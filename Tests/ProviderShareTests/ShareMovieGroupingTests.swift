import XCTest
@testable import ProviderShare
import CoreModels

/// Within-share movie de-duplication: several files of the SAME film collapse to
/// one logical movie (`movie:<key>`) with selectable versions — the share's local
/// equivalent of the server-side version grouping Plex/Jellyfin do — while distinct
/// films (and stacked multi-part movies) stay separate.
final class ShareMovieGroupingTests: XCTestCase {
    private func dir(_ name: String) -> SMBShareBrowser.Entry {
        SMBShareBrowser.Entry(name: name, isDirectory: true, size: 0, modifiedAt: Date())
    }
    private func file(_ name: String, size: UInt64 = 1_000) -> SMBShareBrowser.Entry {
        SMBShareBrowser.Entry(name: name, isDirectory: false, size: size, modifiedAt: Date())
    }
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("plozz-movie-group-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private actor FakeShare {
        private let tree: [String: [SMBShareBrowser.Entry]]
        init(_ tree: [String: [SMBShareBrowser.Entry]]) { self.tree = tree }
        func list(_ path: String) -> [SMBShareBrowser.Entry] { tree[path] ?? [] }
    }
    private func scan(_ tree: [String: [SMBShareBrowser.Entry]], into store: ShareCatalogStore) async {
        let fake = FakeShare(tree)
        let scanner = ShareScanner(store: store, concurrency: 2, makeLister: {
            ShareScanner.ScanLister(list: { await fake.list($0) }, close: {})
        })
        await scanner.scan()
    }

    /// Two quality files in one movie folder → ONE movie card, TWO versions.
    func testTwoFilesInMovieFolderGroupWithVersions() async {
        let store = ShareCatalogStore(accountKey: "a", directory: tempDir())
        let tree: [String: [SMBShareBrowser.Entry]] = [
            "": [dir("Movies")],
            "Movies": [dir("Star Wars (1977)")],
            "Movies/Star Wars (1977)": [
                file("Star Wars (1977) Bluray-2160p.mkv", size: 40_000_000_000 as UInt64),
                file("Star Wars (1977) Bluray-1080p.mkv", size: 12_000_000_000 as UInt64),
            ],
        ]
        await scan(tree, into: store)

        let count1 = await store.movieCount()
        XCTAssertEqual(count1, 1, "two files of one film = one movie card")
        let movies = await store.movies(offset: 0, limit: 10)
        XCTAssertEqual(movies.count, 1)
        XCTAssertEqual(movies.first?.title, "Star Wars")
        XCTAssertTrue(movies.first?.id.hasPrefix("movie:") ?? false)

        // The detail item exposes both files as versions, best-quality default first.
        guard let id = movies.first?.id, let detail = await store.item(id: id) else {
            return XCTFail("logical movie must resolve")
        }
        XCTAssertEqual(detail.versions.count, 2)
        XCTAssertTrue(detail.hasMultipleVersions)
        XCTAssertEqual(detail.versions.first?.height, 2160, "4K version sorts first")
        XCTAssertTrue(detail.versions.first?.isDefault ?? false)

        // The default playable file is the 4K one.
        guard let key = ShareCatalogID.movieKey(forMovieID: id) else { return XCTFail() }
        let def = await store.defaultMovieRelPath(forKey: key)
        XCTAssertEqual(def, "Movies/Star Wars (1977)/Star Wars (1977) Bluray-2160p.mkv")
    }

    /// Loose files (no shared folder) still group by parsed title+year.
    func testLooseFilesGroupByTitleYear() async {
        let store = ShareCatalogStore(accountKey: "a", directory: tempDir())
        let tree: [String: [SMBShareBrowser.Entry]] = [
            "": [dir("Movies")],
            "Movies": [
                file("Inception (2010) 2160p.mkv"),
                file("Inception (2010) 1080p.mkv"),
            ],
        ]
        await scan(tree, into: store)
        let count2 = await store.movieCount()
        XCTAssertEqual(count2, 1)
        let movies = await store.movies(offset: 0, limit: 10)
        XCTAssertEqual(movies.first?.title, "Inception")
        let detail = await store.item(id: movies.first!.id)
        XCTAssertEqual(detail?.versions.count, 2)
    }

