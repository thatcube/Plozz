import Foundation
import Observation

/// Persists the household's `Profile`s, the active profile selection, and each
/// profile's chosen subset of the shared account pool.
///
/// All data here is **non-secret** and lives in `UserDefaults` (mirroring the
/// other settings stores). Tokens and the account pool itself stay
/// household-global in `FeatureAuth.AccountStore`; a profile only records *which*
/// `Account.id`s it uses.
///
/// The first/default profile is the one created by `migrateLegacyIfNeeded()` on
/// upgrade. It uses a `nil` settings namespace (see `Profile.settingsNamespace`)
/// so an existing install keeps its theme/spoiler/caption/diagnostics settings
/// without a copy step, and falls back to the legacy global active-account set
/// when it has no explicitly-stored one.
public protocol ProfilePersisting: Sendable {
    /// All profiles, in stable (created-at) order.
    func loadProfiles() -> [Profile]
    /// Replaces the full profile list.
    func saveProfiles(_ profiles: [Profile])
    /// The selected profile id, if one was persisted.
    func activeProfileID() -> String?
    /// Persists (or clears) the selected profile id.
    func setActiveProfileID(_ id: String?)
    /// The account-id subset this profile uses, or `nil` if it never set one
    /// (callers then fall back to the household default).
    func activeAccountIDs(forProfile profileID: String) -> [String]?
    /// Records the account-id subset for a profile.
    func setActiveAccountIDs(_ ids: [String], forProfile profileID: String)
    /// One-time bootstrap: if no profiles exist yet, create a single default
    /// profile (seeded from `defaultName`/`defaultActiveAccountIDs`) and make it
    /// active. Idempotent; returns the profile list after running.
    @discardableResult
    func migrateLegacyIfNeeded(defaultName: String, defaultActiveAccountIDs: [String]) -> [Profile]
}

public final class ProfileStore: ProfilePersisting, @unchecked Sendable {
    private let defaults: UserDefaults
    private let lock = NSLock()

    private let profilesKey = "com.plozz.profiles.v1"
    private let activeProfileIDKey = "com.plozz.profiles.activeID"
    private let perProfileActiveAccountsPrefix = "com.plozz.profile.activeAccounts."
    /// Stable id assigned to the migrated default profile so its identity is the
    /// same across launches and its `isDefault` status is unambiguous.
    public static let defaultProfileID = "com.plozz.profile.default"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: Profiles

    public func loadProfiles() -> [Profile] {
        lock.lock(); defer { lock.unlock() }
        return loadProfilesLocked()
    }

    public func saveProfiles(_ profiles: [Profile]) {
        lock.lock(); defer { lock.unlock() }
        saveProfilesLocked(profiles)
    }

    public func activeProfileID() -> String? {
        lock.lock(); defer { lock.unlock() }
        let known = Set(loadProfilesLocked().map(\.id))
        guard let id = defaults.string(forKey: activeProfileIDKey), known.contains(id) else {
            return nil
        }
        return id
    }

    public func setActiveProfileID(_ id: String?) {
        lock.lock(); defer { lock.unlock() }
        if let id {
            defaults.set(id, forKey: activeProfileIDKey)
        } else {
            defaults.removeObject(forKey: activeProfileIDKey)
        }
    }

    // MARK: Per-profile active accounts

    public func activeAccountIDs(forProfile profileID: String) -> [String]? {
        lock.lock(); defer { lock.unlock() }
        guard let data = defaults.data(forKey: accountsKey(profileID)),
              let ids = try? JSONDecoder().decode([String].self, from: data) else {
            return nil
        }
        return ids
    }

    public func setActiveAccountIDs(_ ids: [String], forProfile profileID: String) {
        lock.lock(); defer { lock.unlock() }
        if let data = try? JSONEncoder().encode(ids) {
            defaults.set(data, forKey: accountsKey(profileID))
        }
    }

    // MARK: Migration

    @discardableResult
    public func migrateLegacyIfNeeded(defaultName: String, defaultActiveAccountIDs: [String]) -> [Profile] {
        lock.lock(); defer { lock.unlock() }
        let existing = loadProfilesLocked()
        guard existing.isEmpty else { return existing }

        let profile = Profile(
            id: Self.defaultProfileID,
            name: defaultName,
            createdAt: Date(timeIntervalSince1970: 0) // sorts first, ahead of any later profile
        )
        saveProfilesLocked([profile])
        defaults.set(profile.id, forKey: activeProfileIDKey)
        if !defaultActiveAccountIDs.isEmpty {
            if let data = try? JSONEncoder().encode(defaultActiveAccountIDs) {
                defaults.set(data, forKey: accountsKey(profile.id))
            }
        }
        return [profile]
    }

    // MARK: Locked helpers

