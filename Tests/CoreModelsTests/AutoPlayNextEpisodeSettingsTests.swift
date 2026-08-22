import XCTest
@testable import CoreModels

/// Covers the per-profile "Autoplay next episode" toggle on `PlaybackSettings`
/// (#22): the default is ON (the behaviour the player has always had), it
/// round-trips per profile, an older payload decodes to ON so upgrades are
/// unchanged, and it is genuinely independent of the Up Next card.
final class AutoPlayNextEpisodeSettingsTests: XCTestCase {

    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "AutoPlayNextEpisodeSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }

    func testDefaultIsAutoPlayOn() {
        XCTAssertTrue(PlaybackSettings.default.autoPlayNextEpisode,
                      "Default must keep advancing — the setting only ever takes that away")
    }

    func testRoundTripsFlag() {
        let (defaults, _) = makeDefaults()
        let store = PlaybackSettingsStore(defaults: defaults)
        var settings = store.load()
        settings.autoPlayNextEpisode = false
        store.save(settings)
        XCTAssertFalse(store.load().autoPlayNextEpisode)
        XCTAssertTrue(store.load().showUpNextCard, "Unrelated fields stay intact")
        XCTAssertEqual(store.load().skipIntros, .off, "Unrelated fields stay intact")
    }

    func testLegacyPayloadWithoutFieldDecodesToOn() throws {
        let (defaults, _) = makeDefaults()
        let key = SettingsKey.scoped("com.plozz.playbackSettings", namespace: nil)
        let legacy = try JSONSerialization.data(
            withJSONObject: ["skipIntros": "on", "showUpNextCard": false])
        defaults.set(legacy, forKey: key)

        let loaded = PlaybackSettingsStore(defaults: defaults).load()
        XCTAssertEqual(loaded.skipIntros, .on)
        XCTAssertFalse(loaded.showUpNextCard, "Existing fields still decode")
        XCTAssertTrue(loaded.autoPlayNextEpisode,
                      "Missing field must default to ON so an upgrade behaves exactly as before")
    }

    /// The point of the issue: these are two switches, not one. Every combination
    /// has to be storable, including the previously impossible "advance, but don't
    /// announce it" and "announce it, but don't advance".
    func testAutoPlayAndUpNextCardAreIndependent() {
        let (defaults, _) = makeDefaults()
        let store = PlaybackSettingsStore(defaults: defaults)

        for (autoPlay, card) in [(true, true), (true, false), (false, true), (false, false)] {
            var settings = PlaybackSettings.default
            settings.autoPlayNextEpisode = autoPlay
            settings.showUpNextCard = card
            store.save(settings)

            let loaded = store.load()
            XCTAssertEqual(loaded.autoPlayNextEpisode, autoPlay, "autoPlay=\(autoPlay) card=\(card)")
            XCTAssertEqual(loaded.showUpNextCard, card, "autoPlay=\(autoPlay) card=\(card)")
        }
    }

    func testPerProfileNamespacingIsIndependent() {
        let (defaults, _) = makeDefaults()
        let primary = PlaybackSettingsStore(defaults: defaults, namespace: nil)
        let guest = PlaybackSettingsStore(defaults: defaults, namespace: "guest-profile")

        var off = PlaybackSettings.default
        off.autoPlayNextEpisode = false
        guest.save(off)

        XCTAssertFalse(guest.load().autoPlayNextEpisode, "Guest profile is OFF")
        XCTAssertTrue(primary.load().autoPlayNextEpisode, "Primary profile is unaffected")
    }
}
