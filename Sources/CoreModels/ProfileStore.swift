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

    // MARK: Household preferences (opt-in profiles UX)
    //
    // These are household-wide, not per-profile: they govern whether the
    // launch picker appears at all, and whether profile UI is shown in
    // Settings. They live in the same shared/secure store as the profile
    // list so every Apple TV system user sees the same value.

    /// `true`/`false` if the household explicitly set the "Ask which profile
    /// on startup" preference; `nil` when never set (caller picks a default,
    /// typically `profiles.count > 1`).
    func askProfileOnStartupOverride() -> Bool?
    /// Persists (or clears with `nil`) the launch-picker preference.
    func setAskProfileOnStartupOverride(_ value: Bool?)
    /// `true`/`false` if the household explicitly opted profiles in or out;
    /// `nil` when never set. With multiple profiles the UI is always shown
    /// regardless of this flag.
    func profilesEnabledOverride() -> Bool?
    /// Persists (or clears with `nil`) the profiles-enabled preference.
    func setProfilesEnabledOverride(_ value: Bool?)

    /// Whether the one-time first-run profile setup (seed the default profile
    /// from the first sign-in, then confirm it) has completed. Household-wide,
    /// so signing out of everything and re-adding a server never re-seeds a
    /// profile the user has since customized.
    func firstRunProfileSetupComplete() -> Bool
    /// Persists whether the one-time first-run profile setup has completed.
    func setFirstRunProfileSetupComplete(_ value: Bool)

    /// Debug-only: wipes all household profile state (profiles, the active
    /// selection, household preference overrides, and the first-run flag) so
    /// the next launch behaves like a brand-new install.
    func resetForDebugging()
}

extension ProfilePersisting {
    // Default no-op implementations so optional stores (tests/previews) do not
    // need to opt into the household-preferences additions to keep compiling.
    public func askProfileOnStartupOverride() -> Bool? { nil }
    public func setAskProfileOnStartupOverride(_ value: Bool?) {}
    public func profilesEnabledOverride() -> Bool? { nil }
    public func setProfilesEnabledOverride(_ value: Bool?) {}
    public func firstRunProfileSetupComplete() -> Bool { false }
    public func setFirstRunProfileSetupComplete(_ value: Bool) {}
    public func resetForDebugging() {}
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
    private let askOnStartupKey = "com.plozz.profiles.askOnStartup"
    private let profilesEnabledKey = "com.plozz.profiles.enabled"
    private let firstRunSetupKey = "com.plozz.profiles.firstRunSetupComplete"
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

    // MARK: Household preferences

    public func askProfileOnStartupOverride() -> Bool? {
        lock.lock(); defer { lock.unlock() }
        return readSharedBool(forKey: askOnStartupKey)
    }

    public func setAskProfileOnStartupOverride(_ value: Bool?) {
        lock.lock(); defer { lock.unlock() }
        writeSharedBool(value, forKey: askOnStartupKey)
    }

    public func profilesEnabledOverride() -> Bool? {
        lock.lock(); defer { lock.unlock() }
        return readSharedBool(forKey: profilesEnabledKey)
    }

    public func setProfilesEnabledOverride(_ value: Bool?) {
        lock.lock(); defer { lock.unlock() }
        writeSharedBool(value, forKey: profilesEnabledKey)
    }

