import XCTest
@testable import ProviderShare
import CoreModels
import MediaTransportCore

/// Coverage for the foreground share scanner: does walking a share's directory
/// tree build the right indexed catalog (movies vs episodes vs anime), skip the
/// junk (extras folders, sample files), prune content that disappeared, and
/// throttle repeat walks — all without a real SMB server (an in-memory tree is
/// injected as the directory lister).
final class ShareScannerTests: XCTestCase {
    private final class AsyncCloseGate: @unchecked Sendable {
        private let lock = NSLock()
        private var started = false
        private var opened = false
        private var startWaiters: [CheckedContinuation<Void, Never>] = []
        private var openWaiters: [CheckedContinuation<Void, Never>] = []

        func close() async {
            let startWaiters = lock.withLock {
                started = true
                let waiters = self.startWaiters
                self.startWaiters.removeAll()
                return waiters
            }
            startWaiters.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                let isOpen = lock.withLock {
                    guard !opened else { return true }
                    openWaiters.append(continuation)
                    return false
                }
                if isOpen {
                    continuation.resume()
                }
            }
        }

        func waitUntilStarted() async {
            await withCheckedContinuation { continuation in
                let hasStarted = lock.withLock {
                    guard !started else { return true }
                    startWaiters.append(continuation)
                    return false
                }
                if hasStarted {
                    continuation.resume()
                }
            }
        }

