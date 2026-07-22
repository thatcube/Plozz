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
    /// Monotonic per-record version OWNED by the sync layer (bumped on local edit).
    /// Independent of `SyncedAccountDescriptor.recordVersion` (which the pairing
    /// path leaves at 1) — auto-sync needs durable, ever-increasing versions so
    /// last-writer-wins converges.
    public var version: Int
    /// JSON encoding of the entity for this `kind`. Non-secret by construction.
    public var payload: Data

    public init(kind: Kind, id: String, version: Int, payload: Data) {
        self.kind = kind
        self.id = id
        self.version = version
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
    /// Order-independent winner of two records for the same `recordName`: higher
    /// `version` wins; on an exact version tie, the lexicographically-greater
    /// `payload` wins. The tie-break is deterministic and symmetric across devices
    /// (no clock, no "who reached the server first"), so concurrent equal-version
    /// edits converge to the SAME value everywhere instead of each device keeping
    /// its own.
    static func resolve(_ a: CloudSyncRecord, _ b: CloudSyncRecord) -> CloudSyncRecord {
        if a.version != b.version { return a.version > b.version ? a : b }
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
                    profiles.append(VersionedProfile(profile: p, recordVersion: rec.version))
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

    public init(records: [String: CloudSyncRecord] = [:]) { self.records = records }

    /// The changes to push after a local edit, keeping the mirror in lock-step.
    public struct PublishPlan: Equatable, Sendable {
        /// Records to save/update in CloudKit (versions already bumped).
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
    /// actually differs (or is new); its version is bumped to `existing + 1`.
    /// Entities absent from `local` are deleted. Idempotent: publishing the same
    /// local snapshot twice yields an empty plan the second time.
    public mutating func publish(local: SyncConfigSnapshot) -> PublishPlan {
        let desired = CloudSyncCodec.desiredRecords(from: local)
        var plan = PublishPlan()

        // Saves / updates.
        for (name, payload) in desired {
            if let existing = records[name] {
                if existing.payload == payload { continue }   // unchanged
                guard let parsed = CloudSyncRecord.parse(recordName: name) else { continue }
                let bumped = CloudSyncRecord(kind: parsed.kind, id: parsed.id,
                                             version: existing.version + 1, payload: payload)
                records[name] = bumped
                plan.saves.append(bumped)
            } else {
                guard let parsed = CloudSyncRecord.parse(recordName: name) else { continue }
                let fresh = CloudSyncRecord(kind: parsed.kind, id: parsed.id, version: 1, payload: payload)
                records[name] = fresh
                plan.saves.append(fresh)
            }
        }

        // Deletes (present in mirror, gone locally).
        for name in records.keys where desired[name] == nil {
            records[name] = nil
            plan.deletes.append(name)
        }

        plan.saves.sort { $0.recordName < $1.recordName }
        plan.deletes.sort()
        return plan
    }

    /// Fold fetched remote changes into the mirror using the deterministic merge.
    /// Returns the resulting snapshot to apply locally and whether anything
    /// changed (so callers can skip a no-op apply/re-publish).
    public mutating func applyRemote(saved: [CloudSyncRecord],
                                     deletedRecordNames: [String]) -> (snapshot: SyncConfigSnapshot, changed: Bool) {
        var changed = false
        for incoming in saved {
            if let existing = records[incoming.recordName] {
                let winner = CloudSyncRecord.resolve(existing, incoming)
                if winner != existing { records[incoming.recordName] = winner; changed = true }
            } else {
                records[incoming.recordName] = incoming
                changed = true
            }
        }
        for name in deletedRecordNames where records[name] != nil {
            records[name] = nil
            changed = true
        }
        return (CloudSyncCodec.snapshot(from: records), changed)
    }

    /// The snapshot the mirror currently represents (for the initial upload of an
    /// already-configured device, and for diagnostics).
    public var snapshot: SyncConfigSnapshot { CloudSyncCodec.snapshot(from: records) }

    /// Raise a record's version to at least `version`, keeping its payload. Used by
    /// the CloudKit conflict handler: when this device's content wins a same-version
    /// tie-break, we must bump above the server's version so the re-save actually
    /// lands (a same-version save would just conflict again). Returns the updated
    /// record, or nil if absent.
    @discardableResult
    public mutating func bumpVersion(of recordName: String, toAtLeast version: Int) -> CloudSyncRecord? {
        guard let rec = records[recordName] else { return nil }
        guard rec.version < version else { return rec }
        let bumped = CloudSyncRecord(kind: rec.kind, id: rec.id, version: version, payload: rec.payload)
        records[recordName] = bumped
        return bumped
    }
}
