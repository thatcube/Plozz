import XCTest
@testable import CoreModels

final class MusicPlayerSettingsStoreTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "MusicPlayerSettingsStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testDefaultsWhenEmpty() {
        let store = MusicPlayerSettingsStore(defaults: makeDefaults())
        XCTAssertEqual(store.loadAppearance(), .default)
        XCTAssertEqual(store.loadAppearance(), .matchTheme)
        // "Show extra info" is off by default (UserDefaults.bool → false when unset).
        XCTAssertFalse(store.loadShowTrackDetails())
    }

    func testAppearanceRoundTripForEveryCase() {
        let defaults = makeDefaults()
        let store = MusicPlayerSettingsStore(defaults: defaults)
        for appearance in MusicPlayerAppearance.allCases {
            store.saveAppearance(appearance)
            XCTAssertEqual(store.loadAppearance(), appearance, "\(appearance) did not round-trip")
            // A fresh store over the same defaults must read the same value.
            XCTAssertEqual(MusicPlayerSettingsStore(defaults: defaults).loadAppearance(), appearance)
        }
    }

    func testShowTrackDetailsRoundTrip() {
        let defaults = makeDefaults()
        let store = MusicPlayerSettingsStore(defaults: defaults)
        store.saveShowTrackDetails(true)
        XCTAssertTrue(store.loadShowTrackDetails())
        XCTAssertTrue(MusicPlayerSettingsStore(defaults: defaults).loadShowTrackDetails())
        store.saveShowTrackDetails(false)
        XCTAssertFalse(store.loadShowTrackDetails())
        XCTAssertFalse(MusicPlayerSettingsStore(defaults: defaults).loadShowTrackDetails())
    }

    func testCorruptAppearanceFallsBackToDefault() {
        let defaults = makeDefaults()
        defaults.set("not-a-real-appearance", forKey: MusicPlayerAppearance.storageKey)
        XCTAssertEqual(MusicPlayerSettingsStore(defaults: defaults).loadAppearance(), .default)
    }

    /// The primary profile (`namespace == nil`) must keep the legacy un-suffixed
    /// keys so existing installs inherit their values with no migration.
    func testPrimaryProfileUsesLegacyKeys() {
        let defaults = makeDefaults()
        // Seed values directly under the legacy keys, as a pre-per-profile install would.
        defaults.set(MusicPlayerAppearance.oled.rawValue, forKey: "musicPlayerAppearance")
        defaults.set(true, forKey: "musicShowTrackDetails")

        let store = MusicPlayerSettingsStore(defaults: defaults, namespace: nil)
        XCTAssertEqual(store.loadAppearance(), .oled, "primary profile should read the legacy appearance key")
        XCTAssertTrue(store.loadShowTrackDetails(), "primary profile should read the legacy show-details key")
    }

    /// A non-primary profile writes to `"<key>.<namespace>"` and is isolated from
    /// both the primary profile and other namespaces.
    func testNamespaceIsolatesProfiles() {
        let defaults = makeDefaults()
        let primary = MusicPlayerSettingsStore(defaults: defaults, namespace: nil)
        let alice = MusicPlayerSettingsStore(defaults: defaults, namespace: "alice")
        let bob = MusicPlayerSettingsStore(defaults: defaults, namespace: "bob")

        primary.saveAppearance(.dark)
        primary.saveShowTrackDetails(false)
        alice.saveAppearance(.light)
        alice.saveShowTrackDetails(true)
        bob.saveAppearance(.oled)
        bob.saveShowTrackDetails(false)

        // Each profile reads back only its own values.
        XCTAssertEqual(primary.loadAppearance(), .dark)
        XCTAssertFalse(primary.loadShowTrackDetails())
        XCTAssertEqual(alice.loadAppearance(), .light)
        XCTAssertTrue(alice.loadShowTrackDetails())
        XCTAssertEqual(bob.loadAppearance(), .oled)
        XCTAssertFalse(bob.loadShowTrackDetails())

        // A namespaced profile uses the suffixed key, leaving the legacy key untouched.
        XCTAssertEqual(defaults.string(forKey: "musicPlayerAppearance.alice"), MusicPlayerAppearance.light.rawValue)
        XCTAssertEqual(defaults.string(forKey: "musicPlayerAppearance"), MusicPlayerAppearance.dark.rawValue)
    }

    @MainActor
    func testModelPersistsOnChange() {
        let defaults = makeDefaults()
        let model = MusicPlayerSettingsModel(store: MusicPlayerSettingsStore(defaults: defaults))
        XCTAssertEqual(model.appearance, .default)
        XCTAssertFalse(model.showTrackDetails)

        model.appearance = .oled
        model.showTrackDetails = true

        let reloaded = MusicPlayerSettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.loadAppearance(), .oled)
        XCTAssertTrue(reloaded.loadShowTrackDetails())
    }
}
