import Foundation

// MARK: - CloudKit "Stage 1" auto-sync — transport-agnostic core
//
// This is the pure, Foundation-only heart of the CloudKit config auto-sync layer
// (CKSyncEngine lives in `FeatureSyncCloud`, which imports CloudKit; NONE of that
// leaks into CoreModels). It maps the NON-SECRET `SyncConfigSnapshot` to one
// versioned record per logical entity — the granularity CKSyncEngine is built for
// — and back, with a deterministic, order-independent merge so every device on the
// same Apple ID converges to the same roster.
//
// Apple-correct model (see "Mapping Apple TV users to app profiles", WWDC22
// 110384): the profile ROSTER + server descriptors are shared-household data;
// CloudKit propagates that household setup across ONE Apple ID's devices. Tokens
// and passwords are NEVER represented here — only descriptors, profiles,
// per-profile settings, and per-profile server membership.
//
// Loop-prevention + idempotency come from the `CloudSyncMirror`: publishing diffs
// the local snapshot against the last-synced mirror, so re-publishing an unchanged
// state produces no changes, and applying a remote change leaves the mirror equal
// to the local state (the next publish is a no-op).

/// One syncable, NON-SECRET entity. Maps 1:1 to a `CKRecord` in the private DB.
public struct CloudSyncRecord: Codable, Hashable, Sendable {
    /// Which slice of `SyncConfigSnapshot` this record carries.
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case account       // SyncedAccountDescriptor (token-free)
        case profile       // Profile
        case settings      // ProfileSettingsSnapshot (per-profile transferable settings)
        case membership    // [String] account-id subset (per-profile server membership)
    }

    public var kind: Kind
    /// Entity id: `Account.id` for accounts; `Profile.id` for profile/settings/membership.
    public var id: String
    /// Hybrid-logical-clock timestamp of the last local edit, in milliseconds since
    /// 1970. This is the LAST-WRITER-WINS authority for conflict resolution: the
    /// most-recently-edited record wins. It is NOT a plain wall clock — the mirror
    /// advances it as `max(now, everythingSeen + 1ms)` so a local edit always
    /// supersedes anything the device has observed, even across devices with skewed
    /// clocks. This is what makes convergence deadlock-free (a monotonic per-device
    /// version counter could not: the device with the most edits won forever).
    public var editedAt: Int64
    /// JSON encoding of the entity for this `kind`. Non-secret by construction.
    public var payload: Data

    public init(kind: Kind, id: String, editedAt: Int64, payload: Data) {
        self.kind = kind
        self.id = id
        self.editedAt = editedAt
        self.payload = payload
    }

    /// Stable CloudKit record name, e.g. `account:AB12`. Recoverable back into
    /// `(kind, id)` via `parse(recordName:)`.
    public var recordName: String { "\(kind.rawValue):\(id)" }

    /// Recover `(kind, id)` from a `recordName`. `id` may itself contain ':' so we
    /// only split on the FIRST separator.
    public static func parse(recordName: String) -> (kind: Kind, id: String)? {
        guard let sep = recordName.firstIndex(of: ":") else { return nil }
        let kindRaw = String(recordName[recordName.startIndex..<sep])
        let id = String(recordName[recordName.index(after: sep)...])
        guard let kind = Kind(rawValue: kindRaw), !id.isEmpty else { return nil }
        return (kind, id)
    }
}

// MARK: - Deterministic per-record merge

public extension CloudSyncRecord {
    /// Order-independent winner of two records for the same `recordName`:
    /// the later `editedAt` wins (last-writer-wins); on an exact tie, the
    /// lexicographically-greater `payload` wins. Deterministic + symmetric across
    /// devices, so concurrent edits converge to the SAME value everywhere and no
    /// device can be permanently out-voted by a stale higher counter.
    static func resolve(_ a: CloudSyncRecord, _ b: CloudSyncRecord) -> CloudSyncRecord {
        if a.editedAt != b.editedAt { return a.editedAt > b.editedAt ? a : b }
        return payloadGreater(a.payload, b.payload) ? a : b
    }

