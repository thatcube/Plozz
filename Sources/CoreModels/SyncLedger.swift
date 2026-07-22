import Foundation

// MARK: - SyncLedger — the V3 sync core (pure, CloudKit-free)
//
// Replaces the V2 `CloudSyncMirror`. The V2 design inferred "the user edited this"
// from a reconstructed byte snapshot; any non-idempotent adapter, default
// insertion, or ordering change looked like a genuine edit, got a fresh timestamp,
// and clobbered peers (proven on-device). V3 removes that entire class of bug.
//
// Model (aligned with Apple's sample-cloudkit-sync-engine + independent review):
//   • The app's real stores remain the source of truth for VALUES. The ledger only
//     tracks per-record SYNC METADATA: the last value we know is on the server
//     (`syncedValue`), the server's change tag (`systemFields`), our current local
//     value (`localValue`), a mutation-boundary edit clock (`editedAt`), and a
//     `dirty` flag (local differs from server, needs upload).
//   • A genuine local edit is detected by a CANONICAL value change in
//     `reconcileLocal`. `editedAt` is bumped ONLY on that transition — never when
//     applying a remote change. So after `applyFetched` sets
//     `syncedValue == localValue`, a re-capture from the stores round-trips to the
//     SAME canonical bytes (the required invariant
//     `canonicalCapture(exactApply(record)) == record.value`), and the next
//     reconcile sees no change → no spurious re-upload → NO CLOBBER.
//   • Conflicts are DETECTED by CloudKit change tags on send (`serverRecordChanged`)
//     and RESOLVED by `editedAt` last-writer-wins (later real edit wins; exact ties
//     break deterministically by value bytes). Deletions are authoritative (a
//     remote delete never resurrects, even against a local dirty edit).
//   • `applyFetched`/`applySendConflict` return the EXACT set of local changes to
//     apply (`SyncRecordID -> Data?`, where `nil` means "delete locally"), so the
//     app removes omitted settings keys / deleted profiles instead of resurrecting
//     them.
//
// Records are addressed by an opaque `String` recordName the app layer defines
// (e.g. "profile:<id>", "setting:<profileID>:<key>", "membership:<id>",
// "descriptor:<id>"). The core is entity-agnostic: it moves canonical value bytes,
// nothing more. NO secrets ever pass through here.

public typealias SyncRecordID = String

// MARK: - Ledger entry

/// Durable per-record sync bookkeeping. `Codable` so the service can persist the
/// whole ledger alongside the CKSyncEngine state.
public struct SyncLedgerEntry: Codable, Hashable, Sendable {
    /// The canonical value last known to be on the server. `nil` = never confirmed
    /// on the server yet (a brand-new local record).
    public var syncedValue: Data?
    /// `editedAt` of the value last known on the server.
    public var syncedEditedAt: Int64
    /// Archived CKRecord system fields (the change tag) for a conflict-safe save.
    public var systemFields: Data?
    /// This device's current canonical value for the record.
    public var localValue: Data
    /// Mutation-boundary edit clock for `localValue`. Bumped ONLY on a genuine local
    /// edit (a canonical change in `reconcileLocal`), never on a remote apply.
    public var editedAt: Int64
    /// Local value differs from `syncedValue` and must be uploaded.
    public var dirty: Bool

    public init(
        syncedValue: Data?, syncedEditedAt: Int64, systemFields: Data?,
        localValue: Data, editedAt: Int64, dirty: Bool
    ) {
        self.syncedValue = syncedValue
        self.syncedEditedAt = syncedEditedAt
        self.systemFields = systemFields
        self.localValue = localValue
        self.editedAt = editedAt
        self.dirty = dirty
    }
}

// MARK: - Plans returned to the service

/// A record the service must upload: its canonical value + edit clock + the change
/// tag to save against (nil = create).
public struct SyncUpload: Equatable, Sendable {
    public let recordName: SyncRecordID
    public let value: Data
    public let editedAt: Int64
    public let systemFields: Data?
    public init(recordName: SyncRecordID, value: Data, editedAt: Int64, systemFields: Data?) {
        self.recordName = recordName; self.value = value
        self.editedAt = editedAt; self.systemFields = systemFields
    }
}

