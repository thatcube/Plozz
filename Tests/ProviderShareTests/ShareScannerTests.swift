import XCTest
@testable import ProviderShare
import CoreModels

/// Coverage for the foreground share scanner: does walking a share's directory
/// tree build the right indexed catalog (movies vs episodes vs anime), skip the
/// junk (extras folders, sample files), prune content that disappeared, and
/// throttle repeat walks — all without a real SMB server (an in-memory tree is
/// injected as the directory lister).
final class ShareScannerTests: XCTestCase {
    /// In-memory share: maps a directory rel-path ("" == root) to its entries, and
    /// records which directories were listed so throttling can be asserted.
    private actor FakeShare {
        private let tree: [String: [SMBShareBrowser.Entry]]
        private(set) var listedPaths: [String] = []
        init(_ tree: [String: [SMBShareBrowser.Entry]]) { self.tree = tree }
        func list(_ path: String) -> [SMBShareBrowser.Entry] {
            listedPaths.append(path)
            return tree[path] ?? []
        }
        var listCount: Int { listedPaths.count }
    }

    private func dir(_ name: String) -> SMBShareBrowser.Entry {
        SMBShareBrowser.Entry(name: name, isDirectory: true, size: 0, modifiedAt: Date())
    }
    private func file(_ name: String) -> SMBShareBrowser.Entry {
        SMBShareBrowser.Entry(name: name, isDirectory: false, size: 1_000, modifiedAt: Date())
    }
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("plozz-share-scan-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A representative library: Movies (+ a sample), a TV show under Season 01,
    /// an Anime show, and an Extras folder that must be ignored wholesale.
    private func standardTree() -> [String: [SMBShareBrowser.Entry]] {
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
    private func makeScanner(store: ShareCatalogStore, fake: FakeShare, concurrency: Int = 4) -> ShareScanner {
        ShareScanner(store: store, concurrency: concurrency, makeLister: {
            ShareScanner.ScanLister(list: { await fake.list($0) }, close: {})
        })
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
    private func wideTree(shows: Int, seasonsPerShow: Int, episodesPerSeason: Int, movies: Int) -> [String: [SMBShareBrowser.Entry]] {
        var tree: [String: [SMBShareBrowser.Entry]] = [:]
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
}
