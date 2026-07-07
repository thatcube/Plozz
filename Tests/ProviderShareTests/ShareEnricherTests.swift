import XCTest
@testable import ProviderShare
import CoreModels

/// Coverage for Phase 2 enrichment: the scan-time pass that stamps external ids +
/// overview + artwork onto indexed items and persists it, so a share merges with
/// its Plex/Jellyfin twin, pulls ratings, and shows rich detail. A fake resolver
/// keeps these hermetic (no network).
final class ShareEnricherTests: XCTestCase {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("plozz-share-enrich-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private func movie(_ path: String, _ title: String, _ year: Int?) -> CatalogAsset {
        CatalogAsset(relPath: path, basename: (path as NSString).lastPathComponent, size: 1, modifiedAt: Date(),
                     kind: .movie, library: .movies, title: title, year: year,
                     seriesTitle: nil, seriesKey: nil, season: nil, episode: nil)
    }
    private func episode(_ path: String, series: String, s: Int, e: Int, library: CatalogLibrary = .tv) -> CatalogAsset {
        CatalogAsset(relPath: path, basename: (path as NSString).lastPathComponent, size: 1, modifiedAt: Date(),
                     kind: .episode, library: library, title: "Ep \(e)", year: nil,
                     seriesTitle: series, seriesKey: ShareCatalogID.seriesKey(fromTitle: series), season: s, episode: e)
    }

    /// Records requests and returns canned metadata keyed by title.
    private struct FakeResolver: ShareMetadataResolving {
        let byTitle: [String: ShareCatalogStore.EnrichmentRecord]
        func resolve(_ request: ShareEnrichRequest) async -> ShareCatalogStore.EnrichmentRecord {
            byTitle[request.title] ?? ShareCatalogStore.EnrichmentRecord()
        }
    }

    func testEnrichmentStampsIDsOverviewAndArtOntoItems() async {
        let store = ShareCatalogStore(accountKey: "a", directory: tempDir())
        await store.upsert([movie("Movies/The Matrix (1999).mkv", "The Matrix", 1999)], scanID: 1)

        let rec = ShareCatalogStore.EnrichmentRecord(
            providerIDs: ["Imdb": "tt0133093", "Tmdb": "603"],
            overview: "A hacker learns the truth.",
            genres: ["Sci-Fi"],
            runtime: 8160,
            posterURL: URL(string: "https://img/poster.jpg"),
            backdropURL: URL(string: "https://img/backdrop.jpg"),
            logoURL: URL(string: "https://img/logo.png")
        )
        let enricher = ShareEnricher(store: store, resolver: FakeResolver(byTitle: ["The Matrix": rec]))
        await enricher.enrichPending()

        let item = await store.item(id: ShareCatalogID.file("Movies/The Matrix (1999).mkv"))
        XCTAssertEqual(item?.providerIDs["Imdb"], "tt0133093")
        XCTAssertEqual(item?.providerID(.tmdb), "603")
        XCTAssertEqual(item?.overview, "A hacker learns the truth.")
        XCTAssertEqual(item?.posterURL?.absoluteString, "https://img/poster.jpg")
        XCTAssertEqual(item?.backdropURL?.absoluteString, "https://img/backdrop.jpg")
        XCTAssertEqual(item?.logoURL?.absoluteString, "https://img/logo.png")
    }

    func testProviderIDsEnableCrossServerIdentity() async {
        // The whole point: a share item that gains a TMDb id now produces the same
        // MediaItemIdentity a Plex/Jellyfin twin would, so the merge engine fuses them.
        let store = ShareCatalogStore(accountKey: "a", directory: tempDir())
        await store.upsert([movie("Movies/Inception (2010).mkv", "Inception", 2010)], scanID: 1)
        let rec = ShareCatalogStore.EnrichmentRecord(providerIDs: ["Tmdb": "27205"])
        await ShareEnricher(store: store, resolver: FakeResolver(byTitle: ["Inception": rec])).enrichPending()

        let shareItem = await store.item(id: ShareCatalogID.file("Movies/Inception (2010).mkv"))!
        let serverTwin = MediaItem(id: "plex-999", title: "Inception", kind: .movie, providerIDs: ["Tmdb": "27205"])
        let shareIDs = Set(MediaItemIdentity.identities(for: shareItem).map { "\($0)" })
        let twinIDs = Set(MediaItemIdentity.identities(for: serverTwin).map { "\($0)" })
        XCTAssertFalse(shareIDs.isDisjoint(with: twinIDs), "share + server twin must share an identity so they merge")
    }

