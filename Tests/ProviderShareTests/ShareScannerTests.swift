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

    func testScanBuildsIndexedLibraries() async {
        let store = ShareCatalogStore(accountKey: "a", directory: tempDir())
        let fake = FakeShare(standardTree())
        let scanner = ShareScanner(store: store) { await fake.list($0) }
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
        let scanner = ShareScanner(store: store) { await fake.list($0) }
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
        let scanner = ShareScanner(store: store) { await fake.list($0) }
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
        let scanner = ShareScanner(store: store) { await fake.list($0) }
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
        await ShareScanner(store: store) { await fake1.list($0) }.scan()
        let before = await store.libraryCounts()
        XCTAssertEqual(before.movies, 1)

        // A later scan where Movies lost Inception (empty now).
        var shrunk = standardTree()
        shrunk["Movies"] = []
        let fake2 = FakeShare(shrunk)
        await ShareScanner(store: store) { await fake2.list($0) }.scan()

        let after = await store.libraryCounts()
        XCTAssertEqual(after.movies, 0, "a file removed from the share is pruned on the next full scan")
        XCTAssertEqual(after.tvSeries, 1, "still-present content is retained")
    }

    func testScanIfStaleThrottlesRepeatWalks() async {
        let store = ShareCatalogStore(accountKey: "a", directory: tempDir())
        let fake = FakeShare(standardTree())
        let scanner = ShareScanner(store: store) { await fake.list($0) }

        await scanner.scanIfStale(minInterval: 600)
        let afterFirst = await fake.listCount
        XCTAssertGreaterThan(afterFirst, 0, "first call walks the tree")

        await scanner.scanIfStale(minInterval: 600)
        let afterSecond = await fake.listCount
        XCTAssertEqual(afterSecond, afterFirst, "a fresh scan just ran — the second call is throttled to a no-op")
    }
}
