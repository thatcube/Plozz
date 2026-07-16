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

    func testEnrichmentReportsTotalAndProgress() async {
        // The enricher advertises the pass total up front and reports progress per
        // item attempted, so the Home pill can show "N of M".
        final class Captured: @unchecked Sendable {
            private let lock = NSLock()
            private(set) var started = 0
            private(set) var total = 0
            private(set) var maxDone = 0
            private(set) var finished = 0
            func start(_ t: Int) { lock.lock(); started += 1; total = t; lock.unlock() }
            func progress(_ d: Int) { lock.lock(); maxDone = max(maxDone, d); lock.unlock() }
            func finish() { lock.lock(); finished += 1; lock.unlock() }
        }
        let cap = Captured()
        let reporter = ShareScanReporter(
            scanStarted: { _, _ in }, scanProgress: { _, _ in }, scanFinished: { _ in },
            enrichStarted: { _, total in cap.start(total) },
            enrichProgress: { _, done in cap.progress(done) },
            enrichFinished: { _ in cap.finish() }
        )
        let store = ShareCatalogStore(accountKey: "a", directory: tempDir())
        await store.upsert([
            movie("Movies/A (2000).mkv", "A", 2000),
            movie("Movies/B (2001).mkv", "B", 2001),
            movie("Movies/C (2002).mkv", "C", 2002),
        ], scanID: 1)
        let rec = ShareCatalogStore.EnrichmentRecord(providerIDs: ["Tmdb": "1"])
        let enricher = ShareEnricher(
            store: store,
            resolver: FakeResolver(byTitle: ["A": rec, "B": rec, "C": rec]),
            reporter: reporter
        )
        await enricher.enrichPending()

        XCTAssertEqual(cap.started, 1, "advertised once")
        XCTAssertEqual(cap.total, 3, "pass total = pending count")
        XCTAssertEqual(cap.maxDone, 3, "progress reached the total")
        XCTAssertEqual(cap.finished, 1, "finished once")
    }

    func testPassiveSlicesBoundWorkAndDrainSequentially() async {
        let store = ShareCatalogStore(accountKey: "sliced", directory: tempDir())
        let assets = (0..<25).map {
            movie("Movies/M\($0) (2000).mkv", "M\($0)", 2000)
        }
        await store.upsert(assets, scanID: 1)

        actor Counter {
            var value = 0
            func bump() { value += 1 }
        }
        let counter = Counter()
        struct Resolver: ShareMetadataResolving {
            let counter: Counter
            func resolve(_ request: ShareEnrichRequest) async -> ShareCatalogStore.EnrichmentRecord {
                await counter.bump()
                return .init(providerIDs: ["Tmdb": request.itemID])
            }
        }
        let enricher = ShareEnricher(store: store, resolver: Resolver(counter: counter))

        let first = await enricher.enrichPendingSlice(
            maxItems: 10,
            maxDuration: .seconds(10)
        )
        XCTAssertEqual(first, .init(attempted: 10, hasMore: true))
        let afterFirst = await counter.value
        XCTAssertEqual(afterFirst, 10)

        let second = await enricher.enrichPendingSlice(
            maxItems: 10,
            maxDuration: .seconds(10)
        )
        XCTAssertEqual(second, .init(attempted: 10, hasMore: true))
        let afterSecond = await counter.value
        XCTAssertEqual(afterSecond, 20)

        let third = await enricher.enrichPendingSlice(
            maxItems: 10,
            maxDuration: .seconds(10)
        )
        XCTAssertEqual(third, .init(attempted: 5, hasMore: false))
        let afterThird = await counter.value
        let remaining = await store.pendingEnrichmentCount(version: ShareEnricher.version)
        XCTAssertEqual(afterThird, 25)
        XCTAssertEqual(remaining, 0)
    }

    func testSlicedRetryProgressNeverExceedsLogicalTotal() async {
        final class Captured: @unchecked Sendable {
            private let lock = NSLock()
            private(set) var total = 0
            private(set) var maxDone = 0
            private(set) var starts = 0
            private(set) var finishes = 0
            func start(_ value: Int) {
                lock.lock(); starts += 1; total = value; lock.unlock()
            }
            func progress(_ value: Int) {
                lock.lock(); maxDone = max(maxDone, value); lock.unlock()
            }
            func finish() {
                lock.lock(); finishes += 1; lock.unlock()
            }
        }
        let captured = Captured()
        let reporter = ShareScanReporter(
            scanStarted: { _, _ in },
            scanProgress: { _, _ in },
            scanFinished: { _ in },
            enrichStarted: { _, total in captured.start(total) },
            enrichProgress: { _, done in captured.progress(done) },
            enrichFinished: { _ in captured.finish() }
        )
        let store = ShareCatalogStore(accountKey: "retry-progress", directory: tempDir())
        await store.upsert([
            movie("Movies/A (2000).mkv", "A", 2000),
            movie("Movies/B (2000).mkv", "B", 2000),
        ], scanID: 1)
        let enricher = ShareEnricher(
            store: store,
            resolver: FakeResolver(byTitle: [:]),
            reporter: reporter
        )

        for _ in 0..<2 {
            _ = await enricher.enrichPendingSlice(
                maxItems: 2,
                maxDuration: .seconds(10)
            )
        }

        XCTAssertEqual(captured.starts, 1)
        XCTAssertEqual(captured.total, 2)
        XCTAssertEqual(captured.maxDone, 2)
        XCTAssertEqual(captured.finishes, 1)
    }

    func testRetryableMissesAreAttemptedOncePerLogicalPass() async {
        let store = ShareCatalogStore(accountKey: "retry-pass", directory: tempDir())
        await store.upsert((0..<12).map {
            movie("Movies/M\($0) (2000).mkv", "M\($0)", 2000)
        }, scanID: 1)

        actor Counter {
            var value = 0
            func bump() { value += 1 }
        }
        let counter = Counter()
        struct Resolver: ShareMetadataResolving {
            let counter: Counter
            func resolve(_ request: ShareEnrichRequest) async -> ShareCatalogStore.EnrichmentRecord {
                await counter.bump()
                return .init()
            }
        }
        let enricher = ShareEnricher(store: store, resolver: Resolver(counter: counter))

        let first = await enricher.enrichPendingSlice(
            maxItems: 10,
            maxDuration: .seconds(10)
        )
        let second = await enricher.enrichPendingSlice(
            maxItems: 10,
            maxDuration: .seconds(10)
        )
        let attemptsAfterOnePass = await counter.value

        XCTAssertEqual(first.attempted, 10)
        XCTAssertEqual(second, .init(attempted: 2, hasMore: false))
        XCTAssertEqual(attemptsAfterOnePass, 12)

        _ = await enricher.enrichPendingSlice(
            maxItems: 10,
            maxDuration: .seconds(10)
        )
        let attemptsAfterStartingNextPass = await counter.value
        XCTAssertEqual(attemptsAfterStartingNextPass, 22)
    }

    func testInteractivePausePreservesLogicalPassCutoff() async {
        let store = ShareCatalogStore(accountKey: "pause-pass", directory: tempDir())
        await store.upsert((0..<12).map {
            movie("Movies/P\($0) (2000).mkv", "P\($0)", 2000)
        }, scanID: 1)

        actor Counter {
            var value = 0
            func bump() { value += 1 }
        }
        let counter = Counter()
        struct Resolver: ShareMetadataResolving {
            let counter: Counter
            func resolve(_ request: ShareEnrichRequest) async -> ShareCatalogStore.EnrichmentRecord {
                await counter.bump()
                return .init()
            }
        }
        let enricher = ShareEnricher(store: store, resolver: Resolver(counter: counter))

        _ = await enricher.enrichPendingSlice(
            maxItems: 10,
            maxDuration: .seconds(10)
        )
        await enricher.pauseScheduledPass()
        let afterPause = await enricher.enrichPendingSlice(
            maxItems: 10,
            maxDuration: .seconds(10)
        )
        let attempts = await counter.value

        XCTAssertEqual(afterPause, .init(attempted: 2, hasMore: false))
        XCTAssertEqual(attempts, 12)
    }

    func testFastTrackedItemAdvancesActivePassProgress() async {
        final class Captured: @unchecked Sendable {
            private let lock = NSLock()
            private(set) var total = 0
            private(set) var maxDone = 0
            func start(_ value: Int) { lock.lock(); total = value; lock.unlock() }
            func progress(_ value: Int) {
                lock.lock(); maxDone = max(maxDone, value); lock.unlock()
            }
        }
        let captured = Captured()
        let reporter = ShareScanReporter(
            scanStarted: { _, _ in },
            scanProgress: { _, _ in },
            scanFinished: { _ in },
            enrichStarted: { _, total in captured.start(total) },
            enrichProgress: { _, done in captured.progress(done) },
            enrichFinished: { _ in }
        )
        let store = ShareCatalogStore(accountKey: "fast-progress", directory: tempDir())
        await store.upsert([
            movie("Movies/A (2000).mkv", "A", 2000),
            movie("Movies/B (2000).mkv", "B", 2000),
        ], scanID: 1)
        let record = ShareCatalogStore.EnrichmentRecord(providerIDs: ["Tmdb": "1"])
        let enricher = ShareEnricher(
            store: store,
            resolver: FakeResolver(byTitle: ["A": record, "B": record]),
            reporter: reporter
        )

        _ = await enricher.enrichPendingSlice(
            maxItems: 1,
            maxDuration: .seconds(10)
        )
        await enricher.pauseScheduledPass()
        await enricher.enrichOne(itemID: ShareCatalogID.file("Movies/B (2000).mkv"))
        _ = await enricher.enrichPendingSlice(
            maxItems: 1,
            maxDuration: .seconds(10)
        )

        XCTAssertEqual(captured.total, 2)
        XCTAssertEqual(captured.maxDone, 2)
    }

    func testItemsDiscoveredMidPassWaitForNextLogicalPass() async {
        let store = ShareCatalogStore(accountKey: "new-mid-pass", directory: tempDir())
        await store.upsert([
            movie("Movies/A (2000).mkv", "A", 2000),
        ], scanID: 1)

        actor Counter {
            var value = 0
            func bump() { value += 1 }
        }
        let counter = Counter()
        struct Resolver: ShareMetadataResolving {
            let counter: Counter
            func resolve(_ request: ShareEnrichRequest) async -> ShareCatalogStore.EnrichmentRecord {
                await counter.bump()
                return .init()
            }
        }
        let enricher = ShareEnricher(store: store, resolver: Resolver(counter: counter))

        _ = await enricher.enrichPendingSlice(
            maxItems: 1,
            maxDuration: .seconds(10)
        )
        await enricher.pauseScheduledPass()
        try? await Task.sleep(for: .milliseconds(10))
        await store.upsert([
            movie("Movies/B (2000).mkv", "B", 2000),
        ], scanID: 2)
        let endOfFirstPass = await enricher.enrichPendingSlice(
            maxItems: 10,
            maxDuration: .seconds(10)
        )
        let afterFirstPass = await counter.value

        XCTAssertEqual(endOfFirstPass, .init(attempted: 0, hasMore: false))
        XCTAssertEqual(afterFirstPass, 1)

        _ = await enricher.enrichPendingSlice(
            maxItems: 10,
            maxDuration: .seconds(10)
        )
        let afterNextPass = await counter.value
        XCTAssertEqual(afterNextPass, 3)
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

    func testTypoFolderMergesWithTwinBySharedStrongID() async {
        // Id-corroborated reconciliation: a typo'd folder ("Peaky Blinder") and its
        // correct twin ("Peaky Blinders") that resolve to the SAME Tvdb id fold into
        // one series titled with the resolved canonical name.
        let store = ShareCatalogStore(accountKey: "a", directory: tempDir())
        await store.upsert([
            episode("TV/Peaky Blinder/Season 1/Peaky.Blinder.S01E01.mkv", series: "Peaky Blinder", s: 1, e: 1),
            episode("TV/Peaky Blinder/Season 1/Peaky.Blinder.S01E02.mkv", series: "Peaky Blinder", s: 1, e: 2),
            episode("TV/Peaky Blinders/Season 1/Peaky.Blinders.S01E01.mkv", series: "Peaky Blinders", s: 1, e: 1),
        ], scanID: 1)
        let before = await store.series(in: .tv, offset: 0, limit: 10)
        XCTAssertEqual(before.count, 2, "two keys before merge")

        let rec = ShareCatalogStore.EnrichmentRecord(providerIDs: ["Tvdb": "270261"], title: "Peaky Blinders")
        await ShareEnricher(store: store, resolver: FakeResolver(byTitle: [
            "Peaky Blinder": rec, "Peaky Blinders": rec,
        ])).enrichPending()

        let series = await store.series(in: .tv, offset: 0, limit: 10)
        XCTAssertEqual(series.count, 1, "shared Tvdb id + near title folds them into one card")
        XCTAssertEqual(series.first?.title, "Peaky Blinders", "shows the resolved canonical title")
    }

    func testDifferentShowsSharingNoIDDoNotMerge() async {
        // Two near-titled shows that DON'T share an id must stay separate — the id is
        // the authoritative gate, not the title similarity.
        let store = ShareCatalogStore(accountKey: "a", directory: tempDir())
        await store.upsert([
            episode("TV/1883/Season 1/1883.S01E01.mkv", series: "1883", s: 1, e: 1),
            episode("TV/1923/Season 1/1923.S01E01.mkv", series: "1923", s: 1, e: 1),
        ], scanID: 1)
        await ShareEnricher(store: store, resolver: FakeResolver(byTitle: [
            "1883": ShareCatalogStore.EnrichmentRecord(providerIDs: ["Tvdb": "355774"], title: "1883"),
            "1923": ShareCatalogStore.EnrichmentRecord(providerIDs: ["Tvdb": "403361"], title: "1923"),
        ])).enrichPending()
        let series = await store.series(in: .tv, offset: 0, limit: 10)
        XCTAssertEqual(series.count, 2, "distinct ids never merge")
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

    func testMissIsRetriedAcrossPassesThenSettled() async {
        // An empty (unusable) resolve is a likely-transient miss (rate-limit/timeout):
        // it stays pending and is retried across passes, then settled after the
        // attempt cap — never cached as a permanent blank, never retried forever.
        let store = ShareCatalogStore(accountKey: "a", directory: tempDir())
        await store.upsert([
            movie("Movies/A (2000).mkv", "A", 2000),
            movie("Movies/B (2001).mkv", "B", 2001),
        ], scanID: 1)
        let enricher = ShareEnricher(store: store, resolver: FakeResolver(byTitle: [:]))

        // First pass attempts both but resolves nothing → still pending (retry).
        await enricher.enrichPending()
        let afterOne = await store.pendingEnrichment(version: ShareEnricher.version, limit: 10)
        XCTAssertEqual(afterOne.count, 2, "an empty (transient-looking) miss stays pending for retry")

        // Exhaust the remaining retry budget → settled as a genuine miss.
        for _ in 1..<ShareCatalogStore.maxEnrichAttempts { await enricher.enrichPending() }
        let afterCap = await store.pendingEnrichment(version: ShareEnricher.version, limit: 10)
        XCTAssertTrue(afterCap.isEmpty, "after the attempt cap a persistent miss is settled")
    }

    func testRetryBudgetResetsOnVersionBump() async {
        // The attempt budget is PER version: after exhausting retries at v1, a future
        // ShareEnricher.version bump must grant the full budget again (not settle the
        // item after a single v2 attempt).
        let store = ShareCatalogStore(accountKey: "a", directory: tempDir())
        await store.upsert([movie("Movies/A (2000).mkv", "A", 2000)], scanID: 1)
        let id = ShareCatalogID.file("Movies/A (2000).mkv")

        // Exhaust the budget at version 1 with empty (unusable) results.
        for _ in 0..<ShareCatalogStore.maxEnrichAttempts {
            await store.saveEnrichment(itemID: id, .init(), version: 1)
        }
        let pendingV1 = await store.pendingEnrichment(version: 1, limit: 10)
        XCTAssertTrue(pendingV1.isEmpty, "settled as a miss at v1 after the cap")

        // A single empty write at the NEW version must NOT settle it — the budget
        // reset, so it stays pending for the remaining v2 retries.
        await store.saveEnrichment(itemID: id, .init(), version: 2)
        let pendingV2First = await store.pendingEnrichment(version: 2, limit: 10)
        XCTAssertEqual(pendingV2First.count, 1,
                       "a version bump resets the retry budget (one v2 attempt doesn't settle it)")

        // And it still eventually settles at v2 after its own full budget.
        for _ in 1..<ShareCatalogStore.maxEnrichAttempts {
            await store.saveEnrichment(itemID: id, .init(), version: 2)
        }
        let pendingV2After = await store.pendingEnrichment(version: 2, limit: 10)
        XCTAssertTrue(pendingV2After.isEmpty, "settles at v2 after v2's own cap")
    }

    func testUsableResultRecoversAPreviouslyMissedItem() async {
        // A miss that later resolves to real data must recover (not stay blank).
        let store = ShareCatalogStore(accountKey: "a", directory: tempDir())
        await store.upsert([movie("Movies/A (2000).mkv", "A", 2000)], scanID: 1)

        await ShareEnricher(store: store, resolver: FakeResolver(byTitle: [:])).enrichPending()
        let stillPending = await store.pendingEnrichment(version: ShareEnricher.version, limit: 10)
        XCTAssertEqual(stillPending.count, 1)

        let rec = ShareCatalogStore.EnrichmentRecord(providerIDs: ["Tmdb": "1"])
        await ShareEnricher(store: store, resolver: FakeResolver(byTitle: ["A": rec])).enrichPending()
        let item = await store.item(id: ShareCatalogID.file("Movies/A (2000).mkv"))
        XCTAssertEqual(item?.providerID(.tmdb), "1")
        let afterRecover = await store.pendingEnrichment(version: ShareEnricher.version, limit: 10)
        XCTAssertTrue(afterRecover.isEmpty, "a now-usable item settles out of the pending set")
    }

    func testSparseWriteDoesNotClobberRicherEnrichment() async {
        // A later sparse/transient result (e.g. enrichOne racing the drain) must not
        // erase ids/art an earlier pass already resolved.
        let store = ShareCatalogStore(accountKey: "a", directory: tempDir())
        await store.upsert([movie("Movies/A (2000).mkv", "A", 2000)], scanID: 1)
        let id = ShareCatalogID.file("Movies/A (2000).mkv")

        await store.saveEnrichment(itemID: id, .init(
            providerIDs: ["Tmdb": "1"],
            posterURL: URL(string: "https://img/p.jpg"),
            backdropURL: URL(string: "https://img/b.jpg")
        ), version: ShareEnricher.version)
        // A subsequent empty write must merge, not clobber.
        await store.saveEnrichment(itemID: id, .init(), version: ShareEnricher.version)

        let item = await store.item(id: id)
        XCTAssertEqual(item?.providerID(.tmdb), "1", "ids survive a later sparse write")
        XCTAssertEqual(item?.posterURL?.absoluteString, "https://img/p.jpg", "poster survives")
        XCTAssertEqual(item?.backdropURL?.absoluteString, "https://img/b.jpg", "backdrop survives")
    }

    func testVersionBumpReplacesStaleArtworkInsteadOfMerging() async {
        // A re-enrich at a NEW version must REPLACE the row (drop stale artwork from a
        // previous wrong match), not union — the Punisher/"TAP" logo bug.
        let store = ShareCatalogStore(accountKey: "a", directory: tempDir())
        await store.upsert([movie("Movies/The Punisher (2017).mkv", "The Punisher", 2017)], scanID: 1)
        let id = ShareCatalogID.file("Movies/The Punisher (2017).mkv")

        // v1: a WRONG match cached a bogus logo (as if resolved for the "TP" alias).
        await store.saveEnrichment(itemID: id, .init(
            providerIDs: ["Tmdb": "999999"],
            logoURL: URL(string: "https://commons/TAP-Portugal-Logo.svg")
        ), version: 1)

        // v2: the corrected match has proper ids + poster but NO logo. The stale TAP
        // logo must NOT survive the version bump.
        await store.saveEnrichment(itemID: id, .init(
            providerIDs: ["Tmdb": "67178", "Imdb": "tt5675620"],
            posterURL: URL(string: "https://tvdb/punisher-poster.jpg")
        ), version: 2)

        let item = await store.item(id: id)
        XCTAssertNil(item?.logoURL, "stale wrong logo dropped on version bump")
        XCTAssertEqual(item?.providerID(.tmdb), "67178")
        XCTAssertEqual(item?.posterURL?.absoluteString, "https://tvdb/punisher-poster.jpg")
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
