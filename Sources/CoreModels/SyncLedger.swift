import Foundation

// MARK: - SyncLedger — the V3 sync core (pure, CloudKit-free)
//
// Replaces the V2 `CloudSyncMirror`. V2 inferred "the user edited this" from a
// reconstructed byte snapshot; any non-idempotent adapter, default insertion, or
// ordering change looked like a genuine edit, got a fresh timestamp, and clobbered
// peers (proven on-device). V3 removes that entire class of bug and — after two
// independent expert reviews — hardens the delete, resync, in-flight, and
// stale-delivery paths that silently corrupt config.
//
// Model:
//   • The app's real stores remain the source of truth for VALUES. The ledger tracks
//     per-record SYNC METADATA: the last value known on the server (`syncedValue`,
//     nil = never confirmed), the server change tag (`systemFields`), our current
//     local value + a mutation-boundary edit clock (`editedAt`), a `dirty` flag
//     (needs upsert), and a `pendingDelete` tombstone (locally removed, awaiting the
//     server's confirmation — so a delete is never lost to a crash/rebuild/partial
//     failure and can never be resurrected by a late fetch).
//   • A genuine local edit is a CANONICAL value change vs the server baseline; only
//     then is `editedAt` bumped — never on a remote apply — so after `applyFetched`
//     sets `syncedValue == localValue` a re-capture is a no-op (kills the V2
//     receiver-clobber loop). Invariant: canonicalCapture(exactApply(rec)) == rec.
//   • Conflicts are DETECTED by change tags on send (`serverRecordChanged`) and
//     RESOLVED by `editedAt` last-writer-wins (deterministic byte tie-break). Stale /
//     out-of-order deliveries can neither revert a newer clean value nor regress its
//     `editedAt`.
//   • Deletions are authoritative and durable. A full-resync lifecycle
//     (`beginFullResync`/`endFullResync`) makes a token-reset redownload finalize
//     records that a complete server snapshot no longer contains as deletions — so a
//     peer's delete is never resurrected after `CKErrorChangeTokenExpired`.
//   • `reconcileLocal` refuses to synthesize a mass deletion from a partial/empty
//     capture (a hydrating-store foot-gun that would wipe every peer).
//
// NO secrets ever pass through here.

public typealias SyncRecordID = String

/// EXACT local changes the app must apply to its stores after a fetch/merge/resync.
/// `nil` value = delete that entity locally. Applying exactly these keeps
/// `capture(apply) == record`.
public typealias SyncLocalChanges = [SyncRecordID: Data?]

// MARK: - Ledger entry

public struct SyncLedgerEntry: Codable, Hashable, Sendable {
    /// The canonical value last known on the server. `nil` = not confirmed there yet.
    public var syncedValue: Data?
    public var syncedEditedAt: Int64
    /// Archived CKRecord system fields (change tag) for a conflict-safe save.
    public var systemFields: Data?
    /// This device's current canonical value.
    public var localValue: Data
    /// Mutation-boundary edit clock. Bumped ONLY on a genuine local edit.
    public var editedAt: Int64
    /// Local value differs from the server and must be uploaded.
    public var dirty: Bool
    /// Locally deleted; awaiting the server's confirmation of the delete.
    public var pendingDelete: Bool
    /// Transient (full-resync only): had a server baseline when the resync began.
    public var wasSynced: Bool
    /// Transient (full-resync only): delivered during the current full resync.
    public var resyncSeen: Bool

    public init(
        syncedValue: Data?, syncedEditedAt: Int64, systemFields: Data?,
        localValue: Data, editedAt: Int64, dirty: Bool,
        pendingDelete: Bool = false, wasSynced: Bool = false, resyncSeen: Bool = false
    ) {
        self.syncedValue = syncedValue
        self.syncedEditedAt = syncedEditedAt
        self.systemFields = systemFields
        self.localValue = localValue
        self.editedAt = editedAt
        self.dirty = dirty
        self.pendingDelete = pendingDelete
        self.wasSynced = wasSynced
        self.resyncSeen = resyncSeen
    }
}

// MARK: - Plans

/// A record to upload: canonical value + edit clock + the change tag to save against.
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

