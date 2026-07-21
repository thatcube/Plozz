import XCTest
@testable import CoreModels

final class ProfileStoreTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "ProfileStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    // MARK: Migration

    func testMigrationCreatesSingleDefaultProfile() {
        let store = ProfileStore(defaults: makeDefaults())
        let profiles = store.migrateLegacyIfNeeded(defaultName: "Me", defaultActiveAccountIDs: ["a1"])
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles.first?.id, ProfileStore.defaultProfileID)
        XCTAssertEqual(profiles.first?.name, "Me")
        // Migration creates the default profile but records no explicit pick,
        // so a fresh Apple TV system user still gets the launch picker.
        XCTAssertNil(store.activeProfileID())
        XCTAssertEqual(store.activeAccountIDs(forProfile: ProfileStore.defaultProfileID), ["a1"])
    }

    func testMigrationIsIdempotent() {
        let defaults = makeDefaults()
        let store = ProfileStore(defaults: defaults)
        _ = store.migrateLegacyIfNeeded(defaultName: "Me", defaultActiveAccountIDs: [])
        // A second run (or a fresh store over the same defaults) must not add a
        // duplicate default profile.
        let again = ProfileStore(defaults: defaults)
            .migrateLegacyIfNeeded(defaultName: "Other", defaultActiveAccountIDs: ["x"])
        XCTAssertEqual(again.count, 1)
        XCTAssertEqual(again.first?.name, "Me")
    }

    // MARK: Round-trips

    func testProfilesRoundTripInCreatedOrder() {
        let defaults = makeDefaults()
        let store = ProfileStore(defaults: defaults)
        let a = Profile(name: "A", createdAt: Date(timeIntervalSince1970: 10))
        let b = Profile(name: "B", createdAt: Date(timeIntervalSince1970: 20))
        store.saveProfiles([b, a]) // saved out of order
        let loaded = ProfileStore(defaults: defaults).loadProfiles()
        XCTAssertEqual(loaded.map(\.name), ["A", "B"])
    }

    func testActiveProfileIDDroppedWhenProfileGone() {
        let defaults = makeDefaults()
        let store = ProfileStore(defaults: defaults)
        let p = Profile(name: "Kid")
        store.saveProfiles([p])
        store.setActiveProfileID(p.id)
        XCTAssertEqual(store.activeProfileID(), p.id)
        // Removing the profile invalidates the stored active id.
        store.saveProfiles([])
        XCTAssertNil(store.activeProfileID())
    }

    func testPerProfileActiveAccountsAreIsolated() {
        let defaults = makeDefaults()
        let store = ProfileStore(defaults: defaults)
        store.setActiveAccountIDs(["j1"], forProfile: "p1")
        store.setActiveAccountIDs(["x1", "x2"], forProfile: "p2")
        XCTAssertEqual(store.activeAccountIDs(forProfile: "p1"), ["j1"])
        XCTAssertEqual(store.activeAccountIDs(forProfile: "p2"), ["x1", "x2"])
        XCTAssertNil(store.activeAccountIDs(forProfile: "unknown"))
    }

    // MARK: Shared (user-independent Keychain) backing

    func testProfilesPersistInSecureStoreNotDefaults() {
        let defaults = makeDefaults()
        let secure = InMemorySecureStoringDouble()
        let store = ProfileStore(defaults: defaults, secureStore: secure)
        let p = Profile(name: "Mom")
        store.saveProfiles([p])
        store.setActiveAccountIDs(["a1"], forProfile: p.id)
        // Shared bits live in the secure store, never UserDefaults.
        XCTAssertNotNil(secure.string(for: "com.plozz.profiles.v1"))
        XCTAssertNil(defaults.data(forKey: "com.plozz.profiles.v1"))
        // A new store over a *different* (per-user) defaults but the same shared
        // secure store still sees the household profiles + account subsets.
        let other = ProfileStore(defaults: makeDefaults(), secureStore: secure)
        XCTAssertEqual(other.loadProfiles().map(\.name), ["Mom"])
        XCTAssertEqual(other.activeAccountIDs(forProfile: p.id), ["a1"])
    }

    func testMigratesExistingProfilesFromDefaultsToSecureStore() throws {
        let defaults = makeDefaults()
        // Seed an existing (pre-entitlement) install's profiles in UserDefaults.
        let legacy = ProfileStore(defaults: defaults)
        let p = legacy.migrateLegacyIfNeeded(defaultName: "Me", defaultActiveAccountIDs: ["acc"]).first!
        XCTAssertNotNil(defaults.data(forKey: "com.plozz.profiles.v1"))

        // First launch with the shared store wired migrates them across.
        let secure = InMemorySecureStoringDouble()
        let migrated = ProfileStore(defaults: defaults, secureStore: secure)
        XCTAssertEqual(migrated.loadProfiles().map(\.id), [p.id])
        XCTAssertEqual(migrated.activeAccountIDs(forProfile: p.id), ["acc"])
        // Old UserDefaults copies are retired so they don't linger per-user.
        XCTAssertNil(defaults.data(forKey: "com.plozz.profiles.v1"))
        XCTAssertNotNil(secure.string(for: "com.plozz.profiles.v1"))
    }
}

