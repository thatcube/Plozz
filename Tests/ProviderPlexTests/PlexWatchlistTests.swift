import XCTest
import CoreModels
import CoreNetworking
@testable import ProviderPlex

/// Feature B (unified Watchlist) on the Plex provider: the account-level
/// plex.tv Discover writes keyed by the global `plex://` guid, plus the guid
/// stashing that makes them addressable.
final class PlexWatchlistTests: XCTestCase {
    private func makeSession() -> UserSession {
        UserSession(
            server: MediaServer(id: "srv", name: "Home", baseURL: URL(string: "https://plex.host:32400")!, provider: .plex),
            userID: "u1", userName: "Alice", deviceID: "d1", accessToken: "TOKEN"
        )
    }

    // MARK: - guid keying

    func testWatchlistMetadataIDExtractsGuidTail() {
        XCTAssertEqual(PlexClient.watchlistMetadataID(fromGuid: "plex://movie/5d776b9a"), "5d776b9a")
        XCTAssertEqual(PlexClient.watchlistMetadataID(fromGuid: "plex://show/abc123"), "abc123")
        XCTAssertNil(PlexClient.watchlistMetadataID(fromGuid: "imdb://tt0083658"))
        XCTAssertNil(PlexClient.watchlistMetadataID(fromGuid: nil))
        XCTAssertNil(PlexClient.watchlistMetadataID(fromGuid: "plex://movie/"))
    }

    func testProviderIDsStashesPlexGuid() {
        let json = """
        {"ratingKey":"101","type":"movie","title":"Dune","guid":"plex://movie/xyz",
         "Guid":[{"id":"imdb://tt1160419"}]}
        """
        let dto = try! JSONDecoder.plozz.decode(PlexMetadata.self, from: Data(json.utf8))
        let ids = PlexProvider.providerIDs(from: dto)
        XCTAssertEqual(ids["PlexGuid"], "plex://movie/xyz")
        XCTAssertEqual(ids["Imdb"], "tt1160419")
    }

    // MARK: - setWatchlisted via Discover

    func testSetWatchlistedThrowsWithoutGuid() async {
        let stub = StubHTTPClient()
        let provider = PlexProvider(session: makeSession(), http: stub)
        let item = MediaItem(id: "101", title: "m", kind: .movie)
        do {
            try await provider.setWatchlisted(true, item: item)
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(error as? AppError, .notFound)
        }
    }

    func testSetWatchlistedAddsViaDiscover() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/actions/addToWatchlist", json: "{}")
        let provider = PlexProvider(session: makeSession(), http: stub)
        var item = MediaItem(id: "101", title: "m", kind: .movie)
        item.providerIDs = ["PlexGuid": "plex://movie/abc123"]

        try await provider.setWatchlisted(true, item: item)

        XCTAssertEqual(stub.method(forPathSuffix: "/actions/addToWatchlist"), .put)
        let query = stub.queryItems(forPathSuffix: "/actions/addToWatchlist") ?? []
        XCTAssertTrue(query.contains { $0.name == "ratingKey" && $0.value == "abc123" })
    }

    func testSetWatchlistedRemoveUsesRemoveAction() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/actions/removeFromWatchlist", json: "{}")
        let provider = PlexProvider(session: makeSession(), http: stub)
        var item = MediaItem(id: "101", title: "m", kind: .movie)
        item.providerIDs = ["PlexGuid": "plex://movie/abc123"]

        try await provider.setWatchlisted(false, item: item)

        XCTAssertEqual(stub.method(forPathSuffix: "/actions/removeFromWatchlist"), .put)
    }

    // MARK: - watchlist() read

    func testWatchlistMapsItemsAsFavorited() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/library/sections/watchlist/all", json: """
        {"MediaContainer":{"size":1,"Metadata":[
          {"ratingKey":"g1","type":"movie","title":"Dune","year":2021}
        ]}}
        """)
        let provider = PlexProvider(session: makeSession(), http: stub)

        let items = try await provider.watchlist()
        XCTAssertEqual(items.map(\.title), ["Dune"])
        XCTAssertTrue(items.first?.isFavorite ?? false)
    }
}