public struct SyncPushPlan: Equatable, Sendable {
    public var uploads: [SyncUpload]
    public var deletes: [SyncRecordID]
    /// Deletions REFUSED because the capture looked partial/empty (a safety stop). The
    /// service should log this and NOT treat it as "nothing to do".
    public var refusedDeletions: [SyncRecordID]
    public var isEmpty: Bool { uploads.isEmpty && deletes.isEmpty }
    public init(uploads: [SyncUpload] = [], deletes: [SyncRecordID] = [], refusedDeletions: [SyncRecordID] = []) {
        self.uploads = uploads; self.deletes = deletes; self.refusedDeletions = refusedDeletions
    }
}

/// A fetched/conflicted server record.
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
    /// Monotonic edit clock (a hybrid logical clock) that advances ONLY on genuine
    /// local edits and observed remote edits — never on a byte-diff of a rebuilt
    /// snapshot.
    private var clock: Int64
    /// True between `beginFullResync` and `endFullResync`.
    private var resyncing: Bool
    /// Transient, monotonically-bumped counter of REMOTE-driven mutations (fetched
    /// applies, send-conflict server-wins, remote deletions, resync finalize). The
    /// service reads it around the `await captureRecords()` suspension: if it changed
    /// while capture was in flight, the captured snapshot is stale relative to the
    /// server baseline and MUST be re-captured before reconciling — otherwise a stale
    /// local value would be re-stamped and clobber the peer edit that just arrived.
    /// Not persisted (only meaningful within a process's actor lifetime).
    public private(set) var remoteRevision: Int = 0

    public init() { self.entries = [:]; self.clock = 0; self.resyncing = false }

    private mutating func bumpRemoteRevision() { remoteRevision &+= 1 }

    enum CodingKeys: String, CodingKey { case entries, clock }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entries = try c.decode([SyncRecordID: SyncLedgerEntry].self, forKey: .entries)
        clock = try c.decode(Int64.self, forKey: .clock)
        resyncing = false
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(entries, forKey: .entries)
        try c.encode(clock, forKey: .clock)
    }

    /// Records currently mirrored (excludes pending-delete tombstones) — the
    /// "N items in iCloud" count.
    public var count: Int { entries.values.filter { !$0.pendingDelete }.count }

    /// True if any entry carries a confirmed server baseline — i.e. this ledger has
    /// really synced with the server at least once. The service uses this to decide
    /// whether a publish after a FAILED fetch is safe: with a baseline, reconcile
    /// compares against known server state (safe); without one (fresh device / lost
    /// state file), publishing would stamp fresh edits that could clobber peers.
    public var hasServerBaseline: Bool {
        entries.values.contains { $0.syncedValue != nil }
    }

    /// The last-known canonical bytes per record — server baseline where we have one,
    /// otherwise the pending local value. The app's `captureRecords` uses this as a
    /// FALLBACK for records it can't currently express locally (e.g. a setting whose
    /// profile arrived in a later fetch batch, or a not-signed-in server descriptor),
    /// so an out-of-order or partial capture never omits a record and triggers a
    /// spurious deletion. Excludes pending-delete tombstones.
    public func syncedValues() -> [SyncRecordID: Data] {
        var out: [SyncRecordID: Data] = [:]
        for (name, entry) in entries where !entry.pendingDelete {
            out[name] = entry.syncedValue ?? entry.localValue
        }
        return out
    }

    private mutating func tick(_ now: Int64) -> Int64 { clock = max(now, clock + 1); return clock }
    private mutating func observe(_ remote: Int64) { clock = max(clock, remote) }

    // MARK: Local reconcile

    /// Diff the freshly-captured canonical local state against the ledger and produce
    /// the minimal upload/delete plan. `desired` maps every LOCAL record to its
    /// canonical value. A record whose canonical value differs from `syncedValue` is a
    /// genuine edit (fresh `editedAt`, queued to upload). Records present in the ledger
    /// but ABSENT from `desired` are local deletions — routed through durable
    /// `pendingDelete` tombstones so a crash/rebuild/partial-failure can't lose them.
    ///
    /// SAFETY: a partial/empty capture must never be mistaken for mass removal. When
    /// `synthesizeDeletions` is false, or `desired` is empty while server-backed
    /// records exist, absent records are reported as `refusedDeletions` and NOT
    /// deleted. The service passes `synthesizeDeletions: true` only for a trusted,
    /// fully-hydrated snapshot.
    public mutating func reconcileLocal(
        desired: [SyncRecordID: Data], now: Int64, synthesizeDeletions: Bool = true
    ) -> SyncPushPlan {
        var plan = SyncPushPlan()

        for (name, value) in desired {
            if var entry = entries[name] {
                if entry.pendingDelete {
                    // The entity reappeared locally after we queued its delete → revive
                    // as a genuine edit.
                    entry.pendingDelete = false
                    entry.localValue = value
                    entry.editedAt = tick(now)
                    entry.dirty = true
                    entries[name] = entry
                    plan.uploads.append(SyncUpload(recordName: name, value: value,
                                                   editedAt: entry.editedAt, systemFields: entry.systemFields))
                } else if entry.syncedValue != value {
                    // Genuine change vs the SERVER baseline (detects edits made while a
                    // previous upload was in flight).
                    if entry.localValue != value { entry.editedAt = tick(now) }
                    entry.localValue = value
                    entry.dirty = true
                    entries[name] = entry
                    plan.uploads.append(SyncUpload(recordName: name, value: value,
                                                   editedAt: entry.editedAt, systemFields: entry.systemFields))
                } else if entry.localValue != value || entry.dirty {
                    // Server already has this value; heal stale local bookkeeping.
                    entry.localValue = value; entry.dirty = false
                    entries[name] = entry
                }
            } else {
                let stamp = tick(now)
                entries[name] = SyncLedgerEntry(
                    syncedValue: nil, syncedEditedAt: 0, systemFields: nil,
                    localValue: value, editedAt: stamp, dirty: true)
                plan.uploads.append(SyncUpload(recordName: name, value: value, editedAt: stamp, systemFields: nil))
            }
        }

        // Deletions (present in ledger, gone locally). Never inferred from a suspicious
        // capture.
        let serverBacked = entries.values.contains { $0.syncedValue != nil && !$0.pendingDelete }
        let deletionsSafe = synthesizeDeletions && !(desired.isEmpty && serverBacked)
        for (name, var entry) in entries where desired[name] == nil && !entry.pendingDelete {
            if !deletionsSafe {
                plan.refusedDeletions.append(name)
                continue
            }
            if entry.syncedValue == nil && !entry.dirty {
                // Never reached the server → just forget it, no tombstone needed.
                entries[name] = nil
            } else {
                entry.pendingDelete = true
                entry.dirty = false
                entries[name] = entry
                plan.deletes.append(name)
            }
        }

        plan.uploads.sort { $0.recordName < $1.recordName }
        plan.deletes.sort()
        plan.refusedDeletions.sort()
        return plan
    }

    // MARK: Apply fetched changes (server → local, exact)

    public mutating func applyFetched(
        saved: [SyncRemoteRecord], deleted: [SyncRecordID], now: Int64
    ) -> SyncLocalChanges {
        var changes: SyncLocalChanges = [:]
        bumpRemoteRevision()

        for remote in saved {
            observe(remote.editedAt)

            guard var entry = entries[remote.recordName] else {
                entries[remote.recordName] = SyncLedgerEntry(
                    syncedValue: remote.value, syncedEditedAt: remote.editedAt,
                    systemFields: remote.systemFields, localValue: remote.value,
                    editedAt: remote.editedAt, dirty: false,
                    wasSynced: false, resyncSeen: resyncing)
                changes.updateValue(remote.value, forKey: remote.recordName)
                continue
            }
            if resyncing { entry.resyncSeen = true }

            if entry.pendingDelete {
                // We intend to delete this; the server still has it. Keep deleting —
                // never resurrect. (Re-issuing the delete is the service's job.)
                entry.systemFields = remote.systemFields
                entries[remote.recordName] = entry
                continue
            }

            entry.systemFields = remote.systemFields
            if !entry.dirty {
                // Clean locally → accept the server's value ONLY if it isn't stale.
                if entry.syncedValue != nil,
                   entry.localValue != remote.value,
                   !Self.remoteWins(local: entry, remoteEditedAt: remote.editedAt, remoteValue: remote.value) {
                    // Older-than-local delivery → ignore (no value revert, no editedAt regression).
                    entries[remote.recordName] = entry
                    continue
                }
                if entry.localValue != remote.value { changes.updateValue(remote.value, forKey: remote.recordName) }
                entry.syncedValue = remote.value; entry.syncedEditedAt = remote.editedAt
                entry.localValue = remote.value; entry.editedAt = remote.editedAt
                entries[remote.recordName] = entry
            } else if Self.remoteWins(local: entry, remoteEditedAt: remote.editedAt, remoteValue: remote.value) {
                // Concurrent edit; server newer → server wins, drop our edit.
                if entry.localValue != remote.value { changes.updateValue(remote.value, forKey: remote.recordName) }
                entry.syncedValue = remote.value; entry.syncedEditedAt = remote.editedAt
                entry.localValue = remote.value; entry.editedAt = remote.editedAt; entry.dirty = false
                entries[remote.recordName] = entry
            } else {
                // Our edit is newer → keep it; update baseline+tag so our upload lands.
                entry.syncedValue = remote.value; entry.syncedEditedAt = remote.editedAt
                entries[remote.recordName] = entry
            }
        }

        for name in deleted {
            guard entries[name] != nil else { continue }
            // Deletions are authoritative — remove locally even if dirty; never resurrect.
            entries[name] = nil
            changes.updateValue(nil, forKey: name)
        }

        return changes
    }

    // MARK: Send outcomes

    /// A save succeeded. Update the server baseline to what we actually sent, and clear
    /// `dirty` only if the local value still matches — a newer edit (INCLUDING a revert
    /// to the old baseline) made while the save was in flight must stay dirty so it
    /// re-uploads over the value the server now holds.
    public mutating func applySendSuccess(
        recordName: SyncRecordID, savedValue: Data, savedEditedAt: Int64, systemFields: Data
    ) {
        guard var entry = entries[recordName], !entry.pendingDelete else { return }
        entry.systemFields = systemFields
        entry.syncedValue = savedValue
        entry.syncedEditedAt = savedEditedAt
        entry.dirty = (entry.localValue != savedValue)
        entries[recordName] = entry
    }

    /// A `serverRecordChanged` conflict on send. Returns the local change if the server
    /// won (else nil, and the caller retries the save with the fresh tag). Never
    /// resurrects a record we've stopped tracking (matches `applySendSuccess`).
    public mutating func applySendConflict(_ server: SyncRemoteRecord, now: Int64) -> (SyncRecordID, Data?)? {
        observe(server.editedAt)
        bumpRemoteRevision()
        guard var entry = entries[server.recordName], !entry.pendingDelete else { return nil }
        entry.systemFields = server.systemFields
        entry.syncedValue = server.value
        entry.syncedEditedAt = server.editedAt
        if Self.remoteWins(local: entry, remoteEditedAt: server.editedAt, remoteValue: server.value) {
            let change: Data? = entry.localValue == server.value ? nil : server.value
            entry.localValue = server.value; entry.editedAt = server.editedAt; entry.dirty = false
            entries[server.recordName] = entry
            return change.map { (server.recordName, $0) }
        } else {
            entry.dirty = true
            entries[server.recordName] = entry
            return nil
        }
    }

    /// A delete we requested was confirmed by the server (or the record was already
    /// gone) — drop the tombstone.
    public mutating func applyDeleteSuccess(_ recordName: SyncRecordID) {
        if entries[recordName]?.pendingDelete == true { entries[recordName] = nil }
    }

    /// The server reports a record we hold a tag for was DELETED by a peer. Deletion is
    /// authoritative: drop it and delete locally, even against a dirty edit. Returns
    /// whether a local delete is needed (false if we were already deleting it).
    @discardableResult
    public mutating func applyRemoteDeletion(_ recordName: SyncRecordID) -> Bool {
        guard let entry = entries[recordName] else { return false }
        entries[recordName] = nil
        return !entry.pendingDelete
    }

    /// A save hit `unknownItem` (the server has no such record). Drop the stale tag so
    /// the next reconcile re-creates it as needed. (Config policy: re-upload rather than
    /// delete; `unknownItem` here means the record genuinely never persisted.)
    public mutating func clearServerRecord(_ recordName: SyncRecordID) {
        guard var entry = entries[recordName] else { return }
        entry.systemFields = nil; entry.syncedValue = nil; entry.syncedEditedAt = 0
        entries[recordName] = entry
    }

    /// Uploads to (re)send for every dirty record — to requeue pending work after an
    /// engine rebuild without re-stamping anything.
    public func pendingUploads() -> [SyncUpload] {
        entries
            .filter { $0.value.dirty && !$0.value.pendingDelete }
            .map { SyncUpload(recordName: $0.key, value: $0.value.localValue,
                              editedAt: $0.value.editedAt, systemFields: $0.value.systemFields) }
            .sorted { $0.recordName < $1.recordName }
    }

    /// Record names with an unconfirmed local deletion — to requeue deletes after a
    /// rebuild so a delete is never lost.
    public func pendingDeletes() -> [SyncRecordID] {
        entries.filter { $0.value.pendingDelete }.map(\.key).sorted()
    }

    // MARK: Full-resync lifecycle (token reset / redownload)

    /// Begin a full resync: forget every server baseline/tag (forcing re-fetch) but
    /// KEEP local values, dirty edits, and pending deletes. Records confirmed present
    /// by the resync are re-baselined; those a COMPLETE resync never delivers are
    /// finalized as deletions in `endFullResync` — so a peer's delete can't be
    /// resurrected after a tombstoneless (`CKErrorChangeTokenExpired`) resync.
    public mutating func beginFullResync() {
        resyncing = true
        bumpRemoteRevision()
        for (name, var entry) in entries {
            entry.wasSynced = (entry.syncedValue != nil)
            entry.resyncSeen = false
            entry.syncedValue = nil
            entry.syncedEditedAt = 0
            entry.systemFields = nil
            entries[name] = entry
        }
    }

    /// Finish a full resync. A record that HAD a server baseline but was not delivered
    /// by the complete resync, and has no pending local change, was deleted on the
    /// server → delete it locally. Dirty/never-synced local records survive and
    /// re-upload. Returns the exact local deletions to apply.
    public mutating func endFullResync() -> SyncLocalChanges {
        var changes: SyncLocalChanges = [:]
        bumpRemoteRevision()
        for (name, var entry) in entries {
            if entry.wasSynced && !entry.resyncSeen && !entry.dirty && !entry.pendingDelete {
                entries[name] = nil
                changes.updateValue(nil, forKey: name)
            } else {
                entry.wasSynced = false; entry.resyncSeen = false
                entries[name] = entry
            }
        }
        resyncing = false
        return changes
    }

    /// Abort a full resync that FAILED or fetched incompletely — the opposite safety
    /// choice to `endFullResync`. A partial/failed fetch must NEVER be finalized as a
    /// complete snapshot (that would delete records the fetch simply didn't reach).
    /// So a record that HAD a server baseline but wasn't re-delivered is NOT deleted;
    /// instead it is marked dirty so it re-uploads its known-good local value,
    /// restoring the record we couldn't confirm. A later successful fetch/resync
    /// re-establishes the true baseline. No deletions are ever produced.
    public mutating func abortFullResync() {
        bumpRemoteRevision()
        for (name, var entry) in entries {
            if entry.wasSynced && !entry.resyncSeen && !entry.pendingDelete {
                // Couldn't confirm this previously-synced record — re-assert it.
                entry.dirty = true
            }
            entry.wasSynced = false
            entry.resyncSeen = false
            entries[name] = entry
        }
        resyncing = false
    }

    // MARK: Conflict rule

    /// Later real edit wins; exact `editedAt` tie broken deterministically by value
    /// bytes so every device resolves a tie identically.
    private static func remoteWins(local: SyncLedgerEntry, remoteEditedAt: Int64, remoteValue: Data) -> Bool {
        if remoteEditedAt != local.editedAt { return remoteEditedAt > local.editedAt }
        return lexicographicallyGreater(remoteValue, local.localValue)
    }

    private static func lexicographicallyGreater(_ a: Data, _ b: Data) -> Bool {
        let n = min(a.count, b.count)
        var i = 0
        while i < n {
            let ai = a[a.index(a.startIndex, offsetBy: i)]
            let bi = b[b.index(b.startIndex, offsetBy: i)]
            if ai != bi { return ai > bi }
            i += 1
        }
        return a.count > b.count
    }
}
