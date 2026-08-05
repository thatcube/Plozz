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
    /// When each profile was last opened **on this device**, keyed by profile id.
    /// Missing entries mean "never opened here".
    func lastUsedDates() -> [String: Date]
    /// Stamps a profile as opened on this device, now.
    func markProfileUsed(_ profileID: String, at date: Date)
    /// The account-id subset this profile uses, or `nil` if it never set one
    /// (callers then fall back to the household default).
    func activeAccountIDs(forProfile profileID: String) -> [String]?
    /// Records the account-id subset for a profile.
    func setActiveAccountIDs(_ ids: [String], forProfile profileID: String)
    /// Remove a profile's explicit account selection (revert to "never chose" = all).
    func clearActiveAccountIDs(forProfile profileID: String)
    /// One-time bootstrap: if no profiles exist yet, create a single default
    /// profile (seeded from `defaultName`/`defaultActiveAccountIDs`) and make it
    /// active. Idempotent; returns the profile list after running.
    @discardableResult
    func migrateLegacyIfNeeded(defaultName: String, defaultActiveAccountIDs: [String]) -> [Profile]

    // MARK: Household preferences
    //
    // These are household-wide, not per-profile: they govern whether the
    // launch picker appears at all. They live in the same shared/secure store
    // as the profile list so every Apple TV system user sees the same value.

    /// `true`/`false` if the household explicitly set the "Ask which profile
    /// on startup" preference; `nil` when never set (caller picks a default,
    /// typically `profiles.count > 1`).
    func askProfileOnStartupOverride() -> Bool?
    /// Persists (or clears with `nil`) the launch-picker preference.
    func setAskProfileOnStartupOverride(_ value: Bool?)

    /// Whether the one-time first-run profile setup (seed the default profile
    /// from the first sign-in, then confirm it) has completed. Household-wide,
    /// so signing out of everything and re-adding a server never re-seeds a
    /// profile the user has since customized.
    func firstRunProfileSetupComplete() -> Bool
    /// Persists whether the one-time first-run profile setup has completed.
    func setFirstRunProfileSetupComplete(_ value: Bool)

    /// The household's Parental PIN, or `nil` when none is set (the default).
    ///
    /// Household-wide by design — see ``ParentalPIN``. Stored beside the profile
    /// list so every Apple TV system user sees the same value.
    func parentalPIN() -> ParentalPIN?
    /// Persists (or clears with `nil`) the household's Parental PIN.
    func setParentalPIN(_ value: ParentalPIN?)

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
    public func firstRunProfileSetupComplete() -> Bool { false }
    public func setFirstRunProfileSetupComplete(_ value: Bool) {}
    public func parentalPIN() -> ParentalPIN? { nil }
    public func setParentalPIN(_ value: ParentalPIN?) {}
    public func resetForDebugging() {}
    public func clearActiveAccountIDs(forProfile profileID: String) {}
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
    /// Per-device recency map, so the picker can lead with whoever watches here.
    ///
    /// Deliberately NOT on `Profile` and NOT synced: "who used this Apple TV
    /// last" is a fact about this device, and syncing it would also mean every
    /// profile switch published a record — churn on a channel whose whole design
    /// depends on writes being genuine edits.
    private let lastUsedKey = "com.plozz.profiles.lastUsed"
    /// Retired household flag ("Profiles are turned on"). Profiles are now always
    /// on, so nothing reads this — it's kept only so `resetForDebugging` purges
    /// the value left behind by older installs.
    private let legacyProfilesEnabledKey = "com.plozz.profiles.enabled"
    private let firstRunSetupKey = "com.plozz.profiles.firstRunSetupComplete"
    private let parentalPINKey = "com.plozz.profiles.parentalPIN"
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

    public func lastUsedDates() -> [String: Date] {
        lock.lock(); defer { lock.unlock() }
        guard let raw = defaults.dictionary(forKey: lastUsedKey) as? [String: Double] else { return [:] }
        return raw.mapValues { Date(timeIntervalSince1970: $0) }
    }

    public func markProfileUsed(_ profileID: String, at date: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        var raw = (defaults.dictionary(forKey: lastUsedKey) as? [String: Double]) ?? [:]
        raw[profileID] = date.timeIntervalSince1970
        // Drop entries for profiles that no longer exist so the map can't grow
        // without bound across a long-lived install.
        let known = Set(loadProfilesLocked().map(\.id))
        raw = raw.filter { known.contains($0.key) }
        defaults.set(raw, forKey: lastUsedKey)
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

    public func clearActiveAccountIDs(forProfile profileID: String) {
        lock.lock(); defer { lock.unlock() }
        removeSharedData(forKey: accountsKey(profileID))
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

    public func firstRunProfileSetupComplete() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return readSharedBool(forKey: firstRunSetupKey) ?? false
    }

    public func setFirstRunProfileSetupComplete(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        writeSharedBool(value, forKey: firstRunSetupKey)
    }

    /// Stored beside the profile list (the shared/secure store), so the whole
    /// household sees one PIN rather than one per Apple TV system user.
    public func parentalPIN() -> ParentalPIN? {
        lock.lock(); defer { lock.unlock() }
        guard let data = sharedData(forKey: parentalPINKey) else { return nil }
        return try? JSONDecoder().decode(ParentalPIN.self, from: data)
    }

    public func setParentalPIN(_ value: ParentalPIN?) {
        lock.lock(); defer { lock.unlock() }
        guard let value else {
            removeShared(forKey: parentalPINKey)
            return
        }
        guard let data = try? JSONEncoder().encode(value) else { return }
        setSharedData(data, forKey: parentalPINKey)
    }

    public func resetForDebugging() {
        lock.lock(); defer { lock.unlock() }
        for profile in loadProfilesLocked() {
            removeShared(forKey: accountsKey(profile.id))
        }
        removeShared(forKey: profilesKey)
        defaults.removeObject(forKey: activeProfileIDKey)
        defaults.removeObject(forKey: lastUsedKey)
        writeSharedBool(nil, forKey: askOnStartupKey)
        writeSharedBool(nil, forKey: legacyProfilesEnabledKey)
        writeSharedBool(nil, forKey: firstRunSetupKey)
        removeShared(forKey: parentalPINKey)
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

    private func removeSharedData(forKey key: String) {
        if let secureStore { try? secureStore.removeValue(for: key) }
        else { defaults.removeObject(forKey: key) }
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
    /// Household-level "Ask which profile on startup" flag. Defaults to
    /// `profiles.count > 1` until the user explicitly toggles it.
    public private(set) var askProfileOnStartup: Bool
    /// The household's Parental PIN, or `nil` when none is set.
    ///
    /// Its presence is the single switch between the two things a Kids Profile
    /// can be: without it, Kids is *curation* (a simpler page, household
    /// settings hidden) and nothing is gated; with it, Kids is *enforcement*.
    /// Deriving both behaviours from one optional is what stops a setting ever
    /// being locked behind a key nobody holds.
    ///
    /// Read from the household's FIRST profile, which is where it's stored so it
    /// syncs — see ``Profile/parentalPIN``. Falls back to the device-local store
    /// for a PIN written before it synced, so upgrading doesn't silently unlock
    /// a household.
    public var parentalPIN: ParentalPIN? {
        profiles.first?.parentalPIN ?? legacyLocalParentalPIN
    }

    /// A Parental PIN written by a build that kept it device-local. Migrated onto
    /// the first profile the next time one is set, and read until then.
    @ObservationIgnored private var legacyLocalParentalPIN: ParentalPIN?

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
        // Resolve the household preferences. Profiles are always on; the launch
        // picker defaults to "ask" once the household has more than one profile,
        // until the user explicitly toggles it.
        let multi = migrated.count > 1
        self.askProfileOnStartup = store.askProfileOnStartupOverride() ?? multi
        self.legacyLocalParentalPIN = store.parentalPIN()
        // Intentionally does *not* persist a defaulted selection: leaving it
        // unstored is what lets a fresh Apple TV system user get the picker.
        migrateLocalParentalPINIfNeeded()
    }

    /// Moves a Parental PIN written by a build that kept it device-local onto the
    /// synced anchor, so it starts reaching the household's other devices.
    ///
    /// Without this the PIN would sit in local storage forever and only sync if
    /// someone happened to set it again — the household would look protected on
    /// one device and be wide open on the rest, which is the worst of both.
    private func migrateLocalParentalPINIfNeeded() {
        guard let local = legacyLocalParentalPIN, var anchor = profiles.first else { return }

        // A revision means the household has already DECIDED about the PIN —
        // set it, changed it, or deliberately removed it. `parentalPIN == nil`
        // alone can't tell "never had one" from "removed", so migrating on that
        // would resurrect a PIN the user had just deleted (and, because the
        // migration advances the revision, it would beat the deletion on every
        // other device too).
        guard anchor.parentalPIN == nil, anchor.effectiveParentalPINRevision == nil else {
            // The decision has been made elsewhere; this copy is now noise.
            legacyLocalParentalPIN = nil
            store.setParentalPIN(nil)
            return
        }

        anchor.replaceParentalPIN(with: local)
        update(anchor)

        // Only drop the local copy once the anchor actually carries it.
        // Persisting profiles is best-effort, and clearing first would leave a
        // household with no PIN at all if that write didn't land.
        guard profiles.first?.parentalPIN != nil else { return }
        legacyLocalParentalPIN = nil
        store.setParentalPIN(nil)
    }

    /// The currently-selected profile (falls back to the first profile).
    public var activeProfile: Profile {
        profiles.first { $0.id == activeProfileID } ?? profiles.first
            ?? Profile(id: ProfileStore.defaultProfileID, name: "Me")
    }

    // MARK: Parental controls

    /// Sets or clears the household's Parental PIN.
    ///
    /// Written to the first profile so it syncs to every device — a parental
    /// control that applied on one device only wouldn't control anything.
    /// Advances a field-level revision so an unrelated edit arriving from a
    /// stale device can't erase it.
    ///
    /// Clearing it doesn't touch any Kids Profile: those stay on, they simply
    /// stop being enforced. That's deliberate — "I don't need the PIN any more"
    /// shouldn't silently hand a child the household settings back.
    /// - Returns: `false` when there was no profile to anchor the PIN to, so a
    ///   caller can't report success while leaving the household unprotected.
    @discardableResult
    public func setParentalPIN(_ pin: ParentalPIN?) -> Bool {
        guard var anchor = profiles.first else { return false }
        anchor.replaceParentalPIN(with: pin)
        update(anchor)
        // The device-local copy is now redundant; clear it so the synced value is
        // the only source and a stale local one can't resurrect a removed PIN.
        legacyLocalParentalPIN = nil
        store.setParentalPIN(nil)
        return true
    }

    /// Whether `pin` is the household's Parental PIN. `false` when none is set,
    /// so a caller can never be tricked into treating "no PIN" as "any PIN".
    public func matchesParentalPIN(_ pin: String) -> Bool {
        guard let parentalPIN else { return false }
        return parentalPIN.matches(pin: pin)
    }

    /// Whether a Kids Profile's restrictions are actually being enforced.
    ///
    /// The single rule the whole feature turns on: a Kids Profile restricts
    /// nothing until the household has a Parental PIN. Without one there is no
    /// key, so gating a setting would strand it — and the child could switch to
    /// an unlocked grown-up profile anyway, which makes the gate theatre.
    public var enforcesKidsRestrictions: Bool { parentalPIN != nil }

    /// Whether profile MANAGEMENT — creating, editing or deleting profiles — is
    /// currently withheld.
    ///
    /// True only from inside an enforced Kids Profile. Creating a profile
    /// *switches into it*, so an ungated "Add Profile" was a complete bypass:
    /// a child could make an ordinary profile and land in it unrestricted,
    /// never touching the switch gate. Editing is withheld for the same reason —
    /// the editor reaches the Kids flag, the profile lock and Delete.
    ///
    /// A grown-up manages profiles from their own profile; getting there already
    /// costs the Parental PIN, so nothing is unreachable — it just can't be
    /// reached from inside the child's profile.
    public var managementRequiresParentalPIN: Bool {
        activeProfile.isKids && enforcesKidsRestrictions
    }

    /// Whether `profile` may change who it watches as, which libraries it sees,
    /// its own Kids flag, and its own Profile Lock.
    ///
    /// The one predicate every surface asks, so a new screen can't accidentally
    /// expose an escalation route the others close.
    public func canEditRestrictedSettings(of profile: Profile) -> Bool {
        !(profile.isKids && enforcesKidsRestrictions)
    }

    /// Whether switching from `from` to `to` has to be authorised first.
    ///
    /// Only leaving a Kids Profile asks. Switching between grown-up profiles
    /// stays free, so the PIN costs the adults nothing in normal use while still
    /// closing the one route that matters: the child walking out of their own
    /// profile into an unrestricted one.
    public func requiresParentalPIN(switchingFrom from: Profile, to: Profile) -> Bool {
        guard enforcesKidsRestrictions else { return false }
        return from.isKids && !to.isKids
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
        store.markProfileUsed(id, at: Date())
    }

    /// Profiles ordered for pickers/settings: the restored active profile is
    /// always first, then everyone else by most-recent use, then never-used
    /// profiles in creation order.
    ///
    /// Recency beats creation order because the picker's job is to make the
    /// likely choice the nearest one — on a shared Apple TV that's whoever used
    /// it last, and tvOS opens focus on the leading tile.
    public var profilesByRecency: [Profile] {
        let used = store.lastUsedDates()
        return profiles.enumerated().sorted { lhs, rhs in
            if lhs.element.id == activeProfileID { return true }
            if rhs.element.id == activeProfileID { return false }
            switch (used[lhs.element.id], used[rhs.element.id]) {
            case let (l?, r?): return l > r
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return lhs.offset < rhs.offset
            }
        }.map(\.element)
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
        avatarEmojiColorIndex: Int? = nil,
        /// Set at CREATION, not by a follow-up `update`, so the profile is never
        /// durably present without it. A second write can fail (or the app can be
        /// killed between the two), and a persisted profile with no gate inherits
        /// every server and imports the household's watchlist on next launch —
        /// the exact leak the gate exists to stop. See `Profile.isAwaitingSetup`.
        isAwaitingSetup: Bool? = nil,
        isKidsProfile: Bool? = nil
    ) -> Profile {
        var profile = Profile(
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
        profile.isAwaitingSetup = isAwaitingSetup
        profile.isKidsProfile = isKidsProfile
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
        // existing ones so a transferred profile's avatar/emoji/color actually
        // replaces the receiver's pristine default instead of being dropped as a
        // duplicate id.
        //
        // Clobber guard: the ONE id that legitimately collides across devices is
        // the shared default profile (`defaultProfileID`); every other id is a
        // UUID that only matches when it's genuinely the same profile. On a FRESH
        // receiver (first-run not yet complete) overwriting the default is exactly
        // what we want — it inherits the source's cosmetics. But once the receiver
        // has completed setup, its default is a real, user-owned profile (its own
        // name/photo, Plex Home mapping, downloads namespace); silently replacing
        // it with a synced default would lose that. So on an already-configured
        // receiver we keep the local default and skip the incoming one.
        let receiverConfigured = firstRunProfileSetupComplete
        var byID: [String: Profile] = [:]
        var order: [String] = []
        for p in profiles {
            if byID[p.id] == nil { order.append(p.id) }
            byID[p.id] = p
        }
        for p in incoming {
            if p.id == ProfileStore.defaultProfileID, receiverConfigured, var local = byID[p.id] {
                // Keep the receiver's own default, but NOT at the cost of the
                // household Parental PIN: that rides this record and nothing else
                // carries it, so skipping wholesale handed the receiver every Kids
                // Profile with nothing enforcing them — silently, badge and all.
                // Merged under the same revision rule the sync path uses.
                let localRevision = local.effectiveParentalPINRevision
                if let incomingRevision = p.effectiveParentalPINRevision,
                   localRevision == nil || incomingRevision > localRevision! {
                    local.parentalPIN = p.parentalPIN
                    local.parentalPINRevision = incomingRevision
                    byID[p.id] = local
                }
                continue // otherwise don't clobber a configured receiver's own default
            }
            if byID[p.id] == nil { order.append(p.id) }
            byID[p.id] = p
        }
        profiles = order.compactMap { byID[$0] }
        profiles.sort { $0.createdAt < $1.createdAt }
        store.saveProfiles(profiles)
        recomputeHouseholdDefaults()
    }

    /// Apply profiles arriving from ongoing CloudKit sync. Unlike `importProfiles`
    /// (pairing), this UPDATES every existing profile by id — INCLUDING the shared
    /// default profile — so an edit to the default's name/avatar/color on one device
    /// converges on the others. New ids are added. Nothing is removed here (profile
    /// deletions propagate separately). The record-level last-writer-wins in the
    /// sync mirror already decided the winner, so applying the incoming value is
    /// safe: a stale remote never reaches this method (its snapshot is unchanged).
    public func mergeSyncedProfiles(_ incoming: [Profile]) {
        guard !incoming.isEmpty else { return }
        var byID: [String: Profile] = [:]
        var order: [String] = []
        for p in profiles {
            if byID[p.id] == nil { order.append(p.id) }
            byID[p.id] = p
        }
        var changed = false
        for p in incoming {
            if byID[p.id] != p { changed = true }   // add or update (default included)
            if byID[p.id] == nil { order.append(p.id) }
            byID[p.id] = p
        }
        guard changed else { return }
        profiles = order.compactMap { byID[$0] }
        profiles.sort { $0.createdAt < $1.createdAt }
        store.saveProfiles(profiles)
        recomputeHouseholdDefaults()
    }

    /// V3 exact apply: merge incoming cosmetic profile DTOs (upserts) and apply
    /// deletions, in one pass. Merging preserves every DEVICE-LOCAL field (Plex Home /
    /// Seerr / bindings) — only name/avatar/color/createdAt travel — so a re-capture
    /// reproduces the exact same canonical bytes (the round-trip invariant). The
    /// default profile is never deleted.
    public func applySyncedProfileDTOs(_ upserts: [String: ProfileSyncDTO], deletions: Set<String>) {
        var byID: [String: Profile] = [:]
        var order: [String] = []
        for p in profiles {
            if byID[p.id] == nil { order.append(p.id) }
            byID[p.id] = p
        }
        var changed = false
        for (id, dto) in upserts {
            if let existing = byID[id] {
                let merged = dto.merged(into: existing)
                if merged != existing { byID[id] = merged; changed = true }
            } else {
                byID[id] = dto.makeProfile(); order.append(id); changed = true
            }
        }
        for id in deletions where id != ProfileStore.defaultProfileID {
            if byID[id] != nil { byID[id] = nil; changed = true }
        }
        guard changed else { return }
        var next = order.compactMap { byID[$0] }
        next.sort { $0.createdAt < $1.createdAt }
        profiles = next
        store.saveProfiles(profiles)
        if !profiles.contains(where: { $0.id == activeProfileID }) {
            activeProfileID = profiles.first?.id ?? ProfileStore.defaultProfileID
            store.setActiveProfileID(activeProfileID)
        }
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
    ///
    /// True when the local flag is set OR the household already has more than the
    /// default profile — extra profiles only exist because setup was already done
    /// (here or on another device, arriving via sync/pairing), so a device that
    /// receives a multi-profile household must not re-run first-run onboarding just
    /// because its LOCAL flag (which isn't synced) is still false.
    public var firstRunProfileSetupComplete: Bool {
        store.firstRunProfileSetupComplete() || profiles.count > 1
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

    /// Clear a profile's explicit account selection (a synced membership deletion →
    /// revert to "watches all servers").
    public func clearActiveAccountIDs(for profileID: String) {
        store.clearActiveAccountIDs(forProfile: profileID)
    }

    // MARK: Household preferences

    /// Persists the "Ask which profile on startup" toggle.
    public func setAskProfileOnStartup(_ value: Bool) {
        store.setAskProfileOnStartupOverride(value)
        askProfileOnStartup = value
    }

    /// Re-derives the household defaults after a profile add/remove. An explicit
    /// launch-picker choice always wins; this only fills in the default when
    /// none has been set.
    private func recomputeHouseholdDefaults() {
        let multi = profiles.count > 1
        if let override = store.askProfileOnStartupOverride() {
            askProfileOnStartup = override
        } else {
            askProfileOnStartup = multi
        }
    }
}