/// The minimal set of CloudKit operations to perform after reconciling local state.
public struct SyncPushPlan: Equatable, Sendable {
    public var uploads: [SyncUpload]
    public var deletes: [SyncRecordID]
    public var isEmpty: Bool { uploads.isEmpty && deletes.isEmpty }
    public init(uploads: [SyncUpload] = [], deletes: [SyncRecordID] = []) {
        self.uploads = uploads; self.deletes = deletes
    }
}

/// EXACT local changes the app must apply to its real stores after a fetch/merge.
/// `nil` value = delete that entity locally. Applying these (and nothing else) is
/// what keeps `capture(apply) == record`.
public typealias SyncLocalChanges = [SyncRecordID: Data?]

/// A fetched/conflicted server record handed to the ledger.
public struct SyncRemoteRecord: Equatable, Sendable {
    public let recordName: SyncRecordID
    public let value: Data
    public let editedAt: Int64
    public let systemFields: Data
    public init(recordName: SyncRecordID, value: Data, editedAt: Int64, systemFields: Data) {
        self.recordName = recordName; self.value = value
        self.editedAt = editedAt; self.systemFields = systemFields
    }
}

// MARK: - The ledger

public struct SyncLedger: Codable, Hashable, Sendable {
    public private(set) var entries: [SyncRecordID: SyncLedgerEntry]
    /// Monotonic high-water mark so a burst of edits in the same millisecond still
    /// get strictly increasing `editedAt` values (a hybrid logical clock, but one
    /// that ONLY advances on genuine local edits and observed remote edits — never
    /// on a byte-diff of a reconstructed snapshot).
    private var clock: Int64

    public init() {
        self.entries = [:]
        self.clock = 0
    }

    /// Number of records currently mirrored — for the "N items in iCloud" UI.
    public var count: Int { entries.count }

    /// Advance the edit clock and return a strictly-increasing stamp.
    private mutating func tick(_ now: Int64) -> Int64 {
        clock = max(now, clock + 1)
        return clock
    }

    /// Observe a remote timestamp so our clock never falls behind the fleet.
    private mutating func observe(_ remote: Int64) {
        clock = max(clock, remote)
    }

    // MARK: Local reconcile (detect genuine edits)

    /// Diff the freshly-captured canonical local state against the ledger and produce
    /// the minimal upload/delete plan. `desired` maps every LOCAL record to its
    /// canonical value bytes. A record whose canonical value actually differs from
    /// `syncedValue` is a genuine edit: it gets a fresh `editedAt` and is queued for
    /// upload. Records present in the ledger but ABSENT from `desired` are genuine
    /// local deletions.
    ///
    /// Idempotent: calling it twice with the same `desired` yields an empty plan the
    /// second time. Applying a remote change (via `applyFetched`) leaves
    /// `syncedValue == localValue`, so a reconcile right after sees no change — the
    /// property that eliminates the V2 receiver-clobber loop.
    public mutating func reconcileLocal(desired: [SyncRecordID: Data], now: Int64) -> SyncPushPlan {
        var plan = SyncPushPlan()

        for (name, value) in desired {
            if var entry = entries[name] {
                // A genuine change is a difference from what the SERVER has, not from
                // our cached localValue — that way an edit made while a previous
                // upload was in flight is still detected.
                if entry.syncedValue != value {
                    if entry.localValue != value {
                        // Local value actually moved → stamp a new edit time.
                        entry.editedAt = tick(now)
                    }
                    entry.localValue = value
                    entry.dirty = true
                    entries[name] = entry
                    plan.uploads.append(SyncUpload(
                        recordName: name, value: value,
                        editedAt: entry.editedAt, systemFields: entry.systemFields))
                } else if entry.localValue != value || entry.dirty {
                    // Server already has this value; heal any stale local bookkeeping.
                    entry.localValue = value
                    entry.dirty = false
                    entries[name] = entry
                }
            } else {
                // Brand-new local record.
                let stamp = tick(now)
                let entry = SyncLedgerEntry(
                    syncedValue: nil, syncedEditedAt: 0, systemFields: nil,
                    localValue: value, editedAt: stamp, dirty: true)
                entries[name] = entry
                plan.uploads.append(SyncUpload(
                    recordName: name, value: value, editedAt: stamp, systemFields: nil))
            }
        }

        // Deletions: present in the ledger, gone locally.
        for name in entries.keys where desired[name] == nil {
            entries[name] = nil
            plan.deletes.append(name)
        }

        plan.uploads.sort { $0.recordName < $1.recordName }
        plan.deletes.sort()
        return plan
    }