    /// Same title, DIFFERENT year → two distinct movies (a remake isn't a version).
    func testSameTitleDifferentYearStaysSeparate() async {
        let store = ShareCatalogStore(accountKey: "a", directory: tempDir())
        let tree: [String: [SMBShareBrowser.Entry]] = [
            "": [dir("Movies")],
            "Movies": [
                file("The Italian Job (1969).mkv"),
                file("The Italian Job (2003).mkv"),
            ],
        ]
        await scan(tree, into: store)
        let countYears = await store.movieCount()
        XCTAssertEqual(countYears, 2, "different years are different films")
    }

    /// Stacked multi-part movie (CD1/CD2) must NOT collapse into one title whose
    /// "versions" are each half a movie.
    func testStackedPartsAreNotVersions() async {
        let store = ShareCatalogStore(accountKey: "a", directory: tempDir())
        let tree: [String: [SMBShareBrowser.Entry]] = [
            "": [dir("Movies")],
            "Movies": [dir("Gone with the Wind (1939)")],
            "Movies/Gone with the Wind (1939)": [
                file("Gone with the Wind (1939) CD1.avi"),
                file("Gone with the Wind (1939) CD2.avi"),
            ],
        ]
        await scan(tree, into: store)
        let countParts = await store.movieCount()
        XCTAssertEqual(countParts, 2, "CD1/CD2 are parts, not versions")
    }

    /// A single-file movie shows no version picker.
    func testSingleFileMovieHasNoVersions() async {
        let store = ShareCatalogStore(accountKey: "a", directory: tempDir())
        let tree: [String: [SMBShareBrowser.Entry]] = [
            "": [dir("Movies")],
            "Movies": [file("Dune (2021) 2160p.mkv")],
        ]
        await scan(tree, into: store)
        let movies = await store.movies(offset: 0, limit: 10)
        let detail = await store.item(id: movies.first!.id)
        XCTAssertEqual(detail?.versions.count, 0, "one file = no picker")
        XCTAssertFalse(detail?.hasMultipleVersions ?? true)
    }

    /// Watch-state is unified on the logical movie: a version file id canonicalizes
    /// to `movie:<key>` so resume is shared across versions.
    func testCanonicalItemIDFoldsVersionToLogicalMovie() async {
        let store = ShareCatalogStore(accountKey: "a", directory: tempDir())
        let tree: [String: [SMBShareBrowser.Entry]] = [
            "": [dir("Movies")],
            "Movies": [dir("Heat (1995)")],
            "Movies/Heat (1995)": [
                file("Heat (1995) 2160p.mkv"),
                file("Heat (1995) 1080p.mkv"),
            ],
        ]
        await scan(tree, into: store)
        let fileID = ShareCatalogID.file("Movies/Heat (1995)/Heat (1995) 2160p.mkv")
        let canonical = await store.canonicalItemID(fileID)
        XCTAssertTrue(canonical.hasPrefix("movie:"), "a movie version folds to its logical id")
        // Both files fold to the SAME logical id.
        let other = await store.canonicalItemID(ShareCatalogID.file("Movies/Heat (1995)/Heat (1995) 1080p.mkv"))
        XCTAssertEqual(canonical, other)
    }

    /// An episode id is NOT folded (episodes keep their own watch id).
    func testEpisodeIDIsNotFolded() async {
        let store = ShareCatalogStore(accountKey: "a", directory: tempDir())
        let tree: [String: [SMBShareBrowser.Entry]] = [
            "": [dir("TV")],
            "TV": [dir("Show")],
            "TV/Show": [file("Show - S01E01.mkv")],
        ]
        await scan(tree, into: store)
        let epID = ShareCatalogID.file("TV/Show/Show - S01E01.mkv")
        let epCanonical = await store.canonicalItemID(epID)
        XCTAssertEqual(epCanonical, epID)
    }
}
