import CoreModels
import CoreNetworking
import Foundation
import XCTest
@testable import SimklService
@testable import TestSupportNetworking

/// Simkl's half of the universal watchlist. These pin the translation between
/// Plozz's identity vocabulary and Simkl's payloads — the part that has to be
/// right for a title saved on the Apple TV to appear on simkl.com.
final class SimklWatchlistDestinationTests: XCTestCase {
    private func configured() -> SimklConfig {
        SimklConfig(clientID: "client")
    }

    private func makeDestination(
        http: HTTPClient,
        tokens: SimklTokens? = SimklTokens(accessToken: "acc")
    ) -> SimklWatchlistDestination {
        SimklWatchlistDestination(
            config: configured(),
            http: http,
            tokenStore: InMemorySimklTokenStore(tokens: tokens)
        )
    }

    // MARK: - Reading

    func testReadsMoviesAndShowsFromSeparateEndpoints() async throws {
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/sync/all-items/movies/plantowatch", json: """
        {"movies":[{"added_to_watchlist_at":"2026-02-01T00:00:00Z",
          "movie":{"title":"Dune","year":2021,
          "ids":{"simkl":1,"imdb":"tt1160419","tmdb":438631}}}]}
        """)
        http.stub(pathSuffix: "/sync/all-items/shows/plantowatch", json: """
        {"shows":[{"added_to_watchlist_at":"2026-01-01T00:00:00Z",
          "show":{"title":"Severance","year":2022,
          "ids":{"simkl":2,"tvdb":371980}}}]}
        """)

        let entries = try await makeDestination(http: http).fetchEntries()

        XCTAssertEqual(entries.map(\.kind), [.movie, .series])
        XCTAssertTrue(entries[0].externalIDs.contains {
            $0.namespace == .imdb && $0.value == "tt1160419"
        })
        XCTAssertTrue(entries[1].externalIDs.contains {
            $0.namespace == .tvdb && $0.value == "371980"
        })
        XCTAssertEqual(entries[0].presentation?.title, "Dune")
        XCTAssertEqual(entries[1].presentation?.year, 2022)
        XCTAssertTrue(
            http.sent.allSatisfy {
                !$0.queryItems.contains { $0.name == "extended" }
            },
            "The default response includes presentation and added-time metadata"
        )
    }

    func testNewerShowSortsBeforeOlderMovie() async throws {
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/sync/all-items/movies/plantowatch", json: """
        {"movies":[{"added_to_watchlist_at":"2026-01-01T00:00:00Z",
          "movie":{"title":"Older Movie","ids":{"imdb":"tt1"}}}]}
        """)
        http.stub(pathSuffix: "/sync/all-items/shows/plantowatch", json: """
        {"shows":[{"added_to_watchlist_at":"2026-02-01T00:00:00Z",
          "show":{"title":"Newer Show","ids":{"tvdb":2}}}]}
        """)

        let entries = try await makeDestination(http: http).fetchEntries()

        XCTAssertEqual(
            entries.map { $0.presentation?.title },
            ["Newer Show", "Older Movie"]
        )
    }

    func testEqualAddTimesUseBindingAsDeterministicTieBreak() async throws {
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/sync/all-items/movies/plantowatch", json: """
        {"movies":[{"added_to_watchlist_at":"2026-02-01T00:00:00Z",
          "movie":{"title":"Movie","ids":{"imdb":"tt2"}}}]}
        """)
        http.stub(pathSuffix: "/sync/all-items/shows/plantowatch", json: """
        {"shows":[{"added_to_watchlist_at":"2026-02-01T00:00:00Z",
          "show":{"title":"Show","ids":{"tvdb":1}}}]}
        """)

        let entries = try await makeDestination(http: http).fetchEntries()

        XCTAssertEqual(
            entries.map { $0.presentation?.title },
            ["Movie", "Show"]
        )
    }

    func testEqualAddTimesWithinOneKindPreserveProviderOrder() async throws {
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/sync/all-items/movies/plantowatch", json: """
        {"movies":[
          {"added_to_watchlist_at":"2026-02-01T00:00:00Z",
           "movie":{"title":"First","ids":{"imdb":"tt2"}}},
          {"added_to_watchlist_at":"2026-02-01T00:00:00Z",
           "movie":{"title":"Second","ids":{"imdb":"tt1"}}}
        ]}
        """)
        http.stub(
            pathSuffix: "/sync/all-items/shows/plantowatch",
            json: """
            {"shows":[]}
            """
        )

        let entries = try await makeDestination(http: http).fetchEntries()

        XCTAssertEqual(
            entries.map { $0.presentation?.title },
            ["First", "Second"]
        )
    }

    func testMalformedAddTimestampFailsClosed() async throws {
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/sync/all-items/movies/plantowatch", json: """
        {"movies":[{"added_to_watchlist_at":"not-a-date",
          "movie":{"title":"Movie","ids":{"imdb":"tt1"}}}]}
        """)
        http.stub(pathSuffix: "/sync/all-items/shows/plantowatch", json: """
        {"shows":[]}
        """)

        do {
            _ = try await makeDestination(http: http).fetchEntries()
            XCTFail("Expected malformed authoritative ordering data to fail")
        } catch let error as WatchlistDestinationError {
            XCTAssertEqual(error, .transient)
        }
    }

    func testMovieAndShowKindsFetchConcurrently() async throws {
        let http = ConcurrentSimklWatchlistHTTPClient()
        let destination = makeDestination(http: http)

        _ = try await destination.fetchEntries()

        let maximumConcurrentRequests = await http.maximumConcurrentRequests()
        XCTAssertEqual(maximumConcurrentRequests, 2)
    }

    /// Simkl returns numeric ids as a number in some payloads and a string in
    /// others. Both have to land on the same value or the same title read twice
    /// would look like two titles.
    func testNumericIDsDecodeWhetherStringOrNumber() async throws {
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/sync/all-items/movies/plantowatch", json: """
        {"movies":[{"movie":{"title":"Arrival","ids":{"tmdb":"329865"}}}]}
        """)
        http.stub(pathSuffix: "/sync/all-items/shows/plantowatch", json: """
        {"shows":[]}
        """)

        let entries = try await makeDestination(http: http).fetchEntries()

        XCTAssertEqual(entries.count, 1)
        XCTAssertTrue(entries[0].externalIDs.contains {
            $0.namespace == .tmdb && $0.value == "329865"
        })
    }

    private actor ConcurrentSimklWatchlistHTTPClient: HTTPClient {
        private var activeRequests = 0
        private var maximumActiveRequests = 0
        private var startedRequests = 0

        func send(
            _ endpoint: Endpoint,
            baseURL: URL
        ) async throws -> (Data, HTTPURLResponse) {
            activeRequests += 1
            startedRequests += 1
            maximumActiveRequests = max(maximumActiveRequests, activeRequests)
            for _ in 0..<10_000 where startedRequests < 2 {
                await Task.yield()
            }
            activeRequests -= 1
            let json: String
            if endpoint.path.contains("/movies/") {
                json = """
                {"movies":[{"added_to_watchlist_at":"2026-01-01T00:00:00Z",
                  "movie":{"title":"Movie","ids":{"imdb":"tt1"}}}]}
                """
            } else {
                json = """
                {"shows":[{"added_to_watchlist_at":"2026-01-02T00:00:00Z",
                  "show":{"title":"Show","ids":{"tvdb":2}}}]}
                """
            }
            return (
                Data(json.utf8),
                HTTPURLResponse(
                    url: baseURL,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [:]
                )!
            )
        }

        func maximumConcurrentRequests() -> Int {
            maximumActiveRequests
        }
    }

    /// Dropping an unidentifiable title would make a prior confirmation look
    /// externally removed, so the whole read must fail closed instead.
    func testEntryWithNoSharedIdentityRejectsTheIncompleteRead() async throws {
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/sync/all-items/movies/plantowatch", json: """
        {"movies":[{"movie":{"title":"Obscure","ids":{"simkl":99}}}]}
        """)
        http.stub(pathSuffix: "/sync/all-items/shows/plantowatch", json: """
        {"shows":[]}
        """)

        do {
            _ = try await makeDestination(http: http).fetchEntries()
            XCTFail("Expected an incomplete native read to fail")
        } catch let error as WatchlistDestinationError {
            XCTAssertEqual(error, .transient)
        }
    }

    // MARK: - Writing

    func testAddingSendsPlanToWatchForTheRightKind() async throws {
        let http = RecordingHTTPClient()
        http.stubEmpty(pathSuffix: "/sync/add-to-list", status: 200)
        let destination = makeDestination(http: http)
        let binding = try XCTUnwrap(WatchlistDestinationBinding(
            destinationID: WatchlistDestinationID(rawValue: "simkl")!,
            opaqueValue: "movie|imdb|tt1160419"
        ))

        try await destination.apply(.present, to: binding)

        let sent = try XCTUnwrap(http.sent.last)
        XCTAssertTrue(sent.path.hasSuffix("/sync/add-to-list"))
        let movies = try XCTUnwrap(sent.json?["movies"] as? [[String: Any]])
        XCTAssertEqual(movies.count, 1)
        XCTAssertEqual(movies[0]["to"] as? String, "plantowatch")
        let ids = try XCTUnwrap(movies[0]["ids"] as? [String: Any])
        XCTAssertEqual(ids["imdb"] as? String, "tt1160419")
        // A movie must not be filed as a show.
        XCTAssertNil(sent.json?["shows"])
    }

    func testRemovingUsesRemoveFromListAndSendsNoTargetList() async throws {
        let http = RecordingHTTPClient()
        http.stubEmpty(pathSuffix: "/sync/remove-from-list", status: 200)
        let destination = makeDestination(http: http)
        let binding = try XCTUnwrap(WatchlistDestinationBinding(
            destinationID: WatchlistDestinationID(rawValue: "simkl")!,
            opaqueValue: "series|tvdb|371980"
        ))

        try await destination.apply(.absent, to: binding)

        let sent = try XCTUnwrap(http.sent.last)
        XCTAssertTrue(sent.path.hasSuffix("/sync/remove-from-list"))
        let shows = try XCTUnwrap(sent.json?["shows"] as? [[String: Any]])
        XCTAssertNil(shows[0]["to"], "removal targets no list")
        let ids = try XCTUnwrap(shows[0]["ids"] as? [String: Any])
        XCTAssertEqual(ids["tvdb"] as? Int, 371980)
    }

    /// The same shape guard Trakt's destination applies: something that isn't
    /// `tt` + digits is not an IMDb id, and sending it would match nothing.
    func testMalformedIMDbIDIsRejectedRatherThanSent() async throws {
        let http = RecordingHTTPClient()
        http.stubEmpty(pathSuffix: "/sync/add-to-list", status: 200)
        let destination = makeDestination(http: http)
        let binding = try XCTUnwrap(WatchlistDestinationBinding(
            destinationID: WatchlistDestinationID(rawValue: "simkl")!,
            opaqueValue: "movie|imdb|not-an-id"
        ))

        do {
            try await destination.apply(.present, to: binding)
            XCTFail("expected a permanent failure")
        } catch let error as WatchlistDestinationError {
            XCTAssertEqual(error, .permanent)
        }
        XCTAssertTrue(http.sent.isEmpty, "nothing should reach the network")
    }

    // MARK: - Identity + auth

    func testResolvePrefersAnIdentitySimklUnderstands() async throws {
        let destination = makeDestination(http: RecordingHTTPClient())
        let target = try XCTUnwrap(WatchlistMutationTarget(
            aliasID: MediaAliasID(UUID()),
            kind: .movie,
            externalIDs: [
                // Trakt ids mean nothing to Simkl and must not be chosen.
                WatchlistExternalID(namespace: .trakt, value: "500")!,
                WatchlistExternalID(namespace: .tmdb, value: "438631")!,
            ],
            validatedBindings: []
        ))

        let binding = try await destination.resolve(target)

        XCTAssertEqual(binding?.opaqueValue, "movie|tmdb|438631")
    }

    func testDisconnectedAccountAsksForSignInRatherThanRetrying() async {
        let destination = makeDestination(http: RecordingHTTPClient(), tokens: nil)

        do {
            _ = try await destination.fetchEntries()
            XCTFail("expected an authentication failure")
        } catch let error as WatchlistDestinationError {
            // Not `.transient`: retrying without a token can never succeed.
            XCTAssertEqual(error, .authenticationRequired)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
