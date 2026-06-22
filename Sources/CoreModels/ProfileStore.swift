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
    /// When non-nil, the **shared** bits (profile list + per-profile active
    /// accounts) live here instead of `UserDefaults`. In production this is the
    /// user-independent Keychain so the household's profile set is visible to
    /// every Apple TV system user; the active *selection* stays per-user in
    /// `UserDefaults`. `nil` (tests/previews) keeps the all-`UserDefaults`
    /// behavior.
    private let secureStore: SecureStoring?
    private let lock = NSLock()
    /// Guards the one-time `UserDefaults` → shared store migration.
    private var didMigrateShared = false

    private let profilesKey = "com.plozz.profiles.v1"
    private let activeProfileIDKey = "com.plozz.profiles.activeID"
    private let perProfileActiveAccountsPrefix = "com.plozz.profile.activeAccounts."
    /// Stable id assigned to the migrated default profile so its identity is the
    /// same across launches and its `isDefault` status is unambiguous.
    public static let defaultProfileID = "com.plozz.profile.default"

    public init(defaults: UserDefaults = .standard, secureStore: SecureStoring? = nil) {
        self.defaults = defaults
        self.secureStore = secureStore
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
        guard let data = sharedData(forKey: accountsKey(profileID)),
              let ids = try? JSONDecoder().decode([String].self, from: data) else {
            return nil
        }
        return ids
    }

    public func setActiveAccountIDs(_ ids: [String], forProfile profileID: String) {
        lock.lock(); defer { lock.unlock() }
        if let data = try? JSONEncoder().encode(ids) {
            setSharedData(data, forKey: accountsKey(profileID))
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
        // Intentionally does *not* persist `activeProfileIDKey`: creating the
        // default profile is not an explicit user pick. The active id is only
        // stored when a system user actually selects a profile, so a fresh
        // Apple TV user still gets the launch picker (no "remembered" selection).
        if !defaultActiveAccountIDs.isEmpty {
            if let data = try? JSONEncoder().encode(defaultActiveAccountIDs) {
                setSharedData(data, forKey: accountsKey(profile.id))
            }
        }
        return [profile]
    }

    // MARK: Locked helpers

    private func accountsKey(_ profileID: String) -> String { perProfileActiveAccountsPrefix + profileID }

    private func loadProfilesLocked() -> [Profile] {
        ensureSharedMigratedLocked()
        guard let data = sharedData(forKey: profilesKey),
              let profiles = try? JSONDecoder().decode([Profile].self, from: data) else {
            return []
        }
        return profiles.sorted { $0.createdAt < $1.createdAt }
    }

    private func saveProfilesLocked(_ profiles: [Profile]) {
        let ordered = profiles.sorted { $0.createdAt < $1.createdAt }
        if let data = try? JSONEncoder().encode(ordered) {
            setSharedData(data, forKey: profilesKey)
        }
    }

    // MARK: Shared-store routing

    /// Reads a shared blob from the `SecureStoring` (production) or `UserDefaults`
    /// (tests/previews, when no secure store is injected).
    private func sharedData(forKey key: String) -> Data? {
        if let secureStore {
            return secureStore.string(for: key)?.data(using: .utf8)
        }
        return defaults.data(forKey: key)
    }

    private func setSharedData(_ data: Data, forKey key: String) {
        if let secureStore {
            if let json = String(data: data, encoding: .utf8) {
                try? secureStore.setString(json, for: key)
            }
        } else {
            defaults.set(data, forKey: key)
        }
    }

    /// One-time copy of an existing install's profile set from per-user
    /// `UserDefaults` into the shared `SecureStoring`, so every Apple TV system
    /// user sees the same household profiles once the `user-management`
    /// entitlement starts partitioning `UserDefaults`. The active *selection*
    /// stays per-user and is intentionally not migrated. Caller holds `lock`.
    private func ensureSharedMigratedLocked() {
        guard !didMigrateShared else { return }
        didMigrateShared = true
        guard let secureStore, secureStore.string(for: profilesKey) == nil,
              let data = defaults.data(forKey: profilesKey),
              let json = String(data: data, encoding: .utf8) else { return }

        try? secureStore.setString(json, for: profilesKey)
        if let profiles = try? JSONDecoder().decode([Profile].self, from: data) {
            for profile in profiles {
                let key = accountsKey(profile.id)
                if let accData = defaults.data(forKey: key),
                   let accJSON = String(data: accData, encoding: .utf8) {
                    try? secureStore.setString(accJSON, for: key)
                    defaults.removeObject(forKey: key)
                }
            }
        }
        defaults.removeObject(forKey: profilesKey)
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
    /// Whether the current Apple TV system user already has a *stored* profile
    /// pick (vs. the in-memory default). Drives the launch picker: with system
    /// multi-user support, a user with no remembered pick still sees the picker
    /// even though `activeProfile` resolves to a sensible default.
    public private(set) var hasRememberedSelection: Bool

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
        let remembered = store.activeProfileID()
        self.hasRememberedSelection = remembered != nil
        self.activeProfileID = remembered ?? migrated.first?.id ?? ProfileStore.defaultProfileID
        // Intentionally does *not* persist a defaulted selection: leaving it
        // unstored is what lets a fresh Apple TV system user get the picker.
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
        hasRememberedSelection = true
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