    private func accountsKey(_ profileID: String) -> String { perProfileActiveAccountsPrefix + profileID }

    private func loadProfilesLocked() -> [Profile] {
        guard let data = defaults.data(forKey: profilesKey),
              let profiles = try? JSONDecoder().decode([Profile].self, from: data) else {
            return []
        }
        return profiles.sorted { $0.createdAt < $1.createdAt }
    }

    private func saveProfilesLocked(_ profiles: [Profile]) {
        let ordered = profiles.sorted { $0.createdAt < $1.createdAt }
        if let data = try? JSONEncoder().encode(ordered) {
            defaults.set(data, forKey: profilesKey)
        }
    }
}

/// Observable wrapper the app's composition root holds. It exposes the profile
/// list + the active profile and the household mutations (add/rename/remove/
/// select), persisting every change through a `ProfilePersisting`.
///
/// It does **not** own settings or accounts — `AppState` reacts to
/// `activeProfile` changes to rebuild the per-profile settings models and
/// recompute the active account subset.
@MainActor
@Observable
public final class ProfilesModel {
    public private(set) var profiles: [Profile]
    public private(set) var activeProfileID: String

    private let store: ProfilePersisting

    /// - Parameters:
    ///   - defaultName: name for the default profile created on first run.
    ///   - defaultActiveAccountIDs: the household's existing active account set,
    ///     inherited by the default profile.
    public init(
        store: ProfilePersisting = ProfileStore(),
        defaultName: String = "Me",
        defaultActiveAccountIDs: [String] = []
    ) {
        self.store = store
        let migrated = store.migrateLegacyIfNeeded(
            defaultName: defaultName,
            defaultActiveAccountIDs: defaultActiveAccountIDs
        )
        self.profiles = migrated
        self.activeProfileID = store.activeProfileID() ?? migrated.first?.id ?? ProfileStore.defaultProfileID
        // Persist a resolved selection so relaunch is deterministic.
        store.setActiveProfileID(activeProfileID)
    }

    /// The currently-selected profile (falls back to the first profile).
    public var activeProfile: Profile {
        profiles.first { $0.id == activeProfileID } ?? profiles.first
            ?? Profile(id: ProfileStore.defaultProfileID, name: "Me")
    }

    /// Whether `profile` is the default/primary one (drives `nil`-namespaced
    /// settings so the original keys are reused).
    public func isDefault(_ profile: Profile) -> Bool {
        profile.id == ProfileStore.defaultProfileID || profile.id == profiles.first?.id
    }

    /// The settings namespace for the active profile.
    public var activeNamespace: String? {
        activeProfile.settingsNamespace(isDefault: isDefault(activeProfile))
    }

    /// Switches the active profile (no-op for an unknown id).
    public func select(_ id: String) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        activeProfileID = id
        store.setActiveProfileID(id)
    }

    /// Adds a profile and returns it. New profiles are *not* auto-selected.
    @discardableResult
    public func add(
        name: String,
        avatarSymbol: String = Profile.defaultAvatarSymbols[0],
        colorIndex: Int = 0,
        linkedAccountID: String? = nil,
        activeAccountIDs: [String] = []
    ) -> Profile {
        let profile = Profile(
            name: name,
            avatarSymbol: avatarSymbol,
            colorIndex: colorIndex,
            linkedAccountID: linkedAccountID
        )
        profiles.append(profile)
        profiles.sort { $0.createdAt < $1.createdAt }
        store.saveProfiles(profiles)
        if !activeAccountIDs.isEmpty {
            store.setActiveAccountIDs(activeAccountIDs, forProfile: profile.id)
        }
        return profile
    }

    /// Updates an existing profile's editable fields in place.
    public func update(_ profile: Profile) {
        guard let idx = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[idx] = profile
        store.saveProfiles(profiles)
    }

    /// Removes a profile. The default profile can't be removed; removing the
    /// active profile falls selection back to the first remaining profile.
    public func remove(_ id: String) {
        guard id != ProfileStore.defaultProfileID, id != profiles.first?.id else { return }
        profiles.removeAll { $0.id == id }
        store.saveProfiles(profiles)
        if activeProfileID == id {
            activeProfileID = profiles.first?.id ?? ProfileStore.defaultProfileID
            store.setActiveProfileID(activeProfileID)
        }
    }

    // MARK: Per-profile active accounts

    /// The account subset for a profile, or `fallback` when it never set one.
    public func activeAccountIDs(for profileID: String, fallback: [String]) -> [String] {
        store.activeAccountIDs(forProfile: profileID) ?? fallback
    }

    public func setActiveAccountIDs(_ ids: [String], for profileID: String) {
        store.setActiveAccountIDs(ids, forProfile: profileID)
    }
}
