import CoreModels
import CoreNetworking
import Foundation
import XCTest
@testable import MALService

/// MyAnimeList's half of the universal watchlist.
final class MALWatchlistDestinationTests: XCTestCase {
    private func makeDestination(
        http: RecordingHTTPClient,
        tokens: MALTokens? = MALTokens(
            accessToken: "acc",
            refreshToken: "ref",
            // A concrete date, not `.distantFuture`: subtracting the refresh
            // margin from that overflows and reads as already expired.
            expiresAt: Date().addingTimeInterval(3_600)
        )
    ) -> MALWatchlistDestination {
        MALWatchlistDestination(
            config: MALConfig(clientID: "id"),
            http: http,
            tokenStore: InMemoryMALTokenStore(tokens: tokens)
        )
    }

    private func target(
        kind: MediaItemKind,
        _ ids: [(WatchlistExternalID.Namespace, String)]
    ) throws -> WatchlistMutationTarget {
        try XCTUnwrap(WatchlistMutationTarget(
            aliasID: MediaAliasID(UUID()),
            kind: kind,
            externalIDs: ids.compactMap {
                WatchlistExternalID(namespace: $0.0, value: $0.1)
            },
            validatedBindings: []
        ))
    }

    // MARK: - What it declines

    func testTitleWithNoMALIdentityDoesNotResolve() async throws {
        let destination = makeDestination(http: RecordingHTTPClient())
        let dune = try target(kind: .series, [(.imdb, "tt1160419")])

        let resolved = try await destination.resolve(dune)
        XCTAssertNil(resolved)
    }

    /// An AniList id resolves, because `AnimeIDMapper` can translate it — the
    /// same keyless, cached lookup the scrobbler uses. The guard against putting
    /// the wrong show on someone's list lives at WRITE time instead: a title the
    /// mapper cannot translate fails permanently rather than being guessed at.
    func testAniListIdentityResolvesViaTranslation() async throws {
        let destination = makeDestination(http: RecordingHTTPClient())
        let frieren = try target(kind: .series, [(.aniList, "154587")])

        let resolved = try await destination.resolve(frieren)
        XCTAssertEqual(resolved?.opaqueValue, "series|aniList|154587")
    }

    func testSeriesWithAMALIdentityResolves() async throws {
        let destination = makeDestination(http: RecordingHTTPClient())
        let frieren = try target(kind: .series, [(.tvdb, "424536"), (.myAnimeList, "52991")])

        let binding = try await destination.resolve(frieren)

        XCTAssertEqual(binding?.opaqueValue, "series|myAnimeList|52991")
    }

    // MARK: - Writing

    func testAddingSetsPlanToWatch() async throws {
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/my_list_status", json: "{}")
        let destination = makeDestination(http: http)
        let binding = try XCTUnwrap(WatchlistDestinationBinding(
            destinationID: WatchlistDestinationID(rawValue: "myanimelist")!,
            opaqueValue: "series|myAnimeList|52991"
        ))

        try await destination.apply(.present, to: binding)

        let sent = try XCTUnwrap(http.sent.last)
        XCTAssertTrue(sent.path.hasSuffix("/anime/52991/my_list_status"))
        let body = String(data: sent.body ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("plan_to_watch"), "body was: \(body)")
    }

    /// MAL answers 404 when there was no entry to delete. For a removal that
    /// means the desired state already holds, so it must not be reported as a
    /// failure and retried forever.
    func testRemovingSomethingNotOnTheListSucceeds() async throws {
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/my_list_status", json: "{}", status: 404)
        let destination = makeDestination(http: http)
        let binding = try XCTUnwrap(WatchlistDestinationBinding(
            destinationID: WatchlistDestinationID(rawValue: "myanimelist")!,
            opaqueValue: "series|myAnimeList|52991"
        ))

        try await destination.apply(.absent, to: binding)
    }

    // MARK: - Reading

    func testReadsPlanToWatchEntries() async throws {
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/users/@me/animelist", json: """
        {"data":[{"node":{"id":52991,"title":"Sousou no Frieren",
          "start_season":{"year":2023,"season":"fall"}}}]}
        """)

        let entries = try await makeDestination(http: http).fetchEntries()

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].kind, .series)
        XCTAssertEqual(entries[0].presentation?.title, "Sousou no Frieren")
        XCTAssertEqual(entries[0].presentation?.year, 2023)
        XCTAssertEqual(entries[0].externalIDs.first?.namespace, .myAnimeList)
    }

    func testDisconnectedAccountAsksForSignInRatherThanRetrying() async {
        let destination = makeDestination(http: RecordingHTTPClient(), tokens: nil)

        do {
            _ = try await destination.fetchEntries()
            XCTFail("expected an authentication failure")
        } catch let error as WatchlistDestinationError {
            XCTAssertEqual(error, .authenticationRequired)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    /// The case that actually matters for real libraries: Jellyfin and Plex anime
    /// (Shoko especially) tag only AniDB, so a destination that accepted just its
    /// own catalogue's ids would decline nearly every anime the viewer owns while
    /// looking like it worked. Resolving is what makes the title eligible at all;
    /// the translation itself happens at write time via `AnimeIDMapper`.
    func testAniDBOnlyAnimeStillResolves() async throws {
        let destination = makeDestination(http: RecordingHTTPClient())
        let mushoku = try target(kind: .series, [(.tmdb, "94664"), (.aniDB, "14758")])

        let binding = try await destination.resolve(mushoku)

        XCTAssertNotNil(
            binding,
            "an AniDB-tagged anime must not be silently skipped"
        )
        XCTAssertTrue(binding?.opaqueValue.contains("14758") == true)
    }

}
