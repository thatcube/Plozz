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
    ///  - More in Drama   → kept (genre discovery hub, 3 items)
    ///  - Because You Watched → kept (similar hub, 3 items)
    ///  - Top Rated       → kept (3 items)
    ///  - Top Movies with an Actor → dropped (person hub with a single title)
    ///  - Genres          → dropped (Directory-only, no playable items)
    ///  - Recently Released (empty) → dropped (no items)
    private let hubsJSON = """
    {"MediaContainer":{"size":8,"Hub":[
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
       "Metadata":[
         {"ratingKey":"20","type":"movie","title":"Similar One","librarySectionID":1},
         {"ratingKey":"21","type":"movie","title":"Similar Two","librarySectionID":1},
         {"ratingKey":"22","type":"movie","title":"Similar Three","librarySectionID":1}
       ]},
      {"hubIdentifier":"movie.toprated","context":"hub.movie.toprated","title":"Top Rated","type":"movie","more":true,
       "Metadata":[
         {"ratingKey":"30","type":"movie","title":"Acclaimed","librarySectionID":1},
         {"ratingKey":"31","type":"movie","title":"Acclaimed Two","librarySectionID":1},
         {"ratingKey":"32","type":"movie","title":"Acclaimed Three","librarySectionID":1}
       ]},
      {"hubIdentifier":"movie.by.actor.99","context":"hub.movie.byactor","title":"Top Movies with Misa Koide","type":"movie","more":false,
       "Metadata":[{"ratingKey":"40","type":"movie","title":"Her Only Film","librarySectionID":1}]},
      {"hubIdentifier":"movie.genres","context":"hub.movie.genres","title":"Genres","type":"movie","more":false,
       "Directory":[{"key":"/library/sections/1/genre/1","title":"Drama"}]},
      {"hubIdentifier":"movie.recentlyReleased","context":"hub.movie.recentlyReleased","title":"Recently Released","type":"movie","more":false,
       "Metadata":[]}
    ]}}
    """

    func testFiltersDuplicateSparseAndEmptyHubsAndMapsTheRest() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/hubs/sections/1", json: hubsJSON)
        let provider = PlexProvider(session: makeSession(), http: stub)

        let sections = try await provider.libraryHubs(libraryID: "1", kind: .movie, limit: 20)

        // The three populated discovery hubs survive, in server order. The
        // duplicate (recently added / on deck), the single-title person hub, the
        // Directory-only, and the empty hub are all dropped.
        XCTAssertEqual(sections.map(\.title), ["More in Drama", "Because You Watched Drama A", "Top Rated"])
        XCTAssertEqual(sections.map(\.id), ["movie.genre.drama", "movie.similar.10", "movie.toprated"])
        XCTAssertFalse(sections.contains { $0.title.contains("Misa Koide") },
                       "A single-title person hub must not become a whole row")
        XCTAssertEqual(sections.first?.items.map(\.title), ["Drama A", "Drama B", "Drama C"])
        XCTAssertEqual(sections.first?.items.first?.libraryID, "1")
        XCTAssertTrue(sections.allSatisfy { $0.style == .poster && $0.items.count >= 3 })
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
        XCTAssertTrue(PlexProvider.isBaseDuplicateHub(identifier: "movie.inprogress", context: nil))
        // …including an identifier-less Continue Watching hub caught by title…
        XCTAssertTrue(PlexProvider.isBaseDuplicateHub(identifier: nil, context: nil, title: "Continue Watching"))
        XCTAssertTrue(PlexProvider.isBaseDuplicateHub(identifier: "", context: "", title: "On Deck"))
        // …while genre / similar / "start watching" discovery hubs are kept.
        XCTAssertFalse(PlexProvider.isBaseDuplicateHub(identifier: "movie.genre.drama", context: "hub.movie.genre"))
        XCTAssertFalse(PlexProvider.isBaseDuplicateHub(identifier: "movie.similar.10", context: "hub.movie.similar", title: "Because You Watched X"))
        XCTAssertFalse(PlexProvider.isBaseDuplicateHub(identifier: "tv.startWatching", context: "hub.tv.startWatching", title: "Start Watching"))
    }

    func testDropsContinueWatchingHubToAvoidDuplicateRow() async throws {
        // A Plex "Continue Watching" hub (identifier-less, title only) must not
        // become a second CW row alongside Plozz's own per-library CW slice.
        let json = """
        {"MediaContainer":{"size":2,"Hub":[
          {"title":"Continue Watching","type":"show","more":true,
           "Metadata":[
             {"ratingKey":"1","type":"episode","title":"Ep1","librarySectionID":2},
             {"ratingKey":"2","type":"episode","title":"Ep2","librarySectionID":2},
             {"ratingKey":"3","type":"episode","title":"Ep3","librarySectionID":2}
           ]},
          {"hubIdentifier":"show.genre.comedy","context":"hub.show.genre","title":"More in Comedy","type":"show","more":true,
           "Metadata":[
             {"ratingKey":"10","type":"show","title":"Com A","librarySectionID":2},
             {"ratingKey":"11","type":"show","title":"Com B","librarySectionID":2},
             {"ratingKey":"12","type":"show","title":"Com C","librarySectionID":2}
           ]}
        ]}}
        """
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/hubs/sections/2", json: json)
        let provider = PlexProvider(session: makeSession(), http: stub)

        let sections = try await provider.libraryHubs(libraryID: "2", kind: .series, limit: 20)
        XCTAssertEqual(sections.map(\.title), ["More in Comedy"],
                       "The Continue Watching hub must be dropped; only the genre discovery hub remains")
    }
}
