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
        XCTAssertFalse(
            items.first?.locallyValidatedPlayableSource ?? true
        )
    }

    /// Regression: the watchlist READ must hit `discover.provider.plex.tv`, not
    /// the legacy `metadata.provider.plex.tv` host (which now 404s — reads were
    /// migrated to the Discover host, matching the write action's host).
    func testWatchlistReadUsesDiscoverHost() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/library/sections/watchlist/all", json: """
        {"MediaContainer":{"size":0,"Metadata":[]}}
        """)
        let provider = PlexProvider(session: makeSession(), http: stub)

        _ = try await provider.watchlist()

        let host = stub.baseURL(forPathSuffix: "/library/sections/watchlist/all")?.host
        XCTAssertEqual(host, "discover.provider.plex.tv")
    }

    func testWatchlistWriteUsesDiscoverHost() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/actions/addToWatchlist", json: "{}")
        let provider = PlexProvider(session: makeSession(), http: stub)
        var item = MediaItem(id: "101", title: "m", kind: .movie)
        item.providerIDs = ["PlexGuid": "plex://movie/abc123"]

        try await provider.setWatchlisted(true, item: item)

        let host = stub.baseURL(forPathSuffix: "/actions/addToWatchlist")?.host
        XCTAssertEqual(host, "discover.provider.plex.tv")
    }

    /// Regression: the Discover watchlist serializes `Media`/`Part`/`Stream` ids
    /// as **strings** (global ids), unlike the PMS API's integers. One string id
    /// must not abort the decode of the whole payload (previously it threw
    /// `typeMismatch: Expected Int … found a string`, yielding an empty row).
    func testWatchlistDecodesDiscoverStringPartIDs() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/library/sections/watchlist/all", json: """
        {"MediaContainer":{"librarySectionID":"watchlist","totalSize":2,"size":2,"Metadata":[
          {"ratingKey":"g1","type":"movie","title":"Dune","year":2021,
           "Media":[{"id":"m-abc","Part":[{"id":"p-xyz","Stream":[{"id":"s-1"}]}]}]},
          {"ratingKey":"g2","type":"show","title":"Severance"}
        ]}}
        """)
        let provider = PlexProvider(session: makeSession(), http: stub)

        let items = try await provider.watchlist()

        XCTAssertEqual(items.map(\.title), ["Dune", "Severance"])
        XCTAssertTrue(items.allSatisfy(\.isFavorite))
    }

    func testUniversalDestinationResolvesPlexGuidButNeverTitleOrExternalSearch() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/actions/addToWatchlist", json: "{}")
        let provider = PlexProvider(session: makeSession(), http: stub)
        let destination = try XCTUnwrap(
            PlexWatchlistDestination(provider: provider)
        )
        var item = MediaItem(id: "local", title: "Dune", kind: .movie)
        item.providerIDs["PlexGuid"] = "plex://movie/abc123"
        let alias = MediaAliasID()
        let resolved = try await destination.resolve(
            WatchlistMutationTarget(aliasID: alias, item: item)!
        )
        let binding = try XCTUnwrap(resolved)
        try await destination.apply(.present, to: binding)
        XCTAssertEqual(
            stub.method(forPathSuffix: "/actions/addToWatchlist"),
            .put
        )

        let unresolved = WatchlistMutationTarget(
            aliasID: MediaAliasID(),
            kind: .movie,
            externalIDs: [
                WatchlistExternalID(namespace: .imdb, value: "tt1160419")!
            ]
        )!
        let unresolvedBinding = try await destination.resolve(unresolved)
        XCTAssertNil(unresolvedBinding)
    }

    func testUniversalDestinationImportProducesCorroboratedAliasEvidence() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/library/sections/watchlist/all", json: """
        {"MediaContainer":{"size":1,"Metadata":[
          {"ratingKey":"abc123","type":"movie","title":"Dune","year":2021,
           "guid":"plex://movie/abc123","Guid":[{"id":"imdb://tt1160419"}]}
        ]}}
        """)
        let provider = PlexProvider(
            session: makeSession(),
            accountID: "plex-account",
            http: stub
        )
        let destination = try XCTUnwrap(
            PlexWatchlistDestination(provider: provider)
        )

        let imported = try await destination.fetchEntries()
        let entry = try XCTUnwrap(imported.first)
        let evidence = try XCTUnwrap(entry.mediaAliasEvidence)

        XCTAssertEqual(evidence.strong.first?.value, "tt1160419")
        XCTAssertEqual(
            evidence.locallyValidatedBindings.first?.providerItemID,
            "abc123"
        )
        let rebound = WatchlistMutationTarget(
            aliasID: MediaAliasID(),
            kind: .movie,
            validatedBindings: Array(evidence.locallyValidatedBindings)
        )!
        let reboundResolution = try await destination.resolve(rebound)
        XCTAssertNotNil(reboundResolution)
    }

    func testDiscoverDetailRemainsUnownedDespiteAccountOrigin() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/library/metadata/abc123", json: """
        {"MediaContainer":{"size":1,"Metadata":[
          {"ratingKey":"abc123","type":"movie","title":"The Legend of Hei",
           "guid":"plex://movie/abc123"}
        ]}}
        """)
        let provider = PlexProvider(session: makeSession(), http: stub)

        var item = try await provider.item(id: "abc123")
        item.sourceAccountID = "plex-account"

        XCTAssertFalse(item.locallyValidatedPlayableSource)
        XCTAssertFalse(item.hasPlayableLibraryTarget())
    }
}
