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
        defaults.set(AppTheme.oled.rawValue, forKey: "com.plozz.appTheme")
        XCTAssertEqual(ThemeSettingsStore(defaults: defaults, namespace: nil).load(), .oled)
    }

    /// End-to-end zero-migration proof: an existing install's settings (written
    /// under the legacy un-suffixed keys) must be read by the *active default
    /// profile* after the profile system bootstraps. This ties the bootstrapped
    /// default profile's `activeNamespace` to the legacy keys explicitly.
    @MainActor
    func testDefaultProfileReadsPreExistingLegacyKeys() {
        let defaults = makeDefaults()
        // Seed several legacy keys as a pre-profiles install would have.
        defaults.set(AppTheme.oled.rawValue, forKey: "com.plozz.appTheme")
        var spoilerOff = SpoilerSettings.default
        spoilerOff.isEnabled = false
        SpoilerSettingsStore(defaults: defaults, namespace: nil).save(spoilerOff)

        // Bootstrap the profile system over the same defaults (init migrates).
        let model = ProfilesModel(store: ProfileStore(defaults: defaults))

        // The active (default) profile must resolve to the legacy nil namespace.
        XCTAssertNil(model.activeNamespace)

        // Settings stores built from that namespace read the pre-existing values.
        let ns = model.activeNamespace
        XCTAssertEqual(ThemeSettingsStore(defaults: defaults, namespace: ns).load(), .oled)
        XCTAssertFalse(SpoilerSettingsStore(defaults: defaults, namespace: ns).load().isEnabled)
    }

    func testDistinctNamespacesAreIsolated() {
        let defaults = makeDefaults()
        let a = ThemeSettingsStore(defaults: defaults, namespace: "p1")
        let b = ThemeSettingsStore(defaults: defaults, namespace: "p2")
        a.save(.oled)
        b.save(.light)
        XCTAssertEqual(ThemeSettingsStore(defaults: defaults, namespace: "p1").load(), .oled)
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
}