    /// Lexicographic byte comparison — deterministic, no crypto (CoreModels is
    /// Foundation-only). Returns true if `lhs` should win the tie over `rhs`.
    internal static func payloadGreater(_ lhs: Data, _ rhs: Data) -> Bool {
        let n = min(lhs.count, rhs.count)
        var i = 0
        while i < n {
            let l = lhs[lhs.index(lhs.startIndex, offsetBy: i)]
            let r = rhs[rhs.index(rhs.startIndex, offsetBy: i)]
            if l != r { return l > r }
            i += 1
        }
        return lhs.count > rhs.count
    }
}

// MARK: - Snapshot <-> records codec

/// Pure conversion between the typed `SyncConfigSnapshot` and the flat, versioned
/// record list CloudKit stores. Assigning/bumping versions is the mirror's job
/// (below); this codec is stateless.
public enum CloudSyncCodec {
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        // Sorted keys => stable bytes => the payload tie-break and "unchanged?"
        // comparison are reproducible across devices and runs.
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private static let decoder = JSONDecoder()

    /// The desired records (payloads only; `version` is a placeholder 0 the mirror
    /// fills in) for a local snapshot. A profile contributes up to three records
    /// (profile, its settings, its membership) so each syncs independently.
    public static func desiredRecords(from snapshot: SyncConfigSnapshot) -> [String: Data] {
        var out: [String: Data] = [:]
        for a in snapshot.accounts {
            if let d = try? encoder.encode(a) { out["\(CloudSyncRecord.Kind.account.rawValue):\(a.id)"] = d }
        }
        for p in snapshot.profiles {
            if let d = try? encoder.encode(p.profile) { out["\(CloudSyncRecord.Kind.profile.rawValue):\(p.profile.id)"] = d }
        }
        for s in snapshot.profileSettings {
            if let d = try? encoder.encode(s) { out["\(CloudSyncRecord.Kind.settings.rawValue):\(s.profileID)"] = d }
        }
        for (pid, ids) in snapshot.profileMemberships {
            if let d = try? encoder.encode(ids) { out["\(CloudSyncRecord.Kind.membership.rawValue):\(pid)"] = d }
        }
        return out
    }

    /// Rebuild a `SyncConfigSnapshot` from a set of live records (the mirror). The
    /// inverse of `desiredRecords`, minus tombstones (CloudKit deletions are the
    /// tombstone authority for this transport, so a deleted record is simply
    /// absent).
    public static func snapshot(from records: [String: CloudSyncRecord]) -> SyncConfigSnapshot {
        var accounts: [SyncedAccountDescriptor] = []
        var profiles: [VersionedProfile] = []
        var settings: [ProfileSettingsSnapshot] = []
        var memberships: [String: [String]] = [:]

        for rec in records.values {
            switch rec.kind {
            case .account:
                if let a = try? decoder.decode(SyncedAccountDescriptor.self, from: rec.payload) { accounts.append(a) }
            case .profile:
                if let p = try? decoder.decode(Profile.self, from: rec.payload) {
                    profiles.append(VersionedProfile(profile: p, recordVersion: 1))
                }
            case .settings:
                if let s = try? decoder.decode(ProfileSettingsSnapshot.self, from: rec.payload) { settings.append(s) }
            case .membership:
                if let ids = try? decoder.decode([String].self, from: rec.payload) { memberships[rec.id] = ids }
            }
        }

        return SyncConfigSnapshot(
            accounts: accounts.sorted { $0.id < $1.id },
            profiles: profiles.sorted { $0.id < $1.id },
            profileSettings: settings.sorted { $0.profileID < $1.profileID },
            profileMemberships: memberships
        )
    }
}

// MARK: - Mirror (the last-synced state + version ledger)

/// The device's view of what CloudKit currently holds: one `CloudSyncRecord` per
/// live entity. Persisted to disk alongside the CKSyncEngine state serialization.
/// All mutation goes through `publish`/`applyRemote` so versions stay monotonic
/// and the local/remote convergence invariants hold.
public struct CloudSyncMirror: Codable, Hashable, Sendable {
    /// recordName -> record.
    public private(set) var records: [String: CloudSyncRecord]
    /// Hybrid-logical-clock high-water mark (ms since 1970): the greatest `editedAt`
    /// this device has ever produced or observed. A local edit stamps
    /// `max(now, clock + 1)` so it always supersedes anything seen — the property
    /// that makes convergence deadlock-free and skew-tolerant.
    private var clock: Int64