    public func firstRunProfileSetupComplete() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return readSharedBool(forKey: firstRunSetupKey) ?? false
    }

    public func setFirstRunProfileSetupComplete(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        writeSharedBool(value, forKey: firstRunSetupKey)
    }

    public func resetForDebugging() {
        lock.lock(); defer { lock.unlock() }
        for profile in loadProfilesLocked() {
            removeShared(forKey: accountsKey(profile.id))
        }
        removeShared(forKey: profilesKey)
        defaults.removeObject(forKey: activeProfileIDKey)
        writeSharedBool(nil, forKey: askOnStartupKey)
        writeSharedBool(nil, forKey: profilesEnabledKey)
        writeSharedBool(nil, forKey: firstRunSetupKey)
        didMigrateShared = false
    }

    private func removeShared(forKey key: String) {
        if let secureStore {
            try? secureStore.removeValue(for: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private func readSharedBool(forKey key: String) -> Bool? {
        guard let data = sharedData(forKey: key),
              let raw = String(data: data, encoding: .utf8) else { return nil }
        switch raw {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }

    private func writeSharedBool(_ value: Bool?, forKey key: String) {
        guard let value else {
            // Clearing: best-effort. Defaults path stores plain Data, secure
            // path stores a string — wipe whichever applies.
            if let secureStore {
                try? secureStore.removeValue(for: key)
            } else {
                defaults.removeObject(forKey: key)
            }
            return
        }
        let json = value ? "true" : "false"
        if let data = json.data(using: .utf8) {
            setSharedData(data, forKey: key)
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
            createdAt: Date(timeIntervalSince1970: 0), // sorts first, ahead of any later profile
            // A fresh household's first profile gets a fun random emoji rather
            // than a plain symbol (a signed-in account photo, when present, is
            // layered on later by `seedDefaultProfileIdentity` and wins).
            avatarEmoji: Profile.randomAvatarEmoji()
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
    /// Household-level "Profiles are turned on" flag. With more than one
    /// profile in the household, the profile UI is *always* shown (you can't
    /// have multiple profiles without the picker). With exactly one profile,
    /// this reflects an explicit opt-in (Settings → "Enable Profiles").
    public private(set) var profilesEnabled: Bool
    /// Household-level "Ask which profile on startup" flag. Defaults to
    /// `profiles.count > 1` until the user explicitly toggles it.
    public private(set) var askProfileOnStartup: Bool

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
        // Resolve the household preferences. Defaults are "smart" — profiles
        // are considered enabled (and the launch picker shown) whenever the
        // household has more than one profile, even before the user has
        // explicitly toggled either flag. Explicit overrides win.
        let multi = migrated.count > 1
        self.profilesEnabled = store.profilesEnabledOverride() ?? multi
        self.askProfileOnStartup = store.askProfileOnStartupOverride() ?? multi
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
        activeAccountIDs: [String] = [],
        plexHomeUserID: String? = nil,
        plexHomeUserName: String? = nil,
        plexHomeUserAccountID: String? = nil,
        plexHomeUserRequiresPIN: Bool? = nil,
        plexHomeUserAvatarURL: String? = nil,
        plexHomeUserBindings: [String: PlexHomeUserBinding]? = nil,
        avatarImageURL: String? = nil,
        avatarEmoji: String? = nil,
        avatarEmojiColorIndex: Int? = nil
    ) -> Profile {
        let profile = Profile(
            name: name,
            avatarSymbol: avatarSymbol,
            colorIndex: colorIndex,
            linkedAccountID: linkedAccountID,
            plexHomeUserID: plexHomeUserID,
            plexHomeUserName: plexHomeUserName,
            plexHomeUserAccountID: plexHomeUserAccountID,
            plexHomeUserRequiresPIN: plexHomeUserRequiresPIN,
            plexHomeUserAvatarURL: plexHomeUserAvatarURL,
            plexHomeUserBindings: plexHomeUserBindings,
            avatarImageURL: avatarImageURL,
            avatarEmoji: avatarEmoji,
            avatarEmojiColorIndex: avatarEmojiColorIndex
        )
        profiles.append(profile)
        profiles.sort { $0.createdAt < $1.createdAt }
        store.saveProfiles(profiles)
        if !activeAccountIDs.isEmpty {
            store.setActiveAccountIDs(activeAccountIDs, forProfile: profile.id)
        }
        // Crossing into multi-profile territory implicitly enables profiles
        // and the launch picker (unless the user has explicitly turned either
        // off). Without this a freshly-added second profile would never be
        // reachable until the user toggled "Enable Profiles" by hand.
        recomputeHouseholdDefaults()
        return profile
    }

    /// Merge in profiles received from another device (by pairing/sync), preserving
    /// each profile's id so per-profile account scoping stays consistent. Existing
    /// ids are kept as-is; only genuinely new profiles are added.
    public func importProfiles(_ incoming: [Profile]) {
        guard !incoming.isEmpty else { return }
        // Incoming profiles win by id: this both ADDS new profiles and UPDATES
        // existing ones (notably the shared-id default profile) so a transferred
        // profile's avatar/emoji/color actually replaces the receiver's pristine
        // default instead of being silently dropped as a duplicate id.
        var byID: [String: Profile] = [:]
        var order: [String] = []
        for p in profiles {
            if byID[p.id] == nil { order.append(p.id) }
            byID[p.id] = p
        }
        for p in incoming {
            if byID[p.id] == nil { order.append(p.id) }
            byID[p.id] = p
        }
        profiles = order.compactMap { byID[$0] }
        profiles.sort { $0.createdAt < $1.createdAt }
        store.saveProfiles(profiles)
        recomputeHouseholdDefaults()
    }

    /// Updates an existing profile's editable fields in place.
    public func update(_ profile: Profile) {
        guard let idx = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[idx] = profile
        store.saveProfiles(profiles)
    }

    // MARK: First-run setup

    /// Whether the one-time first-run profile setup has completed.
    public var firstRunProfileSetupComplete: Bool {
        store.firstRunProfileSetupComplete()
    }

    /// Marks the one-time first-run profile setup as done so it never runs
    /// again — even if the user later signs out of every server and re-adds one.
    public func markFirstRunProfileSetupComplete() {
        store.setFirstRunProfileSetupComplete(true)
    }

    /// Seeds the default profile's identity (name + optional real photo) from
    /// the first signed-in account, so a brand-new install's profile looks like
    /// whoever just signed in. Only the default profile is touched, and empty
    /// values are ignored. Returns the updated profile (`nil` if none exists).
    @discardableResult
    public func seedDefaultProfileIdentity(name: String, avatarImageURL: String?) -> Profile? {
        guard var profile = profiles.first else { return nil }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty { profile.name = trimmedName }
        if let avatarImageURL,
           !avatarImageURL.trimmingCharacters(in: .whitespaces).isEmpty {
            profile.avatarImageURL = avatarImageURL
        }
        update(profile)
        return profile
    }

    /// Debug-only: collapses back to a single pristine default profile ("Me")
    /// and clears the first-run flag + household preferences, so the next
    /// add-server reproduces a genuine first run and the launch picker won't
    /// interfere.
    public func resetToPristineDefaultForDebugging() {
        store.resetForDebugging()
        let migrated = store.migrateLegacyIfNeeded(defaultName: "Me", defaultActiveAccountIDs: [])
        profiles = migrated
        let remembered = store.activeProfileID()
        hasRememberedSelection = remembered != nil
        activeProfileID = remembered ?? migrated.first?.id ?? ProfileStore.defaultProfileID
        let multi = migrated.count > 1
        profilesEnabled = store.profilesEnabledOverride() ?? multi
        askProfileOnStartup = store.askProfileOnStartupOverride() ?? multi
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
        recomputeHouseholdDefaults()
    }

    // MARK: Per-profile active accounts

    /// The account subset for a profile, or `fallback` when it never set one.
    public func activeAccountIDs(for profileID: String, fallback: [String]) -> [String] {
        store.activeAccountIDs(forProfile: profileID) ?? fallback
    }

    /// The profile's *explicit* stored selection, or `nil` when it never chose
    /// one. Unlike ``activeAccountIDs(for:fallback:)`` this preserves the
    /// difference between "never chose" (`nil` ⇒ default to all servers) and
    /// "chose to watch nothing" (`[]`) — the distinction the per-server master
    /// toggle on Settings → Your Servers & Libraries depends on to be able to
    /// turn a server (and the last remaining server) off.
    public func storedActiveAccountIDs(for profileID: String) -> [String]? {
        store.activeAccountIDs(forProfile: profileID)
    }

    public func setActiveAccountIDs(_ ids: [String], for profileID: String) {
        store.setActiveAccountIDs(ids, forProfile: profileID)
    }

    // MARK: Household preferences

    /// Explicit opt-in. Idempotent: also turns on the launch picker the first
    /// time the user enables profiles so they can actually *see* the picker.
    public func enableProfiles() {
        store.setProfilesEnabledOverride(true)
        profilesEnabled = true
        if store.askProfileOnStartupOverride() == nil {
            store.setAskProfileOnStartupOverride(true)
            askProfileOnStartup = true
        }
    }

    /// Explicit opt-out. Refuses to turn profiles off while more than one
    /// profile exists — the picker is the only way to reach those other
    /// profiles, so hiding it would orphan them.
    public func disableProfiles() {
        guard profiles.count <= 1 else { return }
        store.setProfilesEnabledOverride(false)
        profilesEnabled = false
        store.setAskProfileOnStartupOverride(false)
        askProfileOnStartup = false
    }

    /// Persists the "Ask which profile on startup" toggle.
    public func setAskProfileOnStartup(_ value: Bool) {
        store.setAskProfileOnStartupOverride(value)
        askProfileOnStartup = value
    }

    /// Re-derives the household defaults after a profile add/remove. Explicit
    /// overrides set by `enableProfiles` / `disableProfiles` / the launch toggle
    /// always win; this only fills in the defaults when none has been set.
    private func recomputeHouseholdDefaults() {
        let multi = profiles.count > 1
        if let override = store.profilesEnabledOverride() {
            profilesEnabled = override || multi
        } else {
            profilesEnabled = multi
        }
        if let override = store.askProfileOnStartupOverride() {
            askProfileOnStartup = override
        } else {
            askProfileOnStartup = multi
        }
    }
}
