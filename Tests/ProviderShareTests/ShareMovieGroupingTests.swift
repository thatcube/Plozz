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

    /// Real regression: release metadata disagrees by one year (festival vs
    /// theatrical date) but both files are the same film and must become versions.
    func testSameTitleAdjacentYearsGroupWithDescriptiveVersions() async {
        let store = ShareCatalogStore(accountKey: "a", directory: tempDir())
        let tree: [String: [SMBShareBrowser.Entry]] = [
            "": [dir("Movies")],
            "Movies": [
                file("A.Quiet.Place.Part.II.2020.1080p.WEB.H264.AAC.5.1-CyEg.mkv", size: 4_000_000_000),
                file("A Quiet Place Part II (2021) [imdbid-tt8332922] - [WEBDL-2160p][DV HDR10Plus][EAC3 Atmos 5.1][h265]-PIRATES.mkv", size: 18_000_000_000),
            ],
        ]
        await scan(tree, into: store)

        let count = await store.movieCount()
        XCTAssertEqual(count, 1)
        let movies = await store.movies(offset: 0, limit: 10)
        XCTAssertEqual(movies.count, 1)

        guard let detail = await store.item(id: movies[0].id) else {
            return XCTFail("grouped movie must resolve")
        }
        XCTAssertEqual(detail.versions.count, 2)
        XCTAssertTrue(detail.versions.contains { $0.displayLabel.contains("1080p") })
        XCTAssertTrue(detail.versions.contains {
            $0.displayLabel.contains("4K") && $0.displayLabel.contains("Dolby Vision")
        })
        XCTAssertFalse(detail.versions.contains { $0.displayLabel == "Version" })

        let old2020ID = ShareCatalogID.movie(
            ShareCatalogID.movieKey(fromTitle: "A Quiet Place Part II", year: 2020)
        )
        let canonicalOldID = await store.canonicalItemID(old2020ID)
        XCTAssertEqual(
            canonicalOldID,
            movies[0].id,
            "pre-grouping logical ids must alias to the combined movie"
        )
        let oldItem = await store.item(id: old2020ID)
        XCTAssertEqual(
            oldItem?.id,
            movies[0].id,
            "old deep links must resolve the combined movie"
        )
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

    /// A single-file movie retains one named version for future cross-server /
    /// same-account merging, but still shows no picker (`hasMultipleVersions=false`).
    func testSingleFileMovieRetainsNamedVersionWithoutPicker() async {
        let store = ShareCatalogStore(accountKey: "a", directory: tempDir())
        let tree: [String: [SMBShareBrowser.Entry]] = [
            "": [dir("Movies")],
            "Movies": [file("Dune (2021) 2160p.mkv")],
        ]
        await scan(tree, into: store)
        let movies = await store.movies(offset: 0, limit: 10)
        let detail = await store.item(id: movies.first!.id)
        XCTAssertEqual(detail?.versions.count, 1)
        XCTAssertTrue(detail?.versions.first?.displayLabel.contains("4K") ?? false)
        XCTAssertNotEqual(detail?.versions.first?.displayLabel, "Version")
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

    /// A stale identity-index ref can still address an old `f:<path>` item. It
    /// must retain filename/quality metadata instead of becoming "Version".
    func testLegacyFileMovieLookupRetainsNamedVersion() async {
        let store = ShareCatalogStore(accountKey: "a", directory: tempDir())
        let path = "Movies/A Quiet Place Part II (2021) WEBDL-2160p DV.mkv"
        let tree: [String: [SMBShareBrowser.Entry]] = [
            "": [dir("Movies")],
            "Movies": [file((path as NSString).lastPathComponent)],
        ]
        await scan(tree, into: store)

        let legacy = await store.item(id: ShareCatalogID.file(path))
        XCTAssertEqual(legacy?.versions.count, 1)
        XCTAssertTrue(legacy?.versions[0].displayLabel.contains("4K") ?? false)
        XCTAssertTrue(legacy?.versions[0].displayLabel.contains("Dolby Vision") ?? false)
        XCTAssertNotEqual(legacy?.versions[0].displayLabel, "Version")
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
