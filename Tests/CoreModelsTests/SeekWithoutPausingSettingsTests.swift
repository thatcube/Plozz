import XCTest
@testable import CoreModels

/// Covers the per-profile "seek without pausing" toggle on `PlaybackSettings`:
/// the default is ON (today's scrub-while-playing behaviour), it round-trips per
/// profile, and an older payload written before the field existed still decodes
/// to ON so upgrades keep the current feel.
final class SeekWithoutPausingSettingsTests: XCTestCase {

    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "SeekWithoutPausingSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }

    func testDefaultIsSeekWithoutPausingOn() {
        XCTAssertTrue(PlaybackSettings.default.seekWithoutPausing,
                      "Default must preserve today's scrub-while-playing behaviour")
    }

    func testRoundTripsFlag() {
        let (defaults, _) = makeDefaults()
        let store = PlaybackSettingsStore(defaults: defaults)
        var settings = store.load()
        settings.seekWithoutPausing = false
        store.save(settings)
        XCTAssertFalse(store.load().seekWithoutPausing)
        XCTAssertEqual(store.load().skipIntros, .off, "Unrelated fields stay intact")
        XCTAssertTrue(store.load().syncWatchAcrossServers, "Unrelated fields stay intact")
    }

    func testLegacyPayloadWithoutFieldDecodesToOn() throws {
        // A payload written before `seekWithoutPausing` existed.
        let (defaults, _) = makeDefaults()
        let key = SettingsKey.scoped("com.plozz.playbackSettings", namespace: nil)
        let legacy = try JSONSerialization.data(
            withJSONObject: ["skipIntros": "on", "syncWatchAcrossServers": false])
        defaults.set(legacy, forKey: key)

        let store = PlaybackSettingsStore(defaults: defaults)
        let loaded = store.load()
        XCTAssertEqual(loaded.skipIntros, .on)
        XCTAssertFalse(loaded.syncWatchAcrossServers, "Existing fields still decode")
        XCTAssertTrue(loaded.seekWithoutPausing,
                      "Missing field must default to ON so upgrades keep current scrubbing")
    }

    func testPerProfileNamespacingIsIndependent() {
        let (defaults, _) = makeDefaults()
        let primary = PlaybackSettingsStore(defaults: defaults, namespace: nil)
        let guestNS = "guest-profile"
        let guest = PlaybackSettingsStore(defaults: defaults, namespace: guestNS)

        var off = PlaybackSettings.default
        off.seekWithoutPausing = false
        guest.save(off)

        XCTAssertFalse(guest.load().seekWithoutPausing, "Guest profile is OFF")
        XCTAssertTrue(primary.load().seekWithoutPausing, "Primary profile is unaffected (still default ON)")
    }
}
