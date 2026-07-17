import XCTest
import CoreModels
@testable import FeaturePlayback

/// Tests the per-series audio/subtitle memory collaborator extracted from
/// `PlayerViewModel`. These pin the dual-provider promise: a remembered choice
/// keys first on the cross-server show identity so it follows a show between Plex
/// and Jellyfin, and audio/subtitle reconcile independently.
final class SeriesTrackMemoryTests: XCTestCase {
    /// Dictionary-backed fake store — no persistence, deterministic for tests.
    private final class FakeStore: SeriesTrackPreferenceStoring, @unchecked Sendable {
        var storage: [String: SeriesTrackPreference] = [:]
        func preference(forKey key: String) -> SeriesTrackPreference? { storage[key] }
        func setAudioLanguage(_ language: String?, forKey key: String) {
            var p = storage[key] ?? SeriesTrackPreference()
            p.audioLanguage = language
            storage[key] = p.isEmpty ? nil : p
        }
        func setSubtitle(_ selection: RememberedSubtitleSelection?, forKey key: String) {
            var p = storage[key] ?? SeriesTrackPreference()
            p.subtitle = selection
            storage[key] = p.isEmpty ? nil : p
        }
    }

    private func memory(
        _ store: FakeStore,
        rememberAudio: Bool = true,
        rememberSubtitle: Bool = true,
        accountFallbackID: String? = "acct-a"
    ) -> SeriesTrackMemory {
        SeriesTrackMemory(
            store: store, accountFallbackID: accountFallbackID,
            rememberAudio: rememberAudio, rememberSubtitle: rememberSubtitle)
    }

    private func episode(
        id: String = "ep1",
        seriesID: String? = "series-1",
        sourceAccountID: String? = nil,
        providerIDs: [String: String] = [:]
    ) -> MediaItem {
        MediaItem(
            id: id, title: "Pilot", kind: .episode,
            seriesID: seriesID, providerIDs: providerIDs,
            sourceAccountID: sourceAccountID)
    }

    // MARK: Key derivation

    func testMovieHasNoLocalKey() {
        let m = memory(FakeStore())
        let movie = MediaItem(id: "m1", title: "Film", kind: .movie)
        XCTAssertNil(m.localKey(for: movie))
        XCTAssertTrue(m.crossServerKeys(for: movie).isEmpty)
    }

    func testEpisodeLocalKeyUsesAccountFallback() {
        let m = memory(FakeStore(), accountFallbackID: "acct-a")
        let ep = episode(seriesID: "s9", sourceAccountID: nil)
        XCTAssertEqual(m.localKey(for: ep), "acct-a:s9")
    }

    func testPreferenceKeysPutCrossServerFirst() {
        let m = memory(FakeStore())
        let ep = episode(seriesID: "s1", providerIDs: ["seriestvdb": "12345"])
        XCTAssertEqual(m.preferenceKeys(for: ep), ["show:tvdb:12345", "acct-a:s1"])
    }

    // MARK: Read/write round trips

    func testRecordAndReadAudioNormalizesLanguage() {
        let store = FakeStore()
        let m = memory(store)
        let ep = episode()
        m.recordAudioSelection(language: "eng", for: ep)
        XCTAssertEqual(m.rememberedAudioLanguage(for: ep), "en")
    }

    func testRecordSubtitleOffIsRemembered() {
        let store = FakeStore()
        let m = memory(store)
        let ep = episode()
        m.recordSubtitleSelection(.off, for: ep)
        XCTAssertEqual(m.rememberedSubtitle(for: ep), .off)
    }

    func testAudioToggleOffSuppressesReadAndWrite() {
        let store = FakeStore()
        let m = memory(store, rememberAudio: false)
        let ep = episode()
        m.recordAudioSelection(language: "en", for: ep)
        XCTAssertTrue(store.storage.isEmpty)
        XCTAssertNil(m.rememberedAudioLanguage(for: ep))
    }

    func testNilAudioLanguageNotRemembered() {
        let store = FakeStore()
        let m = memory(store)
        m.recordAudioSelection(language: nil, for: episode())
        XCTAssertTrue(store.storage.isEmpty)
    }

    func testRecordFansOutToAllKeys() {
        let store = FakeStore()
        let m = memory(store)
        let ep = episode(seriesID: "s1", providerIDs: ["seriestvdb": "12345"])
        m.recordAudioSelection(language: "en", for: ep)
        XCTAssertEqual(store.storage["show:tvdb:12345"]?.audioLanguage, "en")
        XCTAssertEqual(store.storage["acct-a:s1"]?.audioLanguage, "en")
    }

    // MARK: Cross-server reconciliation

    func testReconcileImportsCrossServerAudioWhenNotChanged() {
        let store = FakeStore()
        // Cross-server key already holds a choice made on another server.
        store.storage["show:tvdb:12345"] = SeriesTrackPreference(audioLanguage: "ja")
        let m = memory(store)
        let ep = episode(seriesID: "s1", providerIDs: ["seriestvdb": "12345"])

        let outcome = m.reconcile(item: ep, viewerChangedAudio: false, viewerChangedSubtitle: false)

        XCTAssertEqual(outcome.importedAudioLanguage, "ja")
        // Backfilled onto the per-server key so later same-server episodes resolve it.
        XCTAssertEqual(store.storage["acct-a:s1"]?.audioLanguage, "ja")
    }

    func testReconcileMirrorsViewerAudioChangeOntoAllKeys() {
        let store = FakeStore()
        // A switch made before enrich resolved wrote only the per-server key.
        store.storage["acct-a:s1"] = SeriesTrackPreference(audioLanguage: "fr")
        let m = memory(store)
        let ep = episode(seriesID: "s1", providerIDs: ["seriestvdb": "12345"])

        let outcome = m.reconcile(item: ep, viewerChangedAudio: true, viewerChangedSubtitle: false)

        XCTAssertNil(outcome.importedAudioLanguage)
        XCTAssertEqual(store.storage["show:tvdb:12345"]?.audioLanguage, "fr")
    }

    func testReconcileSignalsSubtitleReapplyOnImport() {
        let store = FakeStore()
        store.storage["show:tvdb:12345"] = SeriesTrackPreference(subtitle: .language("en"))
        let m = memory(store)
        let ep = episode(seriesID: "s1", providerIDs: ["seriestvdb": "12345"])

        let outcome = m.reconcile(item: ep, viewerChangedAudio: false, viewerChangedSubtitle: false)

        XCTAssertTrue(outcome.shouldReapplyInitialSubtitle)
        XCTAssertEqual(store.storage["acct-a:s1"]?.subtitle, .language("en"))
    }

    func testReconcileNoCrossKeysIsNoOp() {
        let store = FakeStore()
        store.storage["acct-a:s1"] = SeriesTrackPreference(audioLanguage: "en")
        let m = memory(store)
        let ep = episode(seriesID: "s1") // no external ids -> no cross-server keys

        let outcome = m.reconcile(item: ep, viewerChangedAudio: false, viewerChangedSubtitle: false)

        XCTAssertEqual(outcome, SeriesTrackMemory.ReconcileOutcome())
    }
}