/// In-memory `SecureStoring` double for exercising the shared-store path.
private final class InMemorySecureStoringDouble: SecureStoring, @unchecked Sendable {
    private var storage: [String: String] = [:]
    func setString(_ value: String, for key: String) throws { storage[key] = value }
    func string(for key: String) -> String? { storage[key] }
    func readString(for key: String) throws -> String? { storage[key] }
    func removeValue(for key: String) throws { storage[key] = nil }
}

@MainActor
final class ProfilesModelTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "ProfilesModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testBootstrapsDefaultProfileActiveWithNilNamespace() {
        let model = ProfilesModel(store: ProfileStore(defaults: makeDefaults()))
        XCTAssertEqual(model.profiles.count, 1)
        XCTAssertTrue(model.isDefault(model.activeProfile))
        // The default profile must reuse the legacy (un-suffixed) settings keys.
        XCTAssertNil(model.activeNamespace)
    }

    func testAddSelectAndNamespaceForExtraProfile() {
        let model = ProfilesModel(store: ProfileStore(defaults: makeDefaults()))
        let kid = model.add(name: "Kid")
        XCTAssertEqual(model.profiles.count, 2)
        // Not auto-selected.
        XCTAssertTrue(model.isDefault(model.activeProfile))
        model.select(kid.id)
        XCTAssertEqual(model.activeProfile.id, kid.id)
        XCTAssertFalse(model.isDefault(model.activeProfile))
        // A non-default profile namespaces by its id so its settings are isolated.
        XCTAssertEqual(model.activeNamespace, kid.id)
    }

    func testRemoveActiveProfileFallsBackToDefault() {
        let model = ProfilesModel(store: ProfileStore(defaults: makeDefaults()))
        let kid = model.add(name: "Kid")
        model.select(kid.id)
        model.remove(kid.id)
        XCTAssertEqual(model.profiles.count, 1)
        XCTAssertTrue(model.isDefault(model.activeProfile))
    }

    func testDefaultProfileCannotBeRemoved() {
        let model = ProfilesModel(store: ProfileStore(defaults: makeDefaults()))
        let defaultID = model.activeProfile.id
        model.remove(defaultID)
        XCTAssertEqual(model.profiles.count, 1)
    }

    func testActiveAccountIDsFallbackWhenUnset() {
        let model = ProfilesModel(store: ProfileStore(defaults: makeDefaults()))
        let id = model.activeProfile.id
        // No stored subset → fall back to the supplied household default.
        XCTAssertEqual(model.activeAccountIDs(for: id, fallback: ["g1", "g2"]), ["g1", "g2"])
        model.setActiveAccountIDs(["only"], for: id)
        XCTAssertEqual(model.activeAccountIDs(for: id, fallback: ["g1", "g2"]), ["only"])
    }

    /// `storedActiveAccountIDs` must preserve the difference between "never
    /// chose" (`nil`) and "chose to watch nothing" (`[]`). AppState's
    /// `reloadAccounts()` relies on this so that turning the last server off
    /// on Settings → Your Servers & Libraries actually sticks instead of
    /// snapping back on.
    func testStoredActiveAccountIDsDistinguishesUnsetFromExplicitlyEmpty() {
        let model = ProfilesModel(store: ProfileStore(defaults: makeDefaults()))
        let id = model.activeProfile.id
        // Never chose → nil (caller defaults to the household set).
        XCTAssertNil(model.storedActiveAccountIDs(for: id))
        // Explicitly turned everything off → an empty array, NOT nil.
        model.setActiveAccountIDs([], for: id)
        XCTAssertEqual(model.storedActiveAccountIDs(for: id), [])
        // A real selection round-trips too.
        model.setActiveAccountIDs(["s1"], for: id)
        XCTAssertEqual(model.storedActiveAccountIDs(for: id), ["s1"])
    }

    func testHasRememberedSelectionTracksAnExplicitPick() {
        let defaults = makeDefaults()
        // Fresh household: a default profile exists but no system user has picked.
        let model = ProfilesModel(store: ProfileStore(defaults: defaults))
        XCTAssertFalse(model.hasRememberedSelection)
        let kid = model.add(name: "Kid")
        model.select(kid.id)
        XCTAssertTrue(model.hasRememberedSelection)
        // The pick is persisted, so a relaunch (new model over same store) remembers it.
        let relaunched = ProfilesModel(store: ProfileStore(defaults: defaults))
        XCTAssertTrue(relaunched.hasRememberedSelection)
        XCTAssertEqual(relaunched.activeProfile.id, kid.id)
    }

    func testDefaultedSelectionIsNotRemembered() {
        let defaults = makeDefaults()
        // Building a model without ever calling `select` must not persist a pick,
        // so a fresh Apple TV system user still gets the launch picker.
        _ = ProfilesModel(store: ProfileStore(defaults: defaults))
        let relaunched = ProfilesModel(store: ProfileStore(defaults: defaults))
        XCTAssertFalse(relaunched.hasRememberedSelection)
    }

    // MARK: Household preferences (opt-in profiles + startup picker)

    func testAskOnStartupRemainsTrueEvenAfterPickIsRemembered() {
        // The "Ask on startup" toggle is the single source of truth for the
        // launch picker. Picking a profile must not silently flip it off, and
        // it must not be suppressed by the system-user "remembered selection"
        // path on its own — that path provides the picker's *initial* focus,
        // not a reason to skip the picker entirely.
        let defaults = makeDefaults()
        let model = ProfilesModel(store: ProfileStore(defaults: defaults))
        let kid = model.add(name: "Kid")
        XCTAssertTrue(model.askProfileOnStartup)
        model.select(kid.id)
        XCTAssertTrue(model.hasRememberedSelection)
        XCTAssertTrue(model.askProfileOnStartup, "Picking a profile must not turn off the launch toggle")
        // Survives relaunch.
        let relaunched = ProfilesModel(store: ProfileStore(defaults: defaults))
        XCTAssertTrue(relaunched.hasRememberedSelection)
        XCTAssertTrue(relaunched.askProfileOnStartup)
    }

    func testSoloHouseholdDefaultsToProfilesDisabledAndNoStartupAsk() {
        // A brand-new install with the single migrated default profile must
        // hide all profile UI by default and must NOT pop the launch picker.
        let model = ProfilesModel(store: ProfileStore(defaults: makeDefaults()))
        XCTAssertEqual(model.profiles.count, 1)
        XCTAssertFalse(model.profilesEnabled)
        XCTAssertFalse(model.askProfileOnStartup)
    }

    func testAddingASecondProfileFlipsHouseholdDefaultsOn() {
        // Adding a second profile is what makes a household actually use the
        // profile system. Both defaults flip on so the picker becomes
        // reachable (and the user doesn't have to dig through Settings to
        // turn it on after creating Profile #2).
        let model = ProfilesModel(store: ProfileStore(defaults: makeDefaults()))
        _ = model.add(name: "Kid")
        XCTAssertTrue(model.profilesEnabled)
        XCTAssertTrue(model.askProfileOnStartup)
    }

    func testExplicitlyEnablingProfilesPersists() {
        let defaults = makeDefaults()
        let model = ProfilesModel(store: ProfileStore(defaults: defaults))
        model.enableProfiles()
        XCTAssertTrue(model.profilesEnabled)
        // Survives a relaunch.
        let relaunched = ProfilesModel(store: ProfileStore(defaults: defaults))
        XCTAssertTrue(relaunched.profilesEnabled)
    }

    func testDisablingProfilesRefusedWhenMultipleProfilesExist() {
        // Hiding profile UI while >1 profile exists would orphan the other
        // profiles (the picker is the only way to reach them).
        let model = ProfilesModel(store: ProfileStore(defaults: makeDefaults()))
        _ = model.add(name: "Kid")
        model.disableProfiles()
        XCTAssertTrue(model.profilesEnabled, "Must refuse to disable profiles while multiple exist")
    }

    func testAskOnStartupTogglePersists() {
        let defaults = makeDefaults()
        let model = ProfilesModel(store: ProfileStore(defaults: defaults))
        model.setAskProfileOnStartup(true)
        XCTAssertTrue(model.askProfileOnStartup)
        // Survives a relaunch.
        let relaunched = ProfilesModel(store: ProfileStore(defaults: defaults))
        XCTAssertTrue(relaunched.askProfileOnStartup)
    }

    // MARK: Plex Home user mapping

    func testAddPersistsPlexHomeUserFields() {
        let defaults = makeDefaults()
        let model = ProfilesModel(store: ProfileStore(defaults: defaults))
        let kid = model.add(
            name: "Kiddo",
            linkedAccountID: "acct-1",
            plexHomeUserID: "kid-uuid",
            plexHomeUserName: "Kiddo",
            plexHomeUserAccountID: "acct-1",
            plexHomeUserRequiresPIN: true
        )
        XCTAssertEqual(kid.plexHomeUserID, "kid-uuid")
        XCTAssertEqual(kid.plexHomeUserAccountID, "acct-1")
        XCTAssertEqual(kid.plexHomeUserRequiresPIN, true)
        // Survives a relaunch (re-decoded from the same store).
        let relaunched = ProfilesModel(store: ProfileStore(defaults: defaults))
        let stored = relaunched.profiles.first { $0.id == kid.id }
        XCTAssertEqual(stored?.plexHomeUserID, "kid-uuid")
        XCTAssertEqual(stored?.plexHomeUserName, "Kiddo")
        XCTAssertEqual(stored?.plexHomeUserRequiresPIN, true)
    }

    func testLegacyProfileJSONDecodesWithNilPlexFields() throws {
        // A profile persisted before Phase 2 has no Plex keys; decoding must
        // default them to nil rather than fail.
        let legacy = #"""
        {"id":"p1","name":"Me","avatarSymbol":"person.fill","colorIndex":0,"createdAt":0}
        """#
        let profile = try JSONDecoder().decode(Profile.self, from: Data(legacy.utf8))
        XCTAssertEqual(profile.name, "Me")
        XCTAssertNil(profile.plexHomeUserID)
        XCTAssertNil(profile.plexHomeUserName)
        XCTAssertNil(profile.plexHomeUserAccountID)
        XCTAssertNil(profile.plexHomeUserRequiresPIN)
        XCTAssertNil(profile.plexHomeUserBindings)
    }

    // MARK: Per-account Plex Home-user bindings

    func testHomeUserBindingFallsBackToLegacyFields() {
        // A profile encoded before per-account bindings shipped exposes its
        // single legacy mapping through the new helper.
        let profile = Profile(
            name: "Me",
            plexHomeUserID: "kid-uuid",
            plexHomeUserName: "Kiddo",
            plexHomeUserAccountID: "acct-1",
            plexHomeUserRequiresPIN: true,
            plexHomeUserAvatarURL: "https://plex.tv/u/k.png"
        )
        let binding = profile.homeUserBinding(forPlexAccount: "acct-1")
        XCTAssertEqual(binding?.homeUserID, "kid-uuid")
        XCTAssertEqual(binding?.name, "Kiddo")
        XCTAssertEqual(binding?.requiresPIN, true)
        XCTAssertEqual(binding?.avatarURL, "https://plex.tv/u/k.png")
        // A different Plex account on the same profile must NOT inherit it.
        XCTAssertNil(profile.homeUserBinding(forPlexAccount: "acct-2"))
    }

    func testSettingBindingsForTwoPlexAccountsKeepsBothDistinct() {
        var profile = Profile(name: "Me")
        let a = PlexHomeUserBinding(homeUserID: "uid-a", name: "A", requiresPIN: false)
        let b = PlexHomeUserBinding(homeUserID: "uid-b", name: "B", requiresPIN: true)
        profile = profile.settingHomeUserBinding(a, forPlexAccount: "acct-A")
        profile = profile.settingHomeUserBinding(b, forPlexAccount: "acct-B")
        XCTAssertEqual(profile.plexHomeUserBindings?.count, 2)
        XCTAssertEqual(profile.homeUserBinding(forPlexAccount: "acct-A")?.homeUserID, "uid-a")
        XCTAssertEqual(profile.homeUserBinding(forPlexAccount: "acct-B")?.homeUserID, "uid-b")
        // Round-trip through Codable.
        let data = try! JSONEncoder().encode(profile)
        let decoded = try! JSONDecoder().decode(Profile.self, from: data)
        XCTAssertEqual(decoded.homeUserBinding(forPlexAccount: "acct-A")?.homeUserID, "uid-a")
        XCTAssertEqual(decoded.homeUserBinding(forPlexAccount: "acct-B")?.homeUserID, "uid-b")
    }

    func testClearingOneBindingKeepsOthers() {
        var profile = Profile(name: "Me")
        profile = profile.settingHomeUserBinding(
            PlexHomeUserBinding(homeUserID: "uid-a", name: "A"),
            forPlexAccount: "acct-A"
        )
        profile = profile.settingHomeUserBinding(
            PlexHomeUserBinding(homeUserID: "uid-b", name: "B"),
            forPlexAccount: "acct-B"
        )
        profile = profile.settingHomeUserBinding(nil, forPlexAccount: "acct-A")
        XCTAssertNil(profile.homeUserBinding(forPlexAccount: "acct-A"))
        XCTAssertEqual(profile.homeUserBinding(forPlexAccount: "acct-B")?.homeUserID, "uid-b")
    }

    func testSettingBindingMigratesLegacySingleMapping() {
        // Profile starts with only the legacy fields set (as if loaded from
        // an older persisted blob); adding a binding for a NEW account must
        // preserve the legacy account's mapping in the new dict.
        var profile = Profile(
            name: "Me",
            plexHomeUserID: "legacy-uid",
            plexHomeUserName: "Legacy",
            plexHomeUserAccountID: "acct-legacy",
            plexHomeUserRequiresPIN: false
        )
        profile = profile.settingHomeUserBinding(
            PlexHomeUserBinding(homeUserID: "new-uid", name: "New"),
            forPlexAccount: "acct-new"
        )
        XCTAssertEqual(profile.homeUserBinding(forPlexAccount: "acct-legacy")?.homeUserID, "legacy-uid")
        XCTAssertEqual(profile.homeUserBinding(forPlexAccount: "acct-new")?.homeUserID, "new-uid")
    }
}

/// Verifies the per-profile namespacing of the settings stores, including the
/// crucial zero-migration guarantee: `namespace: nil` reads/writes the *legacy*
/// keys, so an upgrading install keeps its existing settings.
final class SettingsNamespaceTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "SettingsNamespaceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testNilNamespaceUsesLegacyThemeKey() {
        let defaults = makeDefaults()
        // Seed the legacy key directly, as an existing install would have.
        defaults.set(AppTheme.pureBlack.rawValue, forKey: "com.plozz.appTheme")
        XCTAssertEqual(ThemeSettingsStore(defaults: defaults, namespace: nil).load(), .pureBlack)
    }

    /// End-to-end zero-migration proof: an existing install's settings (written
    /// under the legacy un-suffixed keys) must be read by the *active default
    /// profile* after the profile system bootstraps. This ties the bootstrapped
    /// default profile's `activeNamespace` to the legacy keys explicitly.
    @MainActor
    func testDefaultProfileReadsPreExistingLegacyKeys() {
        let defaults = makeDefaults()
        // Seed several legacy keys as a pre-profiles install would have.
        defaults.set(AppTheme.pureBlack.rawValue, forKey: "com.plozz.appTheme")
        var spoilerOff = SpoilerSettings.default
        spoilerOff.isEnabled = false
        SpoilerSettingsStore(defaults: defaults, namespace: nil).save(spoilerOff)

        // Bootstrap the profile system over the same defaults (init migrates).
        let model = ProfilesModel(store: ProfileStore(defaults: defaults))

        // The active (default) profile must resolve to the legacy nil namespace.
        XCTAssertNil(model.activeNamespace)

        // Settings stores built from that namespace read the pre-existing values.
        let ns = model.activeNamespace
        XCTAssertEqual(ThemeSettingsStore(defaults: defaults, namespace: ns).load(), .pureBlack)
        XCTAssertFalse(SpoilerSettingsStore(defaults: defaults, namespace: ns).load().isEnabled)
    }

    func testDistinctNamespacesAreIsolated() {
        let defaults = makeDefaults()
        let a = ThemeSettingsStore(defaults: defaults, namespace: "p1")
        let b = ThemeSettingsStore(defaults: defaults, namespace: "p2")
        a.save(.pureBlack)
        b.save(.light)
        XCTAssertEqual(ThemeSettingsStore(defaults: defaults, namespace: "p1").load(), .pureBlack)
        XCTAssertEqual(ThemeSettingsStore(defaults: defaults, namespace: "p2").load(), .light)
        // The default (nil) namespace is independent of both.
        XCTAssertEqual(ThemeSettingsStore(defaults: defaults, namespace: nil).load(), .default)
    }

    func testSpoilerAndDiagnosticsNamespaceIsolation() {
        let defaults = makeDefaults()
        let spoilerDefault = SpoilerSettingsStore(defaults: defaults, namespace: nil)
        let spoilerKid = SpoilerSettingsStore(defaults: defaults, namespace: "kid")
        var off = SpoilerSettings.default
        off.isEnabled = false
        spoilerKid.save(off)
        // Mutating the kid profile must not disturb the default profile.
        XCTAssertEqual(spoilerDefault.load(), .default)
        XCTAssertFalse(SpoilerSettingsStore(defaults: defaults, namespace: "kid").load().isEnabled)
    }

    func testScopedKeyHelper() {
        XCTAssertEqual(SettingsKey.scoped("base", namespace: nil), "base")
        XCTAssertEqual(SettingsKey.scoped("base", namespace: ""), "base")
        XCTAssertEqual(SettingsKey.scoped("base", namespace: "abc"), "base.abc")
    }

    // MARK: importProfiles (Sync & Setup transfer)

    @MainActor
    func testImportProfilesOverwritesSharedIdDefaultCosmetics() {
        let model = ProfilesModel(store: ProfileStore(defaults: makeDefaults()))
        // The pristine local default profile.
        let localDefault = model.profiles.first { $0.id == ProfileStore.defaultProfileID }
        XCTAssertNotNil(localDefault)

        // An incoming default profile (same shared id) with different cosmetics —
        // e.g. transferred from another device where the user picked a sushi emoji.
        var incoming = Profile(id: ProfileStore.defaultProfileID, name: "Brandon")
        incoming.avatarEmoji = "🍣"
        incoming.colorIndex = 7
        model.importProfiles([incoming])

        let merged = model.profiles.first { $0.id == ProfileStore.defaultProfileID }
        XCTAssertEqual(merged?.avatarEmoji, "🍣", "incoming avatar must overwrite the pristine default")
        XCTAssertEqual(merged?.colorIndex, 7)
        XCTAssertEqual(merged?.name, "Brandon")
        XCTAssertEqual(model.profiles.filter { $0.id == ProfileStore.defaultProfileID }.count, 1,
                       "must not duplicate the default profile")
    }

    @MainActor
    func testImportProfilesDoesNotClobberConfiguredReceiversDefault() {
        let model = ProfilesModel(store: ProfileStore(defaults: makeDefaults()))
        // Receiver already finished setup and customized its own default profile.
        model.markFirstRunProfileSetupComplete()
        var localDefault = model.profiles.first { $0.id == ProfileStore.defaultProfileID }!
        localDefault.name = "My Real Profile"
        localDefault.avatarEmoji = "🎬"
        model.update(localDefault)

        // A pairing transfer brings a different default (same shared id).
        var incoming = Profile(id: ProfileStore.defaultProfileID, name: "Someone Else")
        incoming.avatarEmoji = "🍣"
        model.importProfiles([incoming])

        // The receiver's own default is preserved, not overwritten.
        let after = model.profiles.first { $0.id == ProfileStore.defaultProfileID }
        XCTAssertEqual(after?.name, "My Real Profile")
        XCTAssertEqual(after?.avatarEmoji, "🎬")
        XCTAssertEqual(model.profiles.filter { $0.id == ProfileStore.defaultProfileID }.count, 1)
    }
}
