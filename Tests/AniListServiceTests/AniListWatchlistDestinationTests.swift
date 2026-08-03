import CoreModels
import CoreNetworking
import Foundation
import XCTest
@testable import AniListService

/// AniList's half of the universal watchlist. The behaviour that matters most
/// here is what it DECLINES: this destination must be silent about everything
/// that isn't anime, without anywhere in the app classifying titles.
final class AniListWatchlistDestinationTests: XCTestCase {
    private func makeDestination(
        http: RecordingHTTPClient,
        tokens: AniListTokens? = AniListTokens(accessToken: "acc")
    ) -> AniListWatchlistDestination {
        AniListWatchlistDestination(
            config: AniListConfig(clientID: "id", clientSecret: "secret"),
            http: http,
            tokenStore: InMemoryAniListTokenStore(tokens: tokens)
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

    /// The anime-only rule, expressed where it belongs: a title with no anime
    /// identity simply does not resolve, so the reconciler never asks AniList
    /// about it. Watchlisting Dune must not reach this service at all.
    func testTitleWithNoAnimeIdentityDoesNotResolve() async throws {
        let destination = makeDestination(http: RecordingHTTPClient())
        let dune = try target(kind: .series, [(.imdb, "tt1160419"), (.tmdb, "438631")])

        let binding = try await destination.resolve(dune)

        XCTAssertNil(binding)
    }

    /// An anime FILM is declined too: AniList catalogues films as their own
    /// works, and a movie in the viewer's library carrying an AniList id is far
    /// more likely to be a bad match than a real one.
    func testMovieDoesNotResolveEvenWithAnAnimeIdentity() async throws {
        let destination = makeDestination(http: RecordingHTTPClient())
        let film = try target(kind: .movie, [(.aniList, "21519")])

        let resolved = try await destination.resolve(film)
        XCTAssertNil(resolved)
    }

    func testSeriesWithAnAniListIdentityResolves() async throws {
        let destination = makeDestination(http: RecordingHTTPClient())
        let frieren = try target(kind: .series, [(.tvdb, "424536"), (.aniList, "154587")])

        let binding = try await destination.resolve(frieren)

        XCTAssertEqual(binding?.opaqueValue, "series|aniList|154587")
    }

    // MARK: - Writing

    func testAddingSetsPlanningStatus() async throws {
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "", json: """
        {"data":{"SaveMediaListEntry":{"id":1,"status":"PLANNING","progress":0}}}
        """)
        let destination = makeDestination(http: http)
        let binding = try XCTUnwrap(WatchlistDestinationBinding(
            destinationID: WatchlistDestinationID(rawValue: "anilist")!,
            opaqueValue: "series|aniList|154587"
        ))

        try await destination.apply(.present, to: binding)

        let sent = try XCTUnwrap(http.sent.last)
        let query = try XCTUnwrap(sent.json?["query"] as? String)
        XCTAssertTrue(query.contains("SaveMediaListEntry"))
        let variables = try XCTUnwrap(sent.json?["variables"] as? [String: Any])
        XCTAssertEqual(variables["mediaId"] as? Int, 154587)
        XCTAssertEqual(variables["status"] as? String, "PLANNING")
    }

    /// A MAL id is translated through AniList's own index rather than assumed to
    /// be an AniList id — the two catalogues number their works differently, and
    /// guessing would file the wrong show.
    func testMALIdentityIsTranslatedBeforeWriting() async throws {
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "", json: """
        {"data":{"Media":{"id":154587}}}
        """)
        http.stub(pathSuffix: "", json: """
        {"data":{"SaveMediaListEntry":{"id":1,"status":"PLANNING","progress":0}}}
        """)
        let destination = makeDestination(http: http)
        let binding = try XCTUnwrap(WatchlistDestinationBinding(
            destinationID: WatchlistDestinationID(rawValue: "anilist")!,
            opaqueValue: "series|myAnimeList|52991"
        ))

        try await destination.apply(.present, to: binding)

        XCTAssertEqual(http.sent.count, 2, "a lookup, then the write")
        let lookup = try XCTUnwrap(http.sent.first?.json?["variables"] as? [String: Any])
        XCTAssertEqual(lookup["malId"] as? Int, 52991)
        let write = try XCTUnwrap(http.sent.last?.json?["variables"] as? [String: Any])
        XCTAssertEqual(write["mediaId"] as? Int, 154587)
    }

    // MARK: - Reading

    func testReadsPlanningEntriesWithBothIdentities() async throws {
        let http = RecordingHTTPClient()
        // The viewer lookup comes first: AniList reads a list BY user id.
        http.stub(pathSuffix: "", json: """
        {"data":{"Viewer":{"id":7,"name":"someone"}}}
        """)
        http.stub(pathSuffix: "", json: """
        {"data":{"MediaListCollection":{"lists":[{"entries":[
          {"media":{"id":154587,"idMal":52991,"seasonYear":2023,
           "title":{"romaji":"Sousou no Frieren","english":"Frieren"}}}
        ]}]}}}
        """)

        let entries = try await makeDestination(http: http).fetchEntries()

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].kind, .series)
        XCTAssertEqual(entries[0].presentation?.title, "Frieren")
        XCTAssertEqual(entries[0].presentation?.year, 2023)
        XCTAssertTrue(entries[0].externalIDs.contains {
            $0.namespace == .aniList && $0.value == "154587"
        })
        XCTAssertTrue(entries[0].externalIDs.contains {
            $0.namespace == .myAnimeList && $0.value == "52991"
        })
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
