import XCTest
import CoreModels
@testable import ProviderPlex

/// `PlexProvider.libraryHubs` maps `/hubs/sections/{id}` into the additive
/// discovery rows unmerged Home shows for a library, dropping hubs the uniform
/// base rows already cover (Recently Added, On Deck) and hubs with no playable
/// items. The fixture mirrors the shape a real Plex Media Server returns.
final class PlexHubsTests: XCTestCase {
    private func makeSession() -> UserSession {
        UserSession(
            server: MediaServer(id: "srv", name: "Home", baseURL: URL(string: "https://plex.host:32400")!, provider: .plex),
            userID: "u1", userName: "Alice", deviceID: "d1", accessToken: "TOKEN"
        )
    }

    /// A representative `/hubs/sections/1` payload:
    ///  - Recently Added  → dropped (base row duplicate)
    ///  - On Deck         → dropped (base row duplicate)
    ///  - More in Drama   → kept (genre discovery hub)
    ///  - Because You Watched → kept (similar hub)
    ///  - Top Rated       → kept
    ///  - Genres          → dropped (Directory-only, no playable items)
    ///  - Recently Released (empty) → dropped (no items)
    private let hubsJSON = """
    {"MediaContainer":{"size":7,"Hub":[
      {"hubIdentifier":"movie.recentlyadded.1","context":"hub.movie.recentlyadded","title":"Recently Added Movies","type":"movie","more":true,
       "Metadata":[{"ratingKey":"1","type":"movie","title":"New Arrival","librarySectionID":1}]},
      {"hubIdentifier":"movie.ondeck.1","context":"hub.movie.ondeck","title":"On Deck","type":"movie","more":false,
       "Metadata":[{"ratingKey":"2","type":"movie","title":"Half-Watched","librarySectionID":1,"viewOffset":1000,"duration":7200000}]},
      {"hubIdentifier":"movie.genre.drama","context":"hub.movie.genre","title":"More in Drama","type":"movie","more":true,
       "Metadata":[
         {"ratingKey":"10","type":"movie","title":"Drama A","librarySectionID":1},
         {"ratingKey":"11","type":"movie","title":"Drama B","librarySectionID":1},
         {"ratingKey":"12","type":"movie","title":"Drama C","librarySectionID":1}
       ]},
      {"hubIdentifier":"movie.similar.10","context":"hub.movie.similar","title":"Because You Watched Drama A","type":"movie","more":true,
       "Metadata":[{"ratingKey":"20","type":"movie","title":"Similar One","librarySectionID":1}]},
      {"hubIdentifier":"movie.toprated","context":"hub.movie.toprated","title":"Top Rated","type":"movie","more":true,
       "Metadata":[{"ratingKey":"30","type":"movie","title":"Acclaimed","librarySectionID":1}]},
      {"hubIdentifier":"movie.genres","context":"hub.movie.genres","title":"Genres","type":"movie","more":false,
       "Directory":[{"key":"/library/sections/1/genre/1","title":"Drama"}]},
      {"hubIdentifier":"movie.recentlyReleased","context":"hub.movie.recentlyReleased","title":"Recently Released","type":"movie","more":false,
       "Metadata":[]}
    ]}}
    """

    func testFiltersDuplicateAndEmptyHubsAndMapsTheRest() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/hubs/sections/1", json: hubsJSON)
        let provider = PlexProvider(session: makeSession(), http: stub)

        let sections = try await provider.libraryHubs(libraryID: "1", kind: .movie, limit: 20)

        // Only the three additive discovery hubs survive, in server order.
        XCTAssertEqual(sections.map(\.title), ["More in Drama", "Because You Watched Drama A", "Top Rated"])
        XCTAssertEqual(sections.map(\.id), ["movie.genre.drama", "movie.similar.10", "movie.toprated"])
        // The genre hub kept all three of its items, mapped to MediaItems.
        XCTAssertEqual(sections.first?.items.map(\.title), ["Drama A", "Drama B", "Drama C"])
        // Hub items carry their library attribution (librarySectionID → libraryID).
        XCTAssertEqual(sections.first?.items.first?.libraryID, "1")
        // Every kept section is a poster row and non-empty.
        XCTAssertTrue(sections.allSatisfy { $0.style == .poster && !$0.items.isEmpty })
    }

    func testCapsItemsPerHubToLimit() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/hubs/sections/1", json: hubsJSON)
        let provider = PlexProvider(session: makeSession(), http: stub)

        let sections = try await provider.libraryHubs(libraryID: "1", kind: .movie, limit: 2)
        // "More in Drama" has 3 items in the fixture; the limit clamps it to 2.
        XCTAssertEqual(sections.first?.items.count, 2)
    }

    func testIsBaseDuplicateHubMatchesStableTokensOnly() {
        // Duplicates of the uniform base rows are dropped…
        XCTAssertTrue(PlexProvider.isBaseDuplicateHub(identifier: "movie.recentlyadded.1", context: "hub.movie.recentlyadded"))
        XCTAssertTrue(PlexProvider.isBaseDuplicateHub(identifier: "movie.ondeck.1", context: "hub.movie.ondeck"))
        XCTAssertTrue(PlexProvider.isBaseDuplicateHub(identifier: nil, context: "hub.continueWatching"))
        // …while genre / similar / "start watching" discovery hubs are kept.
        XCTAssertFalse(PlexProvider.isBaseDuplicateHub(identifier: "movie.genre.drama", context: "hub.movie.genre"))
        XCTAssertFalse(PlexProvider.isBaseDuplicateHub(identifier: "movie.similar.10", context: "hub.movie.similar"))
        XCTAssertFalse(PlexProvider.isBaseDuplicateHub(identifier: "tv.startWatching", context: "hub.tv.startWatching"))
    }
}
