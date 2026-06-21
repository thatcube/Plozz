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
        XCTAssertEqual(store.activeProfileID(), ProfileStore.defaultProfileID)
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