    // MARK: Apply fetched changes (server → local, exact)

    /// Fold fetched remote records + deletions into the ledger and return the EXACT
    /// local changes to apply. A record we aren't dirty on is accepted verbatim. A
    /// record we ARE dirty on is resolved by `editedAt` (later real edit wins; exact
    /// tie broken by value bytes for determinism). Remote deletions are authoritative
    /// (never resurrected).
    public mutating func applyFetched(
        saved: [SyncRemoteRecord], deleted: [SyncRecordID], now: Int64
    ) -> SyncLocalChanges {
        var changes: SyncLocalChanges = [:]

        for remote in saved {
            observe(remote.editedAt)
            guard var entry = entries[remote.recordName] else {
                // New to us — accept.
                entries[remote.recordName] = SyncLedgerEntry(
                    syncedValue: remote.value, syncedEditedAt: remote.editedAt,
                    systemFields: remote.systemFields,
                    localValue: remote.value, editedAt: remote.editedAt, dirty: false)
                changes.updateValue(remote.value, forKey: remote.recordName)
                continue
            }
            // Always take the server's change tag so a later save conflicts correctly.
            entry.systemFields = remote.systemFields
            if !entry.dirty {
                // Clean locally → accept the server's value.
                if entry.localValue != remote.value {
                    changes.updateValue(remote.value, forKey: remote.recordName)
                }
                entry.syncedValue = remote.value
                entry.syncedEditedAt = remote.editedAt
                entry.localValue = remote.value
                entry.editedAt = remote.editedAt
                entries[remote.recordName] = entry
            } else if Self.remoteWins(local: entry, remoteEditedAt: remote.editedAt, remoteValue: remote.value) {
                // Concurrent edit; server's is newer → server wins, drop our edit.
                if entry.localValue != remote.value {
                    changes.updateValue(remote.value, forKey: remote.recordName)
                }
                entry.syncedValue = remote.value
                entry.syncedEditedAt = remote.editedAt
                entry.localValue = remote.value
                entry.editedAt = remote.editedAt
                entry.dirty = false
                entries[remote.recordName] = entry
            } else {
                // Our local edit is newer → keep it, but update the baseline+tag so
                // our pending upload lands cleanly. No local change (keep our value).
                entry.syncedValue = remote.value
                entry.syncedEditedAt = remote.editedAt
                entries[remote.recordName] = entry
            }
        }

        for name in deleted {
            guard entries[name] != nil else { continue }
            // Deletions are authoritative — remove locally even if we were dirty, to
            // avoid resurrection loops.
            entries[name] = nil
            changes.updateValue(nil, forKey: name)  // delete locally
        }

        return changes
    }

    // MARK: Send outcomes

    /// A save succeeded. Clear `dirty` only if the local value/stamp still matches
    /// what we sent — a newer edit made while the save was in flight must stay dirty.
    public mutating func applySendSuccess(
        recordName: SyncRecordID, savedValue: Data, savedEditedAt: Int64, systemFields: Data
    ) {
        guard var entry = entries[recordName] else { return }
        entry.systemFields = systemFields
        if entry.localValue == savedValue && entry.editedAt == savedEditedAt {
            entry.syncedValue = savedValue
            entry.syncedEditedAt = savedEditedAt
            entry.dirty = false
        }
        // else: a newer local edit is pending; keep dirty so it re-uploads.
        entries[recordName] = entry
    }

