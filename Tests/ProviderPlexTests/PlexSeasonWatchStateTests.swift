import XCTest
import CoreModels
import CoreNetworking
@testable import ProviderPlex

/// Watch state on **season containers**.
///
/// Plex never increments `viewCount` on a container — a series or a season
/// expresses progress through `leafCount` / `viewedLeafCount`. The mapper applied
/// that rule to `.series` only, so every *season* reported unplayed no matter how
/// much of it had been watched.
///
/// That is load-bearing rather than cosmetic: anything asking "which season is
/// the viewer on" resolves over the season containers, so with none of them ever
/// played the answer was always "the first unwatched one" — i.e. Season 1. A Plex
/// show watched into Season 5 opened on Season 1.
final class PlexSeasonWatchStateTests: XCTestCase {
    private func makeSession() -> UserSession {
        UserSession(
            server: MediaServer(id: "srv", name: "Home", baseURL: URL(string: "https://plex.host:32400")!, provider: .plex),
            userID: "u1", userName: "Alice", deviceID: "d1", accessToken: "TOKEN"
        )
    }

    /// Three seasons: S1 fully watched, S2 partly, S3 untouched. No `viewCount`
    /// anywhere, which is exactly what Plex sends for containers.
    private func makeProvider() -> PlexProvider {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/library/metadata/9/children", json: """
        {"MediaContainer":{"size":3,"Metadata":[
          {"ratingKey":"s1","type":"season","title":"Season 1","index":1,
           "leafCount":10,"viewedLeafCount":10},
          {"ratingKey":"s2","type":"season","title":"Season 2","index":2,
           "leafCount":10,"viewedLeafCount":4},
          {"ratingKey":"s3","type":"season","title":"Season 3","index":3,
           "leafCount":10,"viewedLeafCount":0}
        ]}}
        """)
        return PlexProvider(session: makeSession(), http: stub)
    }

    func testFullyWatchedSeasonReportsPlayed() async throws {
        let seasons = try await makeProvider().children(of: "9")
        let s1 = try XCTUnwrap(seasons.first { $0.id == "s1" })
        XCTAssertTrue(
            s1.isPlayed,
            "every episode watched must mark the season played — Plex sends no viewCount for a container"
        )
        XCTAssertEqual(s1.playedPercentage, 1.0)
    }

    func testPartlyWatchedSeasonReportsProgressButNotPlayed() async throws {
        let seasons = try await makeProvider().children(of: "9")
        let s2 = try XCTUnwrap(seasons.first { $0.id == "s2" })
        XCTAssertFalse(s2.isPlayed)
        XCTAssertEqual(try XCTUnwrap(s2.playedPercentage), 0.4, accuracy: 0.0001,
                       "a container's progress is its watched fraction, not a resume ratio")
        XCTAssertTrue(s2.hasBeenPlayed, "a partly-watched season has been started")
    }

    func testUntouchedSeasonReportsNothing() async throws {
        let seasons = try await makeProvider().children(of: "9")
        let s3 = try XCTUnwrap(seasons.first { $0.id == "s3" })
        XCTAssertFalse(s3.isPlayed)
        XCTAssertFalse(s3.hasBeenPlayed)
        XCTAssertNil(s3.playedPercentage)
    }

    /// The bug this fixes, stated as behaviour: with S1 complete and S2 started,
    /// "which season is the viewer on" must answer S2 — not Season 1.
    func testSeasonsResolveToTheOneBeingWatched() async throws {
        let seasons = try await makeProvider().children(of: "9")
        let inProgress = seasons.first { !$0.isPlayed && $0.hasBeenPlayed }
        XCTAssertEqual(inProgress?.id, "s2")

        let firstUnwatched = seasons.first { !$0.isPlayed }
        XCTAssertEqual(firstUnwatched?.id, "s2",
                       "S1 is complete, so the first unwatched season is S2")
    }

    /// A season with no episodes must not read as complete: `viewedLeafCount >=
    /// leafCount` is trivially true at 0 >= 0.
    func testEmptySeasonIsNotComplete() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/library/metadata/9/children", json: """
        {"MediaContainer":{"size":1,"Metadata":[
          {"ratingKey":"s0","type":"season","title":"Season 1","index":1,
           "leafCount":0,"viewedLeafCount":0}
        ]}}
        """)
        let seasons = try await PlexProvider(session: makeSession(), http: stub).children(of: "9")
        XCTAssertFalse(try XCTUnwrap(seasons.first).isPlayed)
    }

    /// Episodes keep resume-ratio progress — the container rule must not leak
    /// into leaves, which do carry a real runtime.
    func testEpisodeProgressStillUsesResumePosition() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/library/metadata/s1/children", json: """
        {"MediaContainer":{"size":1,"Metadata":[
          {"ratingKey":"e1","type":"episode","title":"Pilot","index":1,
           "duration":1000000,"viewOffset":250000}
        ]}}
        """)
        let episodes = try await PlexProvider(session: makeSession(), http: stub).children(of: "s1")
        let e1 = try XCTUnwrap(episodes.first)
        XCTAssertEqual(try XCTUnwrap(e1.playedPercentage), 0.25, accuracy: 0.0001)
        XCTAssertFalse(e1.isPlayed)
    }
}
