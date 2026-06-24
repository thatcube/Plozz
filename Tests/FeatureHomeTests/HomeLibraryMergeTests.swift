import XCTest
@testable import CoreModels
@testable import FeatureHome

/// Tests `HomeAggregator.mergeLibraries`, which folds the *same* library living
/// on several servers into one Home tile (criterion 1, Library half) while
/// keeping the Settings checklist's per-account list untouched.
final class HomeLibraryMergeTests: XCTestCase {

    private func aggregated(
        account: String,
        libraryID: String,
        title: String,
        kind: MediaItemKind = .movie,
        provider: ProviderKind = .jellyfin
    ) -> AggregatedLibrary {
        AggregatedLibrary(
            accountID: account,
            accountName: "User-\(account)",
            serverName: "Server-\(account)",
            providerKind: provider,
            library: MediaLibrary(id: libraryID, title: title, kind: kind).taggingSource(account)
        )
    }

    func testMergesSameTitleLibraryAcrossServersIntoOneTile() {
        let plex = aggregated(account: "plex", libraryID: "movies-plex", title: "Movies", provider: .plex)
        let jelly = aggregated(account: "jelly", libraryID: "movies-jelly", title: "Movies", provider: .jellyfin)

        let merged = HomeAggregator.mergeLibraries([plex, jelly])

        XCTAssertEqual(merged.count, 1, "One Movies tile across both servers")
        let tile = merged[0]
        XCTAssertEqual(tile.key, "plex:movies-plex", "Primary's stable visibility key is preserved")
        XCTAssertEqual(tile.library.allSourceAccountIDs, ["plex", "jelly"])
        XCTAssertEqual(tile.library.containerID(forSourceAccountID: "plex"), "movies-plex")
        XCTAssertEqual(tile.library.containerID(forSourceAccountID: "jelly"), "movies-jelly",
                       "Each server's own container id is addressable for aggregated browse")
    }

    func testDoesNotMergeDifferentTitles() {
        let movies = aggregated(account: "plex", libraryID: "m", title: "Movies")
        let shows = aggregated(account: "plex", libraryID: "t", title: "TV Shows")
        let merged = HomeAggregator.mergeLibraries([movies, shows])
        XCTAssertEqual(merged.count, 2)
    }

    func testDoesNotMergeSameTitleDifferentKind() {
        let movieLib = aggregated(account: "plex", libraryID: "m", title: "Favourites", kind: .movie)
        let showLib = aggregated(account: "jelly", libraryID: "t", title: "Favourites", kind: .series)
        let merged = HomeAggregator.mergeLibraries([movieLib, showLib])
        XCTAssertEqual(merged.count, 2, "Kind is part of the library identity")
    }

    func testTitleMatchIsCaseAndPunctuationInsensitive() {
        let a = aggregated(account: "plex", libraryID: "m1", title: "Kids' Movies")
        let b = aggregated(account: "jelly", libraryID: "m2", title: "kids movies")
        let merged = HomeAggregator.mergeLibraries([a, b])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].library.allSourceAccountIDs, ["plex", "jelly"])
    }

    func testPreservesFirstSeenOrder() {
        let shows = aggregated(account: "plex", libraryID: "t", title: "TV Shows")
        let movies1 = aggregated(account: "plex", libraryID: "m", title: "Movies")
        let movies2 = aggregated(account: "jelly", libraryID: "m2", title: "Movies")
        let merged = HomeAggregator.mergeLibraries([shows, movies1, movies2])
        XCTAssertEqual(merged.map(\.library.title), ["TV Shows", "Movies"])
    }

    func testThreeServersFoldIntoOne() {
        let a = aggregated(account: "a", libraryID: "ma", title: "Movies")
        let b = aggregated(account: "b", libraryID: "mb", title: "Movies")
        let c = aggregated(account: "c", libraryID: "mc", title: "Movies")
        let merged = HomeAggregator.mergeLibraries([a, b, c])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].library.allSourceAccountIDs, ["a", "b", "c"])
        XCTAssertEqual(merged[0].library.sourceContainerIDByAccount,
                       ["a": "ma", "b": "mb", "c": "mc"])
    }

    func testSingleServerLibraryIsUnchangedAndSingleSource() {
        let only = aggregated(account: "plex", libraryID: "m", title: "Movies")
        let merged = HomeAggregator.mergeLibraries([only])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].library.allSourceAccountIDs, ["plex"],
                       "A lone library stays single-source so browse uses the direct provider path")
    }
}
