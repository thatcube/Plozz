import XCTest
import CoreModels
import CoreNetworking
@testable import ProviderPlex

/// Watchlist detail metadata: a Plex Watchlist title that isn't in any library
/// carries a **global Discover id**, so `item(id:)` must resolve it against the
/// plex.tv Discover host (full overview/cast/ratings) instead of 404'ing on the
/// per-server PMS API — the fix for the previously blank watchlist detail body.
final class PlexDiscoverMetadataTests: XCTestCase {
    private func makeSession() -> UserSession {
        UserSession(
            server: MediaServer(id: "srv", name: "Home", baseURL: URL(string: "https://plex.host:32400")!, provider: .plex),
            userID: "u1", userName: "Alice", deviceID: "d1", accessToken: "TOKEN"
        )
    }

    /// A full Discover metadata payload for one not-owned movie (no `Media`, i.e.
    /// nothing playable on any server), carrying overview/genres/cast/ratings +
    /// external ids so cross-server discovery and the request path can match it.
    private let discoverPayload = """
    {"MediaContainer":{"size":1,"Metadata":[
      {"ratingKey":"5d7768265af944001f1f6977","type":"movie",
       "title":"2 Fast 2 Furious","year":2003,
       "guid":"plex://movie/5d7768265af944001f1f6977",
       "summary":"Ex-cop Brian teams up with an old friend to bring down a drug lord.",
       "Genre":[{"tag":"Action"},{"tag":"Crime"}],
       "Role":[{"tag":"Paul Walker","role":"Brian O'Conner"},
               {"tag":"Tyrese Gibson","role":"Roman Pearce"}],
       "Rating":[{"image":"imdb://image.rating","type":"audience","value":5.9}],
       "Guid":[{"id":"imdb://tt0322259"},{"id":"tmdb://584"}]}
    ]}}
    """

    // MARK: - discoverMetadataID heuristic

    func testDiscoverMetadataIDResolvesGuidAndBareHex() {
        // plex:// guid → its tail.
        XCTAssertEqual(
            PlexClient.discoverMetadataID(from: "plex://movie/5d7768265af944001f1f6977"),
            "5d7768265af944001f1f6977"
        )
        // A bare Discover id (hex with letters) → itself.
        XCTAssertEqual(
            PlexClient.discoverMetadataID(from: "5d7768265af944001f1f6977"),
            "5d7768265af944001f1f6977"
        )
    }

    func testDiscoverMetadataIDRejectsNumericRatingKeyAndSlugs() {
        // A per-server PMS ratingKey is a plain integer → stays on the library path.
        XCTAssertNil(PlexClient.discoverMetadataID(from: "12345"))
        XCTAssertNil(PlexClient.discoverMetadataID(from: ""))
        // Non-hex tokens are ignored (only hex-with-letter qualifies).
        XCTAssertNil(PlexClient.discoverMetadataID(from: "not-a-hex-id"))
    }

    // MARK: - item(id:) resolution

    func testItemWithDiscoverIDResolvesViaDiscoverHost() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/library/metadata/5d7768265af944001f1f6977", json: discoverPayload)
        let provider = PlexProvider(session: makeSession(), http: stub)

        let item = try await provider.item(id: "5d7768265af944001f1f6977")

        // Full body populated from Discover (was blank before the fix).
        XCTAssertEqual(item.title, "2 Fast 2 Furious")
        XCTAssertFalse((item.overview ?? "").isEmpty)
        XCTAssertEqual(item.genres, ["Action", "Crime"])
        XCTAssertEqual(item.cast.map(\.name), ["Paul Walker", "Tyrese Gibson"])
        // Global guid preserved so the watchlist toggle + cross-server discovery work.
        XCTAssertEqual(item.providerIDs["PlexGuid"], "plex://movie/5d7768265af944001f1f6977")
        // The request hit the Discover host, not the per-server PMS.
        let host = stub.baseURL(forPathSuffix: "/library/metadata/5d7768265af944001f1f6977")?.host
        XCTAssertEqual(host, "discover.provider.plex.tv")
    }

    func testItemWithGuidIDResolvesViaDiscoverHost() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/library/metadata/5d7768265af944001f1f6977", json: discoverPayload)
        let provider = PlexProvider(session: makeSession(), http: stub)

        let item = try await provider.item(id: "plex://movie/5d7768265af944001f1f6977")

        XCTAssertEqual(item.title, "2 Fast 2 Furious")
        let host = stub.baseURL(forPathSuffix: "/library/metadata/5d7768265af944001f1f6977")?.host
        XCTAssertEqual(host, "discover.provider.plex.tv")
    }

    func testItemWithNumericRatingKeyStaysOnLibraryHost() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/library/metadata/12345", json: """
        {"MediaContainer":{"size":1,"Metadata":[
          {"ratingKey":"12345","type":"movie","title":"Owned Movie","year":2020,
           "Media":[{"id":1,"Part":[{"id":2,"key":"/library/parts/2/file.mkv"}]}]}
        ]}}
        """)
        let provider = PlexProvider(session: makeSession(), http: stub)

        let item = try await provider.item(id: "12345")

        XCTAssertEqual(item.title, "Owned Movie")
        // Library-first: numeric ratingKey resolves against the per-server PMS.
        let host = stub.baseURL(forPathSuffix: "/library/metadata/12345")?.host
        XCTAssertEqual(host, "plex.host")
    }

    func testItemWithNumericRatingKeyNotFoundRethrows() async {
        let stub = StubHTTPClient()
        // No stub for /library/metadata/999 → the stub 404s → notFound. A numeric id
        // isn't a Discover id, so there's nothing to fall back to.
        let provider = PlexProvider(session: makeSession(), http: stub)
        do {
            _ = try await provider.item(id: "999")
            XCTFail("expected notFound")
        } catch {
            XCTAssertEqual(error as? AppError, .notFound)
        }
    }

    // MARK: - discoverMetadata parse

    func testDiscoverMetadataParsesFullBody() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/library/metadata/5d7768265af944001f1f6977", json: discoverPayload)
        let client = PlexClient(
            baseURL: URL(string: "https://plex.host:32400")!,
            deviceProfile: PlexDeviceProfile(clientIdentifier: "dev1"),
            token: "TOKEN",
            http: stub
        )

        let dto = try await client.discoverMetadata(metadataID: "5d7768265af944001f1f6977")

        XCTAssertEqual(dto.title, "2 Fast 2 Furious")
        XCTAssertEqual(dto.summary?.isEmpty, false)
        XCTAssertEqual(dto.Genre?.compactMap(\.tag), ["Action", "Crime"])
        XCTAssertEqual(dto.Role?.compactMap(\.tag), ["Paul Walker", "Tyrese Gibson"])
    }
}
