import XCTest
@testable import CoreModels

/// Covers the cross-server watch-sync toggle that rides on `PlaybackSettings`:
/// the default is ON (today's behaviour), it round-trips per profile, an older
/// payload written before the field existed still decodes to ON (upgrade-safe),
/// and the off-main `@Sendable` static reader sees the persisted value.
final class PlaybackSyncSettingsTests: XCTestCase {

    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "PlaybackSyncSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }

    func testDefaultIsSyncOn() {
        XCTAssertTrue(PlaybackSettings.default.syncWatchAcrossServers,
                      "Default must preserve today's cross-server fan-out")
    }

    func testRoundTripsSyncFlag() {
        let (defaults, _) = makeDefaults()
        let store = PlaybackSettingsStore(defaults: defaults)
        var settings = store.load()
        settings.syncWatchAcrossServers = false
        store.save(settings)
        XCTAssertFalse(store.load().syncWatchAcrossServers)
        XCTAssertEqual(store.load().skipIntros, .off, "Unrelated fields stay intact")
    }

    func testLegacyPayloadWithoutFieldDecodesToOn() throws {
        // A payload written before `syncWatchAcrossServers` existed (only skipIntros).
        let (defaults, _) = makeDefaults()
        let key = SettingsKey.scoped("com.plozz.playbackSettings", namespace: nil)
        let legacy = try JSONSerialization.data(withJSONObject: ["skipIntros": "on"])
        defaults.set(legacy, forKey: key)

        let store = PlaybackSettingsStore(defaults: defaults)
        let loaded = store.load()
        XCTAssertEqual(loaded.skipIntros, .on)
        XCTAssertTrue(loaded.syncWatchAcrossServers,
                      "Missing field must default to ON so upgrades keep syncing")
    }

    func testPerProfileNamespacingIsIndependent() {
        let (defaults, _) = makeDefaults()
        let primary = PlaybackSettingsStore(defaults: defaults, namespace: nil)
        let guestNS = "guest-profile"
        let guest = PlaybackSettingsStore(defaults: defaults, namespace: guestNS)

        var off = PlaybackSettings.default
        off.syncWatchAcrossServers = false
        guest.save(off)

        XCTAssertFalse(guest.load().syncWatchAcrossServers, "Guest profile is OFF")
        XCTAssertTrue(primary.load().syncWatchAcrossServers, "Primary profile is unaffected (still default ON)")
    }

    func testStaticReaderSeesPersistedValueOffMain() {
        let (defaults, _) = makeDefaults()
        let ns = "p1"
        // Nothing persisted yet ⇒ default ON.
        XCTAssertTrue(PlaybackSettingsStore.currentSyncAcrossServers(defaults: defaults, namespace: ns))

        var off = PlaybackSettings.default
        off.syncWatchAcrossServers = false
        PlaybackSettingsStore(defaults: defaults, namespace: ns).save(off)

        XCTAssertFalse(PlaybackSettingsStore.currentSyncAcrossServers(defaults: defaults, namespace: ns),
                       "Static reader must observe the freshly persisted OFF value")
    }

    // MARK: Audio-language preference (migration from the legacy boolean)

    func testDefaultAudioPreferenceIsOriginal() {
        XCTAssertEqual(PlaybackSettings.default.audioLanguagePreference, .original,
                       "Default preserves today's prefer-original behaviour")
    }

    func testLegacyPreferOriginalTrueMigratesToOriginal() throws {
        let (defaults, _) = makeDefaults()
        let key = SettingsKey.scoped("com.plozz.playbackSettings", namespace: nil)
        let legacy = try JSONSerialization.data(withJSONObject: ["preferOriginalLanguageAudio": true])
        defaults.set(legacy, forKey: key)

        let loaded = PlaybackSettingsStore(defaults: defaults).load()
        XCTAssertEqual(loaded.audioLanguagePreference, .original,
                       "Legacy prefer-original=true maps to .original")
    }

    func testLegacyPreferOriginalFalseMigratesToDevice() throws {
        let (defaults, _) = makeDefaults()
        let key = SettingsKey.scoped("com.plozz.playbackSettings", namespace: nil)
        let legacy = try JSONSerialization.data(withJSONObject: ["preferOriginalLanguageAudio": false])
        defaults.set(legacy, forKey: key)

        let loaded = PlaybackSettingsStore(defaults: defaults).load()
        XCTAssertEqual(loaded.audioLanguagePreference, .device,
                       "Legacy prefer-original=false maps to .device")
    }

    func testAudioPreferenceRoundTripsAndPrefersNewKeyOverLegacy() throws {
        let (defaults, _) = makeDefaults()
        let store = PlaybackSettingsStore(defaults: defaults)
        var settings = store.load()
        settings.audioLanguagePreference = .language("en")
        store.save(settings)
        XCTAssertEqual(store.load().audioLanguagePreference, .language("en"))

        // A payload carrying BOTH the new key and the stale legacy bool: the new
        // key must win so a re-save never resurrects an old choice.
        let key = SettingsKey.scoped("com.plozz.playbackSettings", namespace: nil)
        let both = try JSONSerialization.data(withJSONObject: [
            "audioLanguagePreference": "lang:ko",
            "preferOriginalLanguageAudio": true
        ])
        defaults.set(both, forKey: key)
        XCTAssertEqual(store.load().audioLanguagePreference, .language("ko"),
                       "The new preference key takes precedence over the legacy bool")
    }

    func testMissingAudioFieldDefaultsToOriginal() throws {
        let (defaults, _) = makeDefaults()
        let key = SettingsKey.scoped("com.plozz.playbackSettings", namespace: nil)
        let legacy = try JSONSerialization.data(withJSONObject: ["skipIntros": "on"])
        defaults.set(legacy, forKey: key)
        XCTAssertEqual(PlaybackSettingsStore(defaults: defaults).load().audioLanguagePreference, .original,
                       "Missing audio field defaults to .original")
    }
}
