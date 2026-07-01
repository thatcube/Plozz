import XCTest
@testable import CoreModels

/// Covers the per-profile "Show Up Next card" toggle on `PlaybackSettings`: the
/// default is ON (so existing installs get the closing-credits next-episode
/// card), it round-trips per profile, and an older payload written before the
/// field existed still decodes to ON so upgrades keep the new behaviour.
final class ShowUpNextCardSettingsTests: XCTestCase {

    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "ShowUpNextCardSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }

    func testDefaultIsShowUpNextCardOn() {
        XCTAssertTrue(PlaybackSettings.default.showUpNextCard,
                      "Default must offer the Up Next card during episode credits")
    }

    func testRoundTripsFlag() {
        let (defaults, _) = makeDefaults()
        let store = PlaybackSettingsStore(defaults: defaults)
        var settings = store.load()
        settings.showUpNextCard = false
        store.save(settings)
        XCTAssertFalse(store.load().showUpNextCard)
        XCTAssertEqual(store.load().skipIntros, .off, "Unrelated fields stay intact")
        XCTAssertTrue(store.load().seekWithoutPausing, "Unrelated fields stay intact")
    }

    func testLegacyPayloadWithoutFieldDecodesToOn() throws {
        // A payload written before `showUpNextCard` existed.
        let (defaults, _) = makeDefaults()
        let key = SettingsKey.scoped("com.plozz.playbackSettings", namespace: nil)
        let legacy = try JSONSerialization.data(
            withJSONObject: ["skipIntros": "on", "seekWithoutPausing": false])
        defaults.set(legacy, forKey: key)

        let store = PlaybackSettingsStore(defaults: defaults)
        let loaded = store.load()
        XCTAssertEqual(loaded.skipIntros, .on)
        XCTAssertFalse(loaded.seekWithoutPausing, "Existing fields still decode")
        XCTAssertTrue(loaded.showUpNextCard,
                      "Missing field must default to ON so upgrades get the Up Next card")
    }

    func testPerProfileNamespacingIsIndependent() {
        let (defaults, _) = makeDefaults()
        let primary = PlaybackSettingsStore(defaults: defaults, namespace: nil)
        let guestNS = "guest-profile"
        let guest = PlaybackSettingsStore(defaults: defaults, namespace: guestNS)

        var off = PlaybackSettings.default
        off.showUpNextCard = false
        guest.save(off)

        XCTAssertFalse(guest.load().showUpNextCard, "Guest profile is OFF")
        XCTAssertTrue(primary.load().showUpNextCard, "Primary profile is unaffected (still default ON)")
    }
}
