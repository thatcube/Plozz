import XCTest
@testable import CoreModels

/// Tests for the per-profile per-series remembered audio/subtitle preference
/// store: a manual track switch is remembered by language and re-applied to the
/// rest of that show's episodes.
final class SeriesTrackPreferenceStoreTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        let suite = "SeriesTrackPreferenceStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    // MARK: - Key

    func testKeyNamespacesBySourceAccount() {
        let a = SeriesTrackPreferenceKey.make(sourceAccountID: "plex:1", seriesID: "show")
        let b = SeriesTrackPreferenceKey.make(sourceAccountID: "jellyfin:2", seriesID: "show")
        XCTAssertNotEqual(a, b, "the same series id on two servers must not collide")
    }

    func testKeyHandlesMissingAccount() {
        XCTAssertEqual(SeriesTrackPreferenceKey.make(sourceAccountID: nil, seriesID: "s"), "_:s")
    }

    // MARK: - Cross-server identity keys

    func testCrossServerKeysFromSeriesExternalIDs() {
        let keys = SeriesTrackPreferenceKey.crossServerKeys(providerIDs: [
            "SeriesTvdb": "12345",
            "SeriesImdb": "tt67890"
        ])
        XCTAssertEqual(keys, ["show:tvdb:12345", "show:imdb:tt67890"],
                       "one key per available external id, in priority order")
    }

    func testCrossServerKeysLowercaseAndTrim() {
        let keys = SeriesTrackPreferenceKey.crossServerKeys(providerIDs: [
            "SeriesImdb": "  TT00042  "
        ])
        XCTAssertEqual(keys, ["show:imdb:tt00042"], "values are trimmed and lowercased to match cross-server")
    }

    func testCrossServerKeysEmptyWithoutSeriesIDs() {
        // Episode-level ids (no Series* prefix) must NOT produce a cross-server key.
        XCTAssertTrue(SeriesTrackPreferenceKey.crossServerKeys(providerIDs: [
            "Tvdb": "999",
            "Imdb": "tt1"
        ]).isEmpty)
    }

    func testCrossServerKeysIgnoreEmptyValues() {
        XCTAssertTrue(SeriesTrackPreferenceKey.crossServerKeys(providerIDs: [
            "SeriesTvdb": "   "
        ]).isEmpty)
    }

    func testCrossServerKeyStableAcrossServers() {
        // The same show served by Plex (with TVDB) and Jellyfin (with TVDB+TMDB)
        // shares the TVDB key, so a preference written under one is found by the other.
        let plex = SeriesTrackPreferenceKey.crossServerKeys(providerIDs: ["SeriesTvdb": "555"])
        let jellyfin = SeriesTrackPreferenceKey.crossServerKeys(providerIDs: [
            "SeriesTvdb": "555", "SeriesTmdb": "888"
        ])
        XCTAssertEqual(plex.first, "show:tvdb:555")
        XCTAssertTrue(jellyfin.contains("show:tvdb:555"), "a shared external id keeps the key stable across servers")
    }

    func testCrossServerTransferReadsPreferenceWrittenUnderSharedKey() {
        let store = SeriesTrackPreferenceStore(defaults: makeDefaults())
        // Watched on Plex: choice stored under the shared cross-server key.
        let plexKeys = SeriesTrackPreferenceKey.crossServerKeys(providerIDs: ["SeriesTvdb": "555"])
        for key in plexKeys { store.setAudioLanguage("ja", forKey: key) }

        // Next episode only on Jellyfin: it resolves the same TVDB key and finds the choice.
        let jellyfinKeys = SeriesTrackPreferenceKey.crossServerKeys(providerIDs: [
            "SeriesTvdb": "555", "SeriesTmdb": "888"
        ])
        let found = jellyfinKeys.compactMap { store.preference(forKey: $0)?.audioLanguage }.first
        XCTAssertEqual(found, "ja", "audio choice transfers between servers via the shared series id")
    }

    // MARK: - Audio

    func testRecordsAndReadsAudioLanguage() {
        let store = SeriesTrackPreferenceStore(defaults: makeDefaults())
        let key = SeriesTrackPreferenceKey.make(sourceAccountID: "a", seriesID: "show")
        XCTAssertNil(store.preference(forKey: key))

        store.setAudioLanguage("ja", forKey: key)
        XCTAssertEqual(store.preference(forKey: key)?.audioLanguage, "ja")
        XCTAssertNil(store.preference(forKey: key)?.subtitle)
    }

    func testAudioAndSubtitleCoexistOnSameSeries() {
        let store = SeriesTrackPreferenceStore(defaults: makeDefaults())
        let key = SeriesTrackPreferenceKey.make(sourceAccountID: "a", seriesID: "show")
        store.setAudioLanguage("ja", forKey: key)
        store.setSubtitle(.language("en"), forKey: key)

        let pref = store.preference(forKey: key)
        XCTAssertEqual(pref?.audioLanguage, "ja")
        XCTAssertEqual(pref?.subtitle, .language("en"))
    }

    func testLaterAudioWriteOverwritesEarlier() {
        let store = SeriesTrackPreferenceStore(defaults: makeDefaults())
        let key = SeriesTrackPreferenceKey.make(sourceAccountID: "a", seriesID: "show")
        store.setAudioLanguage("ja", forKey: key)
        store.setAudioLanguage("en", forKey: key)
        XCTAssertEqual(store.preference(forKey: key)?.audioLanguage, "en")
    }

    // MARK: - Subtitle (off vs language)

    func testRecordsSubtitleOff() {
        let store = SeriesTrackPreferenceStore(defaults: makeDefaults())
        let key = SeriesTrackPreferenceKey.make(sourceAccountID: "a", seriesID: "show")
        store.setSubtitle(.off, forKey: key)
        XCTAssertEqual(store.preference(forKey: key)?.subtitle, .off)
    }

    func testRecordsSubtitleLanguage() {
        let store = SeriesTrackPreferenceStore(defaults: makeDefaults())
        let key = SeriesTrackPreferenceKey.make(sourceAccountID: "a", seriesID: "show")
        store.setSubtitle(.language("en"), forKey: key)
        XCTAssertEqual(store.preference(forKey: key)?.subtitle, .language("en"))
    }

    func testSwitchingSubtitleFromLanguageToOffSticks() {
        let store = SeriesTrackPreferenceStore(defaults: makeDefaults())
        let key = SeriesTrackPreferenceKey.make(sourceAccountID: "a", seriesID: "show")
        store.setSubtitle(.language("en"), forKey: key)
        store.setSubtitle(.off, forKey: key)
        XCTAssertEqual(store.preference(forKey: key)?.subtitle, .off)
    }

    // MARK: - Empty-entry dropping

    func testClearingAudioOnlyEntryDropsEntry() {
        let defaults = makeDefaults()
        let store = SeriesTrackPreferenceStore(defaults: defaults)
        let key = SeriesTrackPreferenceKey.make(sourceAccountID: "a", seriesID: "show")
        store.setAudioLanguage("ja", forKey: key)
        store.setAudioLanguage(nil, forKey: key)
        XCTAssertNil(store.preference(forKey: key), "an entry with nothing remembered is dropped")
    }

    func testClearingSubtitleKeepsRememberedAudio() {
        let store = SeriesTrackPreferenceStore(defaults: makeDefaults())
        let key = SeriesTrackPreferenceKey.make(sourceAccountID: "a", seriesID: "show")
        store.setAudioLanguage("ja", forKey: key)
        store.setSubtitle(.language("en"), forKey: key)
        store.setSubtitle(nil, forKey: key)

        let pref = store.preference(forKey: key)
        XCTAssertEqual(pref?.audioLanguage, "ja", "clearing the subtitle leaves the audio memory intact")
        XCTAssertNil(pref?.subtitle)
    }

    // MARK: - Persistence + isolation

    func testPersistsAcrossStoreInstances() {
        let defaults = makeDefaults()
        let key = SeriesTrackPreferenceKey.make(sourceAccountID: "a", seriesID: "show")
        SeriesTrackPreferenceStore(defaults: defaults).setAudioLanguage("ja", forKey: key)

        let reopened = SeriesTrackPreferenceStore(defaults: defaults)
        XCTAssertEqual(reopened.preference(forKey: key)?.audioLanguage, "ja")
    }

    func testNamespaceIsolatesProfiles() {
        let defaults = makeDefaults()
        let key = SeriesTrackPreferenceKey.make(sourceAccountID: "a", seriesID: "show")
        let primary = SeriesTrackPreferenceStore(defaults: defaults, namespace: nil)
        let other = SeriesTrackPreferenceStore(defaults: defaults, namespace: "profile-b")

        primary.setAudioLanguage("ja", forKey: key)
        XCTAssertEqual(primary.preference(forKey: key)?.audioLanguage, "ja")
        XCTAssertNil(other.preference(forKey: key), "a second profile has independent series memory")
    }

    func testDistinctSeriesDoNotInterfere() {
        let store = SeriesTrackPreferenceStore(defaults: makeDefaults())
        let show = SeriesTrackPreferenceKey.make(sourceAccountID: "a", seriesID: "show")
        let other = SeriesTrackPreferenceKey.make(sourceAccountID: "a", seriesID: "other")
        store.setAudioLanguage("ja", forKey: show)
        store.setSubtitle(.off, forKey: other)

        XCTAssertEqual(store.preference(forKey: show)?.audioLanguage, "ja")
        XCTAssertNil(store.preference(forKey: show)?.subtitle)
        XCTAssertEqual(store.preference(forKey: other)?.subtitle, .off)
        XCTAssertNil(store.preference(forKey: other)?.audioLanguage)
    }
}
