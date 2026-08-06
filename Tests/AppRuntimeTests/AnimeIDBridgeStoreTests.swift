import CoreModels
import XCTest
@testable import AppRuntime

/// The published dataset is not uniformly typed, and assuming it was is how a
/// mapping file silently parses to nothing. These pin the real shapes, taken
/// from the live file: a number, an ARRAY of strings, and an OBJECT keyed by
/// media type.
final class AnimeIDBridgeDecodingTests: XCTestCase {
    /// The exact row for the show that was appearing twice on device.
    private let chainsawManJSON = """
    [{"type":"TV","anidb_id":15914,"anilist_id":127230,
      "imdb_id":["tt13616990"],"mal_id":44511,
      "themoviedb_id":{"tv":114410},"tvdb_id":397934}]
    """

    func testDecodesTheRealDatasetShapes() async throws {
        let store = AnimeIDBridgeStore(
            directoryURL: nil,
            sourceURL: URL(string: "https://example.invalid/anime.json")!,
            fetch: { [json = chainsawManJSON] _ in Data(json.utf8) }
        )

        let bridge = await store.refreshIfNeeded()

        let mapping = try XCTUnwrap(
            bridge.mapping(namespace: .aniList, value: "127230")
        )
        XCTAssertEqual(mapping.aniDB, "15914")
        XCTAssertEqual(mapping.myAnimeList, "44511")
        // The array form.
        XCTAssertEqual(mapping.imdb, "tt13616990")
        // The object form.
        XCTAssertEqual(mapping.tmdb, "114410")
        XCTAssertEqual(mapping.tvdb, "397934")
    }

    /// A failed fetch must leave the watchlist working. A stale bridge is
    /// strictly better than none — it merges everything it knew yesterday.
    func testFetchFailureYieldsAnEmptyBridgeRatherThanThrowing() async {
        let store = AnimeIDBridgeStore(
            directoryURL: nil,
            sourceURL: URL(string: "https://example.invalid/anime.json")!,
            fetch: { _ in throw URLError(.notConnectedToInternet) }
        )

        let bridge = await store.refreshIfNeeded()

        XCTAssertTrue(bridge.isEmpty)
    }
}