        func open() {
            let waiters = lock.withLock {
                opened = true
                let waiters = openWaiters
                openWaiters.removeAll()
                return waiters
            }
            waiters.forEach { $0.resume() }
        }
    }

    private final class CompletionFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        var isSet: Bool { lock.withLock { value } }

        func set() {
            lock.withLock { value = true }
        }
    }

    /// In-memory share: maps a directory rel-path ("" == root) to its entries, and
    /// records which directories were listed so throttling can be asserted.
    private actor FakeShare {
        private let tree: [String: [RemoteFileEntry]]
        private(set) var listedPaths: [String] = []
        init(_ tree: [String: [RemoteFileEntry]]) { self.tree = tree }
        func list(_ path: String) -> [RemoteFileEntry] {
            listedPaths.append(path)
            return tree[path] ?? []
        }
        var listCount: Int { listedPaths.count }
    }

    private func dir(_ name: String) -> RemoteFileEntry {
        try! RemoteFileEntry(relativePath: name, kind: .directory, modifiedAt: Date())
    }
    private func file(_ name: String) -> RemoteFileEntry {
        try! RemoteFileEntry(
            relativePath: name,
            kind: .file,
            size: 1_000,
            modifiedAt: Date()
        )
    }
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("plozz-share-scan-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A representative library: Movies (+ a sample), a TV show under Season 01,
    /// an Anime show, and an Extras folder that must be ignored wholesale.
    private func standardTree() -> [String: [RemoteFileEntry]] {
        [
            "": [dir("Movies"), dir("TV Shows"), dir("Anime"), dir("Extras")],
            "Movies": [file("Inception (2010).mkv"), file("sample.mkv")],
            "TV Shows": [dir("Breaking Bad")],
            "TV Shows/Breaking Bad": [dir("Season 01")],
            "TV Shows/Breaking Bad/Season 01": [
                file("Breaking Bad - S01E01 - Pilot.mkv"),
                file("Breaking Bad - S01E02.mkv"),
            ],
            "Anime": [dir("Naruto")],
            "Anime/Naruto": [file("Naruto - S01E05.mkv")],
            "Extras": [file("blooper.mkv")],
        ]
    }

    /// Build a scanner whose pool of listers all read the shared (concurrency-safe)
    /// fake tree — mirrors production, where each pool slot has its own connection.
    private func makeScanner(
        store: ShareCatalogStore,
        fake: FakeShare,
        concurrency: Int = 4,
        pacer: ShareScanPacer = ShareScanPacer()
    ) -> ShareScanner {
        ShareScanner(store: store, concurrency: concurrency, pacer: pacer, makeLister: {
            ShareScanner.ScanLister(list: { await fake.list($0) }, close: {})
        })
    }

    func testScanWaitsForEveryListerToClose() async {
        let store = ShareCatalogStore(accountKey: "close-drain", directory: tempDir())
        let closeGate = AsyncCloseGate()
        let completed = CompletionFlag()
        let scanner = ShareScanner(store: store, concurrency: 1, makeLister: {
            ShareScanner.ScanLister(
                list: { _ in [] },
                close: { await closeGate.close() }
            )
        })
        let scan = Task {
            await scanner.scan()
            completed.set()
        }

        await closeGate.waitUntilStarted()
        XCTAssertFalse(completed.isSet)
        closeGate.open()
        await scan.value
        XCTAssertTrue(completed.isSet)
    }

    func testConcurrentListerCloseWaitsForSameTeardown() async {
        let closeGate = AsyncCloseGate()
        let firstCompleted = CompletionFlag()
        let secondCompleted = CompletionFlag()
        let lister = ShareScanner.ScanLister(
            list: { _ in [] },
            close: { await closeGate.close() }
        )
        let first = Task {
            await lister.close()
            firstCompleted.set()
        }

        await closeGate.waitUntilStarted()
        let second = Task {
            await lister.close()
            secondCompleted.set()
        }
        await Task.yield()
        XCTAssertFalse(firstCompleted.isSet)
        XCTAssertFalse(secondCompleted.isSet)

        closeGate.open()
        await first.value
        await second.value
        XCTAssertTrue(firstCompleted.isSet)
        XCTAssertTrue(secondCompleted.isSet)
    }

    func testScanBuildsIndexedLibraries() async {
        let store = ShareCatalogStore(accountKey: "a", directory: tempDir())
        let fake = FakeShare(standardTree())
        let scanner = makeScanner(store: store, fake: fake)
        await scanner.scan()

        let counts = await store.libraryCounts()
        XCTAssertEqual(counts.movies, 1, "Inception indexed; sample.mkv skipped")
        XCTAssertEqual(counts.tvSeries, 1)
        XCTAssertEqual(counts.animeSeries, 1)

        let movies = await store.movies(offset: 0, limit: 10)
        XCTAssertEqual(movies.map(\.title), ["Inception"])
        XCTAssertEqual(movies.first?.productionYear, 2010)
    }

    func testEpisodesGroupUnderSeriesInOrder() async {
        let store = ShareCatalogStore(accountKey: "a", directory: tempDir())
        let fake = FakeShare(standardTree())
        let scanner = makeScanner(store: store, fake: fake)
        await scanner.scan()

        let key = ShareCatalogID.seriesKey(fromTitle: "Breaking Bad")
        let seasons = await store.seasons(seriesKey: key)
        XCTAssertEqual(seasons.map(\.seasonNumber), [1])
        let eps = await store.episodes(seriesKey: key, season: 1)
        XCTAssertEqual(eps.map(\.episodeNumber), [1, 2])
    }

    func testAnimeFolderClassifiedAsAnime() async {
        let store = ShareCatalogStore(accountKey: "a", directory: tempDir())
        let fake = FakeShare(standardTree())
        let scanner = makeScanner(store: store, fake: fake)
        await scanner.scan()

        let anime = await store.series(in: .anime, offset: 0, limit: 10)
        XCTAssertEqual(anime.map(\.title), ["Naruto"])
        // Naruto must NOT also appear under TV.
        let tv = await store.series(in: .tv, offset: 0, limit: 10)
        XCTAssertFalse(tv.contains { $0.title == "Naruto" })
    }

    /// Bare-numbered anime (no `SxxEyy` marker) grouped under one series by the
    /// folder tree — and NOT leaking into the Movies library. This is the exact
    /// regression from the report (many "Sword Art Online 2 18" cards in Movies).
    func testBareNumberedAnimeGroupsAsSeriesNotMovies() async {
        let store = ShareCatalogStore(accountKey: "a", directory: tempDir())
        let tree: [String: [RemoteFileEntry]] = [
            "": [dir("Anime")],
            "Anime": [dir("Sword Art Online II")],
            "Anime/Sword Art Online II": [
                file("Sword Art Online II - 18.mkv"),
                file("Sword Art Online II - 19.mkv"),
                file("Sword Art Online II - 20.mkv"),
            ],
        ]
        let scanner = makeScanner(store: store, fake: FakeShare(tree))
        await scanner.scan()

        let counts = await store.libraryCounts()
        XCTAssertEqual(counts.movies, 0, "bare-numbered anime must not land in Movies")
        XCTAssertEqual(counts.animeSeries, 1)

        let key = ShareCatalogID.seriesKey(fromTitle: "Sword Art Online II")
        let eps = await store.episodes(seriesKey: key, season: 1)
        XCTAssertEqual(eps.map(\.episodeNumber), [18, 19, 20])
    }

    /// A classifier bump forces a fresh walk even when the throttle would skip it,
    /// so already-indexed files get reclassified under the new rules.
    func testClassifierBumpForcesReparse() async {
        let store = ShareCatalogStore(accountKey: "a", directory: tempDir())
        let fake = FakeShare(standardTree())
        let scanner = makeScanner(store: store, fake: fake)
        await scanner.scan()
        let afterFirst = await fake.listCount
        XCTAssertGreaterThan(afterFirst, 0)

        // Same classifier version already recorded → throttled (no new listings).
        await scanner.scanIfStale()
        let afterThrottled = await fake.listCount
        XCTAssertEqual(afterThrottled, afterFirst, "throttled when parser_version matches")

        // Simulate a classifier bump by clearing the recorded version.
        await store.setMeta("parser_version", "0")
        await scanner.scanIfStale()
        let afterBump = await fake.listCount
        XCTAssertGreaterThan(afterBump, afterFirst, "a classifier bump re-walks despite the throttle")
    }

    func testExcludedDirsAndSampleFilesSkipped() async {
        let store = ShareCatalogStore(accountKey: "a", directory: tempDir())
        let fake = FakeShare(standardTree())
        let scanner = makeScanner(store: store, fake: fake)
        await scanner.scan()

        // The Extras subtree is never entered, so its video isn't indexed.
        let blooper = await store.item(id: ShareCatalogID.file("Extras/blooper.mkv"))
        XCTAssertNil(blooper)
        // sample.mkv was present in Movies but filtered.
        let sample = await store.item(id: ShareCatalogID.file("Movies/sample.mkv"))
        XCTAssertNil(sample)
    }

    func testRescanPrunesRemovedContent() async {
        let store = ShareCatalogStore(accountKey: "a", directory: tempDir())
        let fake1 = FakeShare(standardTree())
        await makeScanner(store: store, fake: fake1).scan()
        let before = await store.libraryCounts()
        XCTAssertEqual(before.movies, 1)

        // A later scan where Movies lost Inception (empty now).
        var shrunk = standardTree()
        shrunk["Movies"] = []
        let fake2 = FakeShare(shrunk)
        await makeScanner(store: store, fake: fake2).scan()

        let after = await store.libraryCounts()
        XCTAssertEqual(after.movies, 0, "a file removed from the share is pruned on the next full scan")
        XCTAssertEqual(after.tvSeries, 1, "still-present content is retained")
    }

    func testPartialScanFailureDoesNotPrune() async {
        struct ListError: Error {}
        let store = ShareCatalogStore(accountKey: "a", directory: tempDir())

        // First scan indexes everything cleanly.
        await makeScanner(store: store, fake: FakeShare(standardTree())).scan()
        let before = await store.libraryCounts()
        XCTAssertEqual(before.movies, 1)
        XCTAssertEqual(before.tvSeries, 1)

        // Second scan: listing the Movies folder throws (a transient SMB error). The
        // walk must NOT prune, so the still-present Inception survives rather than
        // being deleted (and its "date added" reset) on the next rediscovery.
        let fake = FakeShare(standardTree())
        let scanner = ShareScanner(store: store, concurrency: 4, makeLister: {
            ShareScanner.ScanLister(
                list: { path in
                    if path == "Movies" { throw ListError() }
                    return await fake.list(path)
                },
                close: {}
            )
        })
        await scanner.scan()

        let after = await store.libraryCounts()
        XCTAssertEqual(after.movies, 1, "a transient listing failure must not prune still-present content")
        XCTAssertEqual(after.tvSeries, 1)
    }

    func testFailedConnectionIsRecycledAndWalkStillCompletes() async {
        // A wedged connection (a listing that fails) must be discarded and replaced by
        // a fresh one, so it can't drag the walk. Fail a media-less "Decoy" branch so
        // the recycle is exercised while the real libraries still index fully.
        struct ListError: Error {}
        final class Flag: @unchecked Sendable {
            private let lock = NSLock()
            private var fired = false
            func takeFirst() -> Bool { lock.lock(); defer { lock.unlock() }
                if fired { return false }; fired = true; return true }
        }
        actor Counter { var made = 0; func madeOne() { made += 1 } }
        let counter = Counter()
        let decoyFails = Flag()
        let store = ShareCatalogStore(accountKey: "a", directory: tempDir())

        var tree = standardTree()
        tree[""] = [dir("Movies"), dir("TV Shows"), dir("Anime"), dir("Decoy")]
        tree["Decoy"] = [dir("Empty")]
        tree["Decoy/Empty"] = []
        let fake = FakeShare(tree)

        // The first listing of "Decoy" fails once (wedging that connection), forcing a
        // recycle; every fresh replacement then works. Decoy carries no media, so the
        // real libraries are unaffected.
        let scanner = ShareScanner(store: store, concurrency: 4, makeLister: {
            Task { await counter.madeOne() }
            return ShareScanner.ScanLister(
                list: { path in
                    if path == "Decoy" && decoyFails.takeFirst() { throw ListError() }
                    return await fake.list(path)
                },
                close: {}
            )
        })
        await scanner.scan()

        let counts = await store.libraryCounts()
        XCTAssertEqual(counts.movies, 1, "walk completes and indexes movies despite a recycle")
        XCTAssertEqual(counts.tvSeries, 1)
        XCTAssertEqual(counts.animeSeries, 1)
        let made = await counter.made
        XCTAssertGreaterThan(made, 4, "a failed connection was replaced by a fresh one (beyond the initial pool of 4)")
    }

    func testScanIfStaleThrottlesRepeatWalks() async {
        let store = ShareCatalogStore(accountKey: "a", directory: tempDir())
        let fake = FakeShare(standardTree())
        let scanner = makeScanner(store: store, fake: fake)

        await scanner.scanIfStale(minInterval: 600)
        let afterFirst = await fake.listCount
        XCTAssertGreaterThan(afterFirst, 0, "first call walks the tree")

        await scanner.scanIfStale(minInterval: 600)
        let afterSecond = await fake.listCount
        XCTAssertEqual(afterSecond, afterFirst, "a fresh scan just ran — the second call is throttled to a no-op")
    }

    /// A wide/deep tree: many shows, each with seasons + episodes, plus many movies.
    /// Exercises the parallel BFS across multiple levels and pool reuse.
    private func wideTree(shows: Int, seasonsPerShow: Int, episodesPerSeason: Int, movies: Int) -> [String: [RemoteFileEntry]] {
        var tree: [String: [RemoteFileEntry]] = [:]
        tree[""] = [dir("Movies"), dir("TV Shows")]
        tree["Movies"] = (0..<movies).map { file("Movie \($0) (20\(String(format: "%02d", $0 % 100))).mkv") }
        tree["TV Shows"] = (0..<shows).map { dir("Show \($0)") }
        for s in 0..<shows {
            let showPath = "TV Shows/Show \(s)"
            tree[showPath] = (1...seasonsPerShow).map { dir("Season \(String(format: "%02d", $0))") }
            for season in 1...seasonsPerShow {
                let seasonPath = "\(showPath)/Season \(String(format: "%02d", season))"
                tree[seasonPath] = (1...episodesPerSeason).map {
                    file("Show \(s) - S\(String(format: "%02d", season))E\(String(format: "%02d", $0)).mkv")
                }
            }
        }
        return tree
    }

    func testParallelAndSerialWalksProduceIdenticalCatalogs() async {
        let tree = wideTree(shows: 8, seasonsPerShow: 3, episodesPerSeason: 10, movies: 25)

        // Serial (concurrency 1)
        let serialStore = ShareCatalogStore(accountKey: "serial", directory: tempDir())
        await makeScanner(store: serialStore, fake: FakeShare(tree), concurrency: 1).scan()
        let serialCounts = await serialStore.libraryCounts()

        // Parallel (concurrency 6)
        let parallelStore = ShareCatalogStore(accountKey: "parallel", directory: tempDir())
        await makeScanner(store: parallelStore, fake: FakeShare(tree), concurrency: 6).scan()
        let parallelCounts = await parallelStore.libraryCounts()

        XCTAssertEqual(serialCounts.movies, 25)
        XCTAssertEqual(serialCounts.tvSeries, 8)
        XCTAssertEqual(parallelCounts.movies, serialCounts.movies, "parallel walk must index the same movies")
        XCTAssertEqual(parallelCounts.tvSeries, serialCounts.tvSeries, "parallel walk must index the same series")

        // Every episode of every show made it in, regardless of concurrency.
        let key = ShareCatalogID.seriesKey(fromTitle: "Show 3")
        let s2Serial = await serialStore.episodes(seriesKey: key, season: 2)
        let s2Parallel = await parallelStore.episodes(seriesKey: key, season: 2)
        XCTAssertEqual(s2Serial.count, 10)
        XCTAssertEqual(s2Parallel.map(\.episodeNumber), s2Serial.map(\.episodeNumber))
    }

    func testScanKeepsProgressingDuringContinuousInteractiveActivity() async {
        let store = ShareCatalogStore(accountKey: "paced", directory: tempDir())
        let tree = wideTree(shows: 12, seasonsPerShow: 2, episodesPerSeason: 8, movies: 100)
        let pacer = ShareScanPacer(activeWindow: .seconds(10), activeDelay: .milliseconds(2))
        let scanner = makeScanner(
            store: store,
            fake: FakeShare(tree),
            concurrency: 4,
            pacer: pacer
        )
        let activity = Task {
            while !Task.isCancelled {
                await pacer.noteInteractiveActivity()
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
        await scanner.scan()
        activity.cancel()

        let counts = await store.libraryCounts()
        XCTAssertEqual(counts.movies, 100)
        XCTAssertEqual(counts.tvSeries, 12,
                       "bounded pacing must slow admission, never wait for idle/starve")
    }

    func testSupersededScanGenerationCannotWriteOrPruneCatalog() async throws {
        let store = ShareCatalogStore(accountKey: "generation", directory: tempDir())
        let oldGeneration = UUID()
        await store.activateScanGeneration(oldGeneration)
        let generatedScanID = await store.nextScanID(for: oldGeneration)
        let oldScanID = try XCTUnwrap(generatedScanID)
        let retainedPath = "Movies/Arrival (2016).mkv"
        await store.upsert(
            [ShareScanner.asset(relPath: retainedPath, entry: file("Arrival (2016).mkv"))],
            scanID: oldScanID,
            scanGeneration: oldGeneration
        )

        let replacementGeneration = UUID()
        await store.activateScanGeneration(replacementGeneration)
        let stalePath = "Movies/Stale (2020).mkv"
        await store.upsert(
            [ShareScanner.asset(relPath: stalePath, entry: file("Stale (2020).mkv"))],
            scanID: oldScanID + 1,
            scanGeneration: oldGeneration
        )
        await store.pruneNotSeen(
            inScan: oldScanID + 1,
            scanGeneration: oldGeneration
        )

        let retained = await store.item(id: ShareCatalogID.file(retainedPath))
        let stale = await store.item(id: ShareCatalogID.file(stalePath))
        XCTAssertNotNil(retained)
        XCTAssertNil(stale)
    }

    func testPacerEngagesOnlyForRecentActivityAndIsPerShare() async {
        let firstShare = ShareScanPacer(
            activeWindow: .milliseconds(15),
            activeDelay: .milliseconds(1)
        )
        let secondShare = ShareScanPacer(
            activeWindow: .seconds(1),
            activeDelay: .milliseconds(1)
        )

        let idle = await firstShare.paceIfBrowsing()
        XCTAssertFalse(idle)

        await firstShare.noteInteractiveActivity()
        let active = await firstShare.paceIfBrowsing()
        let unrelated = await secondShare.paceIfBrowsing()
        XCTAssertTrue(active, "recent activity must engage bounded pacing")
        XCTAssertFalse(unrelated, "browsing one share must not throttle another")

        try? await Task.sleep(for: .milliseconds(20))
        let expired = await firstShare.paceIfBrowsing()
        XCTAssertFalse(expired, "full throughput resumes after the activity window")
    }
}