    public init(records: [String: CloudSyncRecord] = [:]) {
        self.records = records
        self.clock = records.values.map(\.editedAt).max() ?? 0
    }

    /// Advance the HLC and return the new timestamp for a local edit.
    private mutating func tick() -> Int64 {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        clock = max(now, clock + 1)
        return clock
    }

    /// The changes to push after a local edit, keeping the mirror in lock-step.
    public struct PublishPlan: Equatable, Sendable {
        /// Records to save/update in CloudKit (editedAt already stamped).
        public var saves: [CloudSyncRecord]
        /// Record names to delete in CloudKit.
        public var deletes: [String]
        public var isEmpty: Bool { saves.isEmpty && deletes.isEmpty }
        public init(saves: [CloudSyncRecord] = [], deletes: [String] = []) {
            self.saves = saves; self.deletes = deletes
        }
    }

    /// Diff `local` against the mirror, producing the minimal save/delete plan and
    /// advancing the mirror to match. A record is saved only when its payload
    /// actually differs (or is new); a changed record is stamped with a fresh HLC
    /// `editedAt`. Entities absent from `local` are deleted. Idempotent: publishing
    /// the same local snapshot twice yields an empty plan the second time.
    public mutating func publish(local: SyncConfigSnapshot) -> PublishPlan {
        let desired = CloudSyncCodec.desiredRecords(from: local)
        var plan = PublishPlan()

        // Saves / updates.
        for (name, payload) in desired {
            if let existing = records[name], existing.payload == payload { continue } // unchanged
            guard let parsed = CloudSyncRecord.parse(recordName: name) else { continue }
            let stamped = CloudSyncRecord(kind: parsed.kind, id: parsed.id,
                                          editedAt: tick(), payload: payload)
            records[name] = stamped
            plan.saves.append(stamped)
        }

        // Deletes (present in mirror, gone locally). NEVER delete `account`
        // descriptors from mere absence: a device legitimately lacks servers it
        // isn't signed into, so deleting them here would destroy household servers
        // for everyone (the "4 saves, 2 deletes on a rename" data-loss bug).
        // Profile/settings/membership deletes ARE propagated — every device holds
        // every profile, so absence there means a real removal.
        for name in records.keys where desired[name] == nil {
            if CloudSyncRecord.parse(recordName: name)?.kind == .account { continue }
            records[name] = nil
            plan.deletes.append(name)
        }

        plan.saves.sort { $0.recordName < $1.recordName }
        plan.deletes.sort()
        return plan
    }

    /// Fold fetched remote changes into the mirror using the last-writer-wins
    /// resolve. Returns:
    ///   • `snapshot` — the merged config to apply locally,
    ///   • `changed`  — whether local state changed (skip a no-op apply otherwise),
    ///   • `toPush`   — records where THIS device's copy beat the server's, so the
    ///     server is stale and must be re-saved. Without pushing these back, a local
    ///     edit that lost the transport race (its older peer reached the server last)
    ///     would be stranded locally and never re-uploaded.
    @discardableResult
    public mutating func applyRemote(
        saved: [CloudSyncRecord], deletedRecordNames: [String]
    ) -> (snapshot: SyncConfigSnapshot, changed: Bool, toPush: [CloudSyncRecord]) {
        var changed = false
        var toPush: [CloudSyncRecord] = []
        for incoming in saved {
            clock = max(clock, incoming.editedAt)   // observe remote time
            if let existing = records[incoming.recordName] {
                let winner = CloudSyncRecord.resolve(existing, incoming)
                if winner != existing { records[incoming.recordName] = winner; changed = true }
                // The winner isn't the server's copy ⇒ server is stale ⇒ push ours.
                if winner != incoming { toPush.append(winner) }
            } else {
                records[incoming.recordName] = incoming
                changed = true
            }
        }
        for name in deletedRecordNames where records[name] != nil {
            records[name] = nil
            changed = true
        }
        return (CloudSyncCodec.snapshot(from: records), changed, toPush)
    }

    /// The snapshot the mirror currently represents (for the initial upload of an
    /// already-configured device, and for diagnostics).
    public var snapshot: SyncConfigSnapshot { CloudSyncCodec.snapshot(from: records) }
}