    /// A `serverRecordChanged` conflict on send: merge the server record. Returns the
    /// local change to apply if the server won (else `nil`). If our edit is newer we
    /// keep it dirty (the caller re-enqueues the save with the fresh tag).
    public mutating func applySendConflict(_ server: SyncRemoteRecord, now: Int64) -> (SyncRecordID, Data?)? {
        observe(server.editedAt)
        guard var entry = entries[server.recordName] else {
            // We no longer track it but the server has it — adopt it.
            entries[server.recordName] = SyncLedgerEntry(
                syncedValue: server.value, syncedEditedAt: server.editedAt,
                systemFields: server.systemFields,
                localValue: server.value, editedAt: server.editedAt, dirty: false)
            return (server.recordName, .some(server.value))
        }
        entry.systemFields = server.systemFields
        entry.syncedValue = server.value
        entry.syncedEditedAt = server.editedAt
        if Self.remoteWins(local: entry, remoteEditedAt: server.editedAt, remoteValue: server.value) {
            // Server wins → adopt its value, stop retrying.
            let change: Data? = entry.localValue == server.value ? nil : server.value
            entry.localValue = server.value
            entry.editedAt = server.editedAt
            entry.dirty = false
            entries[server.recordName] = entry
            return change.map { (server.recordName, $0) }
        } else {
            // Our edit is newer → keep dirty, caller retries the save with new tag.
            entry.dirty = true
            entries[server.recordName] = entry
            return nil
        }
    }

    /// A record we tried to save no longer exists on the server (`unknownItem`), or a
    /// delete failed because it was already gone. Drop our server bookkeeping so the
    /// next reconcile treats it as a fresh create (if still present locally).
    public mutating func clearServerRecord(_ recordName: SyncRecordID) {
        guard var entry = entries[recordName] else { return }
        entry.systemFields = nil
        entry.syncedValue = nil
        entry.syncedEditedAt = 0
        entries[recordName] = entry
    }

    /// The server reports a record we hold a change tag for was DELETED by a peer
    /// (a save/delete that conflicts with a tombstone). Deletion is authoritative:
    /// drop our entry and tell the caller to delete it locally too — even if we had
    /// a pending edit — so a concurrent edit can never resurrect a deleted entity.
    /// Returns whether a local delete is needed.
    @discardableResult
    public mutating func applyRemoteDeletion(_ recordName: SyncRecordID) -> Bool {
        guard entries[recordName] != nil else { return false }
        entries[recordName] = nil
        return true
    }

    /// The uploads to (re)send for every currently-dirty record — used to requeue
    /// pending work after an engine rebuild without re-stamping anything.
    public func pendingUploads() -> [SyncUpload] {
        entries
            .filter { $0.value.dirty }
            .map { SyncUpload(recordName: $0.key, value: $0.value.localValue,
                              editedAt: $0.value.editedAt, systemFields: $0.value.systemFields) }
            .sorted { $0.recordName < $1.recordName }
    }

    /// Forget the server-side bookkeeping (change tags + synced baseline) WITHOUT
    /// touching local values or dirty edits — for a token-reset redownload. After
    /// this, a full fetch repopulates baselines and only genuinely-dirty local edits
    /// remain queued.
    public mutating func forgetServerState() {
        for (name, var entry) in entries {
            entry.systemFields = nil
            entry.syncedValue = nil
            entry.syncedEditedAt = 0
            // Keep localValue/editedAt/dirty as-is.
            entries[name] = entry
        }
    }

    // MARK: Conflict rule

    /// Later real edit wins; exact `editedAt` tie broken deterministically by value
    /// bytes so every device resolves an exact tie identically.
    private static func remoteWins(local: SyncLedgerEntry, remoteEditedAt: Int64, remoteValue: Data) -> Bool {
        if remoteEditedAt != local.editedAt { return remoteEditedAt > local.editedAt }
        return lexicographicallyGreater(remoteValue, local.localValue)
    }

    /// Deterministic total order on bytes (a > b).
    private static func lexicographicallyGreater(_ a: Data, _ b: Data) -> Bool {
        let n = min(a.count, b.count)
        var i = 0
        while i < n {
            if a[a.index(a.startIndex, offsetBy: i)] != b[b.index(b.startIndex, offsetBy: i)] {
                return a[a.index(a.startIndex, offsetBy: i)] > b[b.index(b.startIndex, offsetBy: i)]
            }
            i += 1
        }
        return a.count > b.count
    }
}
