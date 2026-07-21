import Foundation

// MARK: - Sync reconciliation (granular, versioned, tombstoned)
//
// The research critique flagged that whole-blob last-writer-wins loses unrelated
// offline edits and that compacted tombstones can resurrect deleted records. This
// reconciler is therefore GRANULAR (per-record id) and versioned:
//   • each record carries a monotonically-increasing `recordVersion`;
//   • the higher version wins per id;
//   • a tombstone (id -> version) suppresses any record at an equal-or-lower
//     version, and tombstones merge by highest version so a returning stale device
//     cannot resurrect a delete.
//
// It reconciles ONLY non-secret data (descriptors, profiles). It NEVER deletes a
// local Keychain secret: a remote tombstone removes the non-secret *descriptor*
// only; unbinding the local credential is a separate, locally-confirmed step.

public enum SyncReconciler {

    /// Merge local and remote versioned records + tombstones for one collection.
    /// - Returns: the surviving records (sorted by id for determinism) and the
    ///   merged tombstone map.
    public static func merge<T: Identifiable>(
        local: [T],
        remote: [T],
        version: (T) -> Int,
        localTombstones: [T.ID: Int] = [:],
        remoteTombstones: [T.ID: Int] = [:]
    ) -> (records: [T], tombstones: [T.ID: Int]) where T.ID: Hashable & Comparable {

        // 1. Merge tombstones by highest version.
        var tombstones = localTombstones
        for (id, v) in remoteTombstones {
            tombstones[id] = max(tombstones[id] ?? Int.min, v)
        }

        // 2. Pick the winning record per id (higher version wins; equal version
        //    keeps the local copy for stability).
        var winners: [T.ID: T] = [:]
        for r in local { winners[r.id] = r }
        for r in remote {
            if let existing = winners[r.id] {
                if version(r) > version(existing) { winners[r.id] = r }
            } else {
                winners[r.id] = r
            }
        }

        // 3. Drop any record suppressed by a tombstone at >= its version.
        let survivors = winners.values.filter { rec in
            guard let tv = tombstones[rec.id] else { return true }
            return version(rec) > tv
        }

        return (survivors.sorted { $0.id < $1.id }, tombstones)
    }
}

// MARK: - Config snapshot (the non-secret bundle a device publishes)

/// Wraps a `Profile` with a sync version so profiles reconcile granularly like
/// descriptors do. (`Profile` itself stays a pure, version-free value type.)
public struct VersionedProfile: Codable, Hashable, Identifiable, Sendable {
    public var profile: Profile
    public var recordVersion: Int
    public var id: String { profile.id }
    public init(profile: Profile, recordVersion: Int = 1) {
        self.profile = profile
        self.recordVersion = recordVersion
    }
}

/// The NON-SECRET configuration a device replicates. No tokens, no passwords —
/// account *descriptors* only, plus profiles and their tombstones.
public struct SyncConfigSnapshot: Codable, Hashable, Sendable {
    public var accounts: [SyncedAccountDescriptor]
    public var accountTombstones: [String: Int]
    public var profiles: [VersionedProfile]
    public var profileTombstones: [String: Int]
    /// Per-profile transferable settings (theme, playback, subtitles, …), keyed by
    /// profile id. Empty for a config-only or legacy snapshot.
    public var profileSettings: [ProfileSettingsSnapshot]
    /// Per-profile server *membership* (which accounts a profile watches), keyed by
    /// profile id. A key PRESENT means the profile made an explicit choice — the
    /// value is the chosen account-id subset, possibly `[]` ("watch nothing"). A
    /// key ABSENT means the profile never chose (⇒ defaults to all servers). This
    /// present/absent distinction preserves the unset/empty/subset tri-state that
    /// the per-server master toggle depends on. Empty for a legacy snapshot.
    public var profileMemberships: [String: [String]]
    public var schemaVersion: Int

    public static let currentSchemaVersion = 1

    public init(
        accounts: [SyncedAccountDescriptor] = [],
        accountTombstones: [String: Int] = [:],
        profiles: [VersionedProfile] = [],
        profileTombstones: [String: Int] = [:],
        profileSettings: [ProfileSettingsSnapshot] = [],
        profileMemberships: [String: [String]] = [:],
        schemaVersion: Int = SyncConfigSnapshot.currentSchemaVersion
    ) {
        self.accounts = accounts
        self.accountTombstones = accountTombstones
        self.profiles = profiles
        self.profileTombstones = profileTombstones
        self.profileSettings = profileSettings
        self.profileMemberships = profileMemberships
        self.schemaVersion = schemaVersion
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accounts = try c.decodeIfPresent([SyncedAccountDescriptor].self, forKey: .accounts) ?? []
        accountTombstones = try c.decodeIfPresent([String: Int].self, forKey: .accountTombstones) ?? [:]
        profiles = try c.decodeIfPresent([VersionedProfile].self, forKey: .profiles) ?? []
        profileTombstones = try c.decodeIfPresent([String: Int].self, forKey: .profileTombstones) ?? [:]
        profileSettings = try c.decodeIfPresent([ProfileSettingsSnapshot].self, forKey: .profileSettings) ?? []
        profileMemberships = try c.decodeIfPresent([String: [String]].self, forKey: .profileMemberships) ?? [:]
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? SyncConfigSnapshot.currentSchemaVersion
    }

    /// Reconcile this (local) snapshot against a `remote` one, granularly.
    public func merged(with remote: SyncConfigSnapshot) -> SyncConfigSnapshot {
        let acc = SyncReconciler.merge(
            local: accounts, remote: remote.accounts,
            version: { $0.recordVersion },
            localTombstones: accountTombstones, remoteTombstones: remote.accountTombstones
        )
        let prof = SyncReconciler.merge(
            local: profiles, remote: remote.profiles,
            version: { $0.recordVersion },
            localTombstones: profileTombstones, remoteTombstones: remote.profileTombstones
        )
        return SyncConfigSnapshot(
            accounts: acc.records, accountTombstones: acc.tombstones,
            profiles: prof.records, profileTombstones: prof.tombstones,
            profileSettings: SyncReconciler.unionByProfileID(local: profileSettings, remote: remote.profileSettings),
            profileMemberships: profileMemberships.merging(remote.profileMemberships) { _, incoming in incoming },
            schemaVersion: max(schemaVersion, remote.schemaVersion)
        )
    }
}

extension SyncReconciler {
    /// Merge two per-profile settings lists by `profileID`. A whole-list replace
    /// would drop settings for any profile the remote snapshot doesn't happen to
    /// carry; instead we keep every local profile's settings and overlay the
    /// remote's values for the profiles it does include (remote-wins per profile,
    /// matching the reconciler's incoming-can-update rule). No version field exists
    /// on the snapshot, so per-profile last-writer is the best available tie-break.
    static func unionByProfileID(
        local: [ProfileSettingsSnapshot], remote: [ProfileSettingsSnapshot]
    ) -> [ProfileSettingsSnapshot] {
        var byID: [String: ProfileSettingsSnapshot] = [:]
        var order: [String] = []
        for snap in local + remote {
            if byID[snap.profileID] == nil { order.append(snap.profileID) }
            byID[snap.profileID] = snap
        }
        return order.compactMap { byID[$0] }
    }
}