    func testAniListIDReclassifiesSeriesToAnime() async {
        // A series indexed under TV that resolves an AniList/MAL id is confirmed
        // anime and must move to the Anime library.
        let store = ShareCatalogStore(accountKey: "a", directory: tempDir())
        await store.upsert([
            episode("TV/Frieren/S01E01.mkv", series: "Frieren", s: 1, e: 1, library: .tv),
        ], scanID: 1)
        let initial = await store.libraryCounts()
        XCTAssertEqual(initial.tvSeries, 1)

        let key = ShareCatalogID.seriesKey(fromTitle: "Frieren")
        let rec = ShareCatalogStore.EnrichmentRecord(providerIDs: ["AniList": "154587", "Mal": "52991"])
        await ShareEnricher(store: store, resolver: FakeResolver(byTitle: ["Frieren": rec])).enrichPending()

        let counts = await store.libraryCounts()
        XCTAssertEqual(counts.tvSeries, 0, "should have moved out of TV")
        XCTAssertEqual(counts.animeSeries, 1, "AniList id confirms it as anime")
    }

    func testEnrichmentIsIdempotentAndNotReFetched() async {
        let store = ShareCatalogStore(accountKey: "a", directory: tempDir())
        await store.upsert([movie("Movies/A (2000).mkv", "A", 2000)], scanID: 1)

        actor Counter { var n = 0; func bump() { n += 1 }; var value: Int { n } }
        let counter = Counter()
        struct CountingResolver: ShareMetadataResolving {
            let counter: Counter
            func resolve(_ request: ShareEnrichRequest) async -> ShareCatalogStore.EnrichmentRecord {
                await counter.bump()
                return ShareCatalogStore.EnrichmentRecord(providerIDs: ["Tmdb": "1"])
            }
        }
        let enricher = ShareEnricher(store: store, resolver: CountingResolver(counter: counter))
        await enricher.enrichPending()
        let afterFirst = await counter.value
        XCTAssertEqual(afterFirst, 1)

        // A second pass finds nothing pending (already at current version) → no re-fetch.
        await enricher.enrichPending()
        let afterSecond = await counter.value
        XCTAssertEqual(afterSecond, 1, "an already-enriched item is not resolved again")
    }

    func testPendingShrinksAsItemsAreEnriched() async {
        let store = ShareCatalogStore(accountKey: "a", directory: tempDir())
        await store.upsert([
            movie("Movies/A (2000).mkv", "A", 2000),
            movie("Movies/B (2001).mkv", "B", 2001),
        ], scanID: 1)
        let before = await store.pendingEnrichment(version: ShareEnricher.version, limit: 10)
        XCTAssertEqual(before.count, 2)

        await ShareEnricher(store: store, resolver: FakeResolver(byTitle: [:])).enrichPending()
        let after = await store.pendingEnrichment(version: ShareEnricher.version, limit: 10)
        XCTAssertTrue(after.isEmpty, "every pending item was attempted and marked at the current version")
    }

    func testSingleItemPendingLookupTargetsTheOpenedItem() async {
        let store = ShareCatalogStore(accountKey: "a", directory: tempDir())
        await store.upsert([movie("Movies/Dune (2021).mkv", "Dune", 2021)], scanID: 1)
        let id = ShareCatalogID.file("Movies/Dune (2021).mkv")

        let pending = await store.pendingEnrichment(forItemID: id, version: ShareEnricher.version)
        XCTAssertEqual(pending?.itemID, id)
        XCTAssertEqual(pending?.title, "Dune")
        XCTAssertEqual(pending?.year, 2021)
        XCTAssertEqual(pending?.isMovie, true)

        // Once enriched, the same lookup reports nothing pending.
        await store.saveEnrichment(itemID: id, .init(providerIDs: ["Tmdb": "438631"]), version: ShareEnricher.version)
        let after = await store.pendingEnrichment(forItemID: id, version: ShareEnricher.version)
        XCTAssertNil(after, "an already-enriched item is not pending")
    }

    func testEnrichOneFastTracksTheOpenedItemOnly() async {
        // Two indexed movies; enrichOne must persist art for the ONE we open and
        // leave the other still pending for the background drain.
        let store = ShareCatalogStore(accountKey: "a", directory: tempDir())
        await store.upsert([
            movie("Movies/Arrival (2016).mkv", "Arrival", 2016),
            movie("Movies/Sicario (2015).mkv", "Sicario", 2015),
        ], scanID: 1)
        let opened = ShareCatalogID.file("Movies/Arrival (2016).mkv")
        let rec = ShareCatalogStore.EnrichmentRecord(
            providerIDs: ["Tmdb": "329865"],
            backdropURL: URL(string: "https://img/arrival-backdrop.jpg")
        )
        await ShareEnricher(store: store, resolver: FakeResolver(byTitle: ["Arrival": rec]))
            .enrichOne(itemID: opened)

        let openedItem = await store.item(id: opened)
        XCTAssertEqual(openedItem?.heroBackdropURL?.absoluteString, "https://img/arrival-backdrop.jpg",
                       "the opened item gained persisted hero art")
        let stillPending = await store.pendingEnrichment(version: ShareEnricher.version, limit: 10)
        XCTAssertEqual(stillPending.map(\.title), ["Sicario"], "only the opened item was fast-tracked")
    }
}
