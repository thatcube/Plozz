import XCTest
import CoreModels
import CoreNetworking
@testable import TraktService
@testable import TestSupportNetworking

private let traktBaseURL = URL(string: "https://api.trakt.tv")!

private func configured() -> TraktConfig {
    TraktConfig(clientID: "CLIENT", clientSecret: "SECRET")
}

private func tokenJSON(access: String = "acc", refresh: String = "ref", expiresIn: Double = 7_776_000, createdAt: Double = Date().timeIntervalSince1970) -> String {
    """
    {"access_token":"\(access)","refresh_token":"\(refresh)","expires_in":\(Int(expiresIn)),"created_at":\(Int(createdAt))}
    """
}

private func movie(imdb: String? = "tt0111161", tmdb: String? = nil) -> MediaItem {
    var ids: [String: String] = [:]
    if let imdb { ids["Imdb"] = imdb }
    if let tmdb { ids["Tmdb"] = tmdb }
    return MediaItem(id: "m1", title: "The Shawshank Redemption", kind: .movie, productionYear: 1994, runtime: 8520, providerIDs: ids)
}

private func episode(tvdb: String? = "12345") -> MediaItem {
    var ids: [String: String] = [:]
    if let tvdb { ids["Tvdb"] = tvdb }
    return MediaItem(id: "e1", title: "Pilot", kind: .episode, parentTitle: "Show", seasonNumber: 1, episodeNumber: 3, runtime: 2400, providerIDs: ids)
}

// MARK: - Config

final class TraktConfigTests: XCTestCase {
    func testIsConfiguredRequiresBothCredentials() {
        XCTAssertTrue(TraktConfig(clientID: "a", clientSecret: "b").isConfigured)
        XCTAssertFalse(TraktConfig(clientID: "a", clientSecret: nil).isConfigured)
        XCTAssertFalse(TraktConfig(clientID: "", clientSecret: "b").isConfigured)
    }

    func testSanitizeRejectsPlaceholderAndEmpty() {
        XCTAssertNil(TraktConfig(clientID: "$(TRAKT_CLIENT_ID)", clientSecret: "x").clientID)
        XCTAssertNil(TraktConfig(clientID: "   ", clientSecret: "x").clientID)
        XCTAssertEqual(TraktConfig(clientID: " abc ", clientSecret: "x").clientID, "abc")
    }
}

// MARK: - Mapping

final class TraktScrobblerMappingTests: XCTestCase {
    func testEventMapping() {
        XCTAssertEqual(TraktScrobbler.action(for: .start), "start")
        XCTAssertEqual(TraktScrobbler.action(for: .unpause), "start")
        XCTAssertEqual(TraktScrobbler.action(for: .pause), "pause")
        XCTAssertEqual(TraktScrobbler.action(for: .stop), "stop")
        XCTAssertNil(TraktScrobbler.action(for: .progress), "Periodic progress must not scrobble")
    }

    func testIDParsingTolerantOfCasingAndTypes() {
        let ids = TraktScrobbler.traktIDs(from: ["Imdb": "tt42", "Tmdb": "278", "Tvdb": "99", "Trakt": "7"])
        XCTAssertEqual(ids.imdb, "tt42")
        XCTAssertEqual(ids.tmdb, 278)
        XCTAssertEqual(ids.tvdb, 99)
        XCTAssertEqual(ids.trakt, 7)
    }

    func testInvalidIMDbAndNonNumericRejected() {
        let ids = TraktScrobbler.traktIDs(from: ["Imdb": "278", "Tmdb": "abc"])
        XCTAssertNil(ids.imdb, "IMDb ids must start with tt")
        XCTAssertNil(ids.tmdb)
        XCTAssertTrue(ids.isEmpty)
    }

    func testMovieBodyClampsProgress() {
        let body = TraktScrobbler.scrobbleBody(for: movie(), progress: 150)
        XCTAssertEqual(body?.progress, 100)
        XCTAssertEqual(body?.movie?.ids.imdb, "tt0111161")
        XCTAssertEqual(body?.movie?.year, 1994)
        XCTAssertNil(body?.episode)
    }

    func testEpisodeBodyCarriesSeasonAndNumber() {
        let body = TraktScrobbler.scrobbleBody(for: episode(), progress: 50)
        XCTAssertEqual(body?.episode?.season, 1)
        XCTAssertEqual(body?.episode?.number, 3)
        XCTAssertEqual(body?.episode?.ids.tvdb, 12345)
        XCTAssertNil(body?.movie)
    }

    func testEpisodeWithSeriesIDsUsesShowPlusSeasonAndNumber() {
        let item = MediaItem(
            id: "avatar-s2e5",
            title: "Ten Thousand Things",
            kind: .episode,
            parentTitle: "Avatar: The Last Airbender",
            seasonNumber: 2,
            episodeNumber: 5,
            productionYear: 2024,
            providerIDs: [
                // Plex supplied these show-level values in the plain namespace too.
                "Imdb": "tt9018736",
                "Tmdb": "82452",
                "Tvdb": "385925",
                "SeriesImdb": "tt9018736",
                "SeriesTmdb": "82452",
                "SeriesTvdb": "385925"
            ]
        )

        let body = TraktScrobbler.scrobbleBody(for: item, progress: 10)

        XCTAssertEqual(body?.show?.ids.imdb, "tt9018736")
        XCTAssertEqual(body?.show?.ids.tmdb, 82452)
        XCTAssertEqual(body?.show?.ids.tvdb, 385925)
        XCTAssertEqual(body?.episode?.season, 2)
        XCTAssertEqual(body?.episode?.number, 5)
        XCTAssertTrue(
            body?.episode?.ids.isEmpty == true,
            "Show-level IDs must never be sent in Trakt's episode ID field"
        )
    }

    func testNoBodyWithoutUsableIDs() {
        XCTAssertNil(TraktScrobbler.scrobbleBody(for: movie(imdb: nil), progress: 50))
        XCTAssertNil(TraktScrobbler.scrobbleBody(for: episode(tvdb: nil), progress: 50))
    }

    func testSeriesIsNotScrobbled() {
        let series = MediaItem(id: "s1", title: "Show", kind: .series, providerIDs: ["Imdb": "tt9"])
        XCTAssertNil(TraktScrobbler.scrobbleBody(for: series, progress: 90))
    }
}

// MARK: - Scrobbler (network)

final class TraktScrobblerNetworkTests: XCTestCase {
    private func makeScrobbler(http: RecordingHTTPClient, tokens: TraktTokens?) -> TraktScrobbler {
        let store = InMemoryTraktTokenStore(tokens: tokens)
        return TraktScrobbler(config: configured(), http: http, tokenStore: store)
    }

    private func validTokens() -> TraktTokens {
        TraktTokens(accessToken: "acc", refreshToken: "ref", expiresAt: .distantFuture)
    }

    func testScrobbleStartPostsMoviePayloadWithBearer() async {
        let http = RecordingHTTPClient()
        http.stubEmpty(pathSuffix: "/scrobble/start")
        let scrobbler = makeScrobbler(http: http, tokens: validTokens())

        await scrobbler.scrobble(item: movie(), progress: 80, event: .start)

        XCTAssertEqual(http.sent.count, 1)
        let req = http.sent[0]
        XCTAssertEqual(req.path, "/scrobble/start")
        XCTAssertEqual(req.headers["Authorization"], "Bearer acc")
        XCTAssertEqual(req.headers["trakt-api-key"], "CLIENT")
        let movieIDs = (req.json?["movie"] as? [String: Any])?["ids"] as? [String: Any]
        XCTAssertEqual(movieIDs?["imdb"] as? String, "tt0111161")
        XCTAssertEqual(req.json?["progress"] as? Double, 80)
    }

    func testNotConnectedIsNoOp() async {
        let http = RecordingHTTPClient()
        http.stubEmpty(pathSuffix: "/scrobble/start")
        let scrobbler = makeScrobbler(http: http, tokens: nil)

        await scrobbler.scrobble(item: movie(), progress: 80, event: .start)

        XCTAssertTrue(http.sentPaths.isEmpty, "No token → must not hit the network")
    }

    func testProgressEventIsNotScrobbled() async {
        let http = RecordingHTTPClient()
        http.stubEmpty(pathSuffix: "/scrobble/start")
        let scrobbler = makeScrobbler(http: http, tokens: validTokens())

        await scrobbler.scrobble(item: movie(), progress: 40, event: .progress)

        XCTAssertTrue(http.sentPaths.isEmpty)
    }

    func testExpiredTokenIsRefreshedBeforeScrobble() async {
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/oauth/token", json: tokenJSON(access: "acc2", refresh: "ref2"))
        http.stubEmpty(pathSuffix: "/scrobble/stop")
        let store = InMemoryTraktTokenStore(tokens: TraktTokens(accessToken: "old", refreshToken: "ref", expiresAt: .distantPast))
        let scrobbler = TraktScrobbler(config: configured(), http: http, tokenStore: store)

        await scrobbler.scrobble(item: movie(), progress: 95, event: .stop)

        XCTAssertEqual(http.sentPaths, ["/oauth/token", "/scrobble/stop"])
        XCTAssertEqual(http.sent.last?.headers["Authorization"], "Bearer acc2")
        XCTAssertEqual(store.load()?.accessToken, "acc2", "Refreshed token must be persisted")
    }
}

// MARK: - 409 = success

/// A Trakt `/scrobble` 409 means "already scrobbled within the cooldown" — a
/// duplicate, which is exactly the convergent outcome we want. It must be treated
/// as confirmed success: no thrown error from the durable path, no retry, and the
/// non-throwing path must stay silent too.
final class TraktScrobble409SuccessTests: XCTestCase {
    private func validTokens() -> TraktTokens {
        TraktTokens(accessToken: "acc", refreshToken: "ref", expiresAt: .distantFuture)
    }

    func testDurableScrobbleResultTreats409AsSuccess() async throws {
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/scrobble/stop", json: "{}", status: 409)
        let store = InMemoryTraktTokenStore(tokens: validTokens())
        let scrobbler = TraktScrobbler(config: configured(), http: http, tokenStore: store)

        // Must NOT throw — 409 is success.
        try await scrobbler.scrobbleResult(item: movie(), progress: 100, event: .stop)

        XCTAssertEqual(http.sentPaths, ["/scrobble/stop"], "One scrobble attempt, no retry")
    }

    func testNonThrowingScrobbleSwallows409() async {
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/scrobble/stop", json: "{}", status: 409)
        let store = InMemoryTraktTokenStore(tokens: validTokens())
        let scrobbler = TraktScrobbler(config: configured(), http: http, tokenStore: store)

        await scrobbler.scrobble(item: movie(), progress: 100, event: .stop)

        XCTAssertEqual(http.sentPaths, ["/scrobble/stop"])
    }

    func testGenuineFailureStillThrowsFromDurablePath() async {
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/scrobble/stop", json: "{}", status: 500)
        let store = InMemoryTraktTokenStore(tokens: validTokens())
        let scrobbler = TraktScrobbler(config: configured(), http: http, tokenStore: store)

        do {
            try await scrobbler.scrobbleResult(item: movie(), progress: 100, event: .stop)
            XCTFail("A 500 must surface so the outbox retries")
        } catch {
            // expected — a real failure is retryable.
        }
    }
}

// MARK: - Watchlist

final class TraktWatchlistDestinationTests: XCTestCase {
    private func makeDestination(
        http: RecordingHTTPClient,
        tokens: TraktTokens = TraktTokens(
            accessToken: "acc",
            refreshToken: "ref",
            expiresAt: .distantFuture
        )
    ) -> TraktWatchlistDestination {
        TraktWatchlistDestination(
            config: configured(),
            http: http,
            tokenStore: InMemoryTraktTokenStore(tokens: tokens)
        )
    }

    func testListDecodesMoviesAndShowsWithTypedIDs() async throws {
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/sync/watchlist/movies", json: """
        [{"movie":{"title":"Dune","year":2021,"ids":{"trakt":1,"imdb":"tt1160419","tmdb":438631}}}]
        """)
        http.stub(pathSuffix: "/sync/watchlist/shows", json: """
        [{"show":{"title":"Severance","year":2022,"ids":{"trakt":2,"tvdb":371980}}}]
        """)

        let entries = try await makeDestination(http: http).fetchEntries()

        XCTAssertEqual(entries.map(\.kind), [.movie, .series])
        XCTAssertTrue(entries[0].externalIDs.contains {
            $0.namespace == .imdb && $0.value == "tt1160419"
        })
        XCTAssertEqual(
            http.sentPaths,
            ["/sync/watchlist/movies", "/sync/watchlist/shows"]
        )
    }

    func testListReadsEveryTraktPaginationPage() async throws {
        let http = RecordingHTTPClient()
        http.stub(
            pathSuffix: "/sync/watchlist/movies",
            json: """
            [{"movie":{"title":"First","ids":{"trakt":1}}}]
            """,
            headers: ["X-Pagination-Page-Count": "2"]
        )
        http.stub(
            pathSuffix: "/sync/watchlist/movies",
            json: """
            [{"movie":{"title":"Second","ids":{"trakt":2}}}]
            """,
            headers: ["X-Pagination-Page-Count": "2"]
        )
        http.stub(
            pathSuffix: "/sync/watchlist/shows",
            json: "[]",
            headers: ["X-Pagination-Page-Count": "1"]
        )

        let entries = try await makeDestination(http: http).fetchEntries()

        XCTAssertEqual(entries.map { $0.presentation?.title }, ["First", "Second"])
        let movieRequests = http.sent.filter {
            $0.path.hasSuffix("/sync/watchlist/movies")
        }
        XCTAssertEqual(
            movieRequests.compactMap {
                $0.queryItems.first { $0.name == "page" }?.value
            },
            ["1", "2"]
        )
    }

    func testListRejectsChangingTraktPaginationMetadata() async throws {
        let http = RecordingHTTPClient()
        http.stub(
            pathSuffix: "/sync/watchlist/movies",
            json: """
            [{"movie":{"title":"First","ids":{"trakt":1}}}]
            """,
            headers: [
                "X-Pagination-Page-Count": "2",
                "X-Pagination-Item-Count": "2",
            ]
        )
        http.stub(
            pathSuffix: "/sync/watchlist/movies",
            json: """
            [{"movie":{"title":"Second","ids":{"trakt":2}}}]
            """,
            headers: [
                "X-Pagination-Page-Count": "1",
                "X-Pagination-Item-Count": "2",
            ]
        )

        do {
            _ = try await makeDestination(http: http).fetchEntries()
            XCTFail("Expected inconsistent pagination to fail closed")
        } catch let error as WatchlistDestinationError {
            XCTAssertEqual(error, .transient)
        }
    }

    func testAddAndRemoveUseTypedMovieAndShowPayloads() async throws {
        let http = RecordingHTTPClient()
        http.stubEmpty(pathSuffix: "/sync/watchlist")
        http.stubEmpty(pathSuffix: "/sync/watchlist/remove")
        let destination = makeDestination(http: http)
        let movie = WatchlistMutationTarget(
            aliasID: MediaAliasID(),
            kind: .movie,
            externalIDs: [
                WatchlistExternalID(namespace: .imdb, value: "tt1")!
            ]
        )!
        let show = WatchlistMutationTarget(
            aliasID: MediaAliasID(),
            kind: .series,
            externalIDs: [
                WatchlistExternalID(namespace: .tvdb, value: "42")!
            ]
        )!

        let movieResolution = try await destination.resolve(movie)
        let showResolution = try await destination.resolve(show)
        try await destination.apply(
            .present,
            to: try XCTUnwrap(movieResolution)
        )
        try await destination.apply(
            .absent,
            to: try XCTUnwrap(showResolution)
        )

        let add = try XCTUnwrap(http.sent.first?.json)
        let addMovie = try XCTUnwrap((add["movies"] as? [[String: Any]])?.first)
        XCTAssertEqual(
            (addMovie["ids"] as? [String: Any])?["imdb"] as? String,
            "tt1"
        )
        let remove = try XCTUnwrap(http.sent.last?.json)
        let removeShow = try XCTUnwrap(
            (remove["shows"] as? [[String: Any]])?.first
        )
        XCTAssertEqual(
            (removeShow["ids"] as? [String: Any])?["tvdb"] as? Int,
            42
        )
        XCTAssertEqual(
            http.sentPaths,
            ["/sync/watchlist", "/sync/watchlist/remove"]
        )
    }

    func testScopedWriteRejectsAnotherAccountsMutation() async throws {
        let http = RecordingHTTPClient()
        let destination = makeDestination(http: http)
        let target = WatchlistMutationTarget(
            aliasID: MediaAliasID(),
            kind: .movie,
            externalIDs: [
                WatchlistExternalID(namespace: .imdb, value: "tt1")!
            ]
        )!
        let resolved = try await destination.resolve(target)
        let binding = try XCTUnwrap(resolved)

        do {
            try await destination.apply(
                .present,
                to: binding,
                expectedReconciliationScope: "trakt#another-account"
            )
            XCTFail("Expected the stale account mutation to be rejected")
        } catch let error as WatchlistDestinationError {
            XCTAssertEqual(error, .authenticationRequired)
        }
        XCTAssertTrue(http.sent.isEmpty)
    }

    func testRateLimitCarriesRetryAfterAndConflictIsIdempotentSuccess() async throws {
        let http = RecordingHTTPClient()
        http.stub(
            pathSuffix: "/sync/watchlist",
            json: "{}",
            status: 429,
            headers: ["Retry-After": "17"]
        )
        let destination = makeDestination(http: http)
        let target = WatchlistMutationTarget(
            aliasID: MediaAliasID(),
            kind: .movie,
            externalIDs: [
                WatchlistExternalID(namespace: .tmdb, value: "10")!
            ]
        )!
        let resolution = try await destination.resolve(target)
        let binding = try XCTUnwrap(resolution)
        do {
            try await destination.apply(.present, to: binding)
            XCTFail("Expected rate limit")
        } catch let error as WatchlistDestinationError {
            XCTAssertEqual(error, .rateLimited(retryAfter: 17))
        }

        let idempotentHTTP = RecordingHTTPClient()
        idempotentHTTP.stub(
            pathSuffix: "/sync/watchlist",
            json: "{}",
            status: 409
        )
        let idempotent = makeDestination(http: idempotentHTTP)
        let idempotentResolution = try await idempotent.resolve(target)
        let idempotentBinding = try XCTUnwrap(idempotentResolution)
        try await idempotent.apply(.present, to: idempotentBinding)
        XCTAssertEqual(idempotentHTTP.sentPaths.count, 1)
    }

    func testExpiredTokenRefreshesBeforeList() async throws {
        let http = RecordingHTTPClient()
        http.stub(
            pathSuffix: "/oauth/token",
            json: tokenJSON(access: "new", refresh: "new-ref")
        )
        http.stub(pathSuffix: "/sync/watchlist/movies", json: "[]")
        http.stub(pathSuffix: "/sync/watchlist/shows", json: "[]")
        let destination = makeDestination(
            http: http,
            tokens: TraktTokens(
                accessToken: "old",
                refreshToken: "ref",
                expiresAt: .distantPast
            )
        )

        _ = try await destination.fetchEntries()

        XCTAssertEqual(
            http.sentPaths,
            [
                "/oauth/token",
                "/sync/watchlist/movies",
                "/sync/watchlist/shows"
            ]
        )
    }
}

// MARK: - Auth (device code poll)

final class TraktAuthServiceTests: XCTestCase {
    func testAwaitTokenPollsUntilApproved() async throws {
        let http = RecordingHTTPClient()
        // Pending twice (HTTP 400), then approved.
        http.stub(pathSuffix: "/oauth/device/token", json: "{}", status: 400)
        http.stub(pathSuffix: "/oauth/device/token", json: "{}", status: 400)
        http.stub(pathSuffix: "/oauth/device/token", json: tokenJSON(access: "live"))

        let auth = TraktAuthService(config: configured(), http: http, sleep: { _ in })
        let code = TraktDeviceCode(deviceCode: "dev", userCode: "ABCD", verificationURL: "https://trakt.tv/activate", expiresIn: 600, interval: 1)

        let tokens = try await auth.awaitToken(for: code)

        XCTAssertEqual(tokens.accessToken, "live")
        XCTAssertEqual(http.sentPaths.filter { $0 == "/oauth/device/token" }.count, 3)
    }

    func testAwaitTokenThrowsWhenExpired() async {
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/oauth/device/token", json: "{}", status: 400)
        let auth = TraktAuthService(config: configured(), http: http, sleep: { _ in })
        // expiresIn 0 → deadline already passed, loop body never succeeds.
        let code = TraktDeviceCode(deviceCode: "dev", userCode: "ABCD", verificationURL: "https://trakt.tv/activate", expiresIn: 0, interval: 1)

        do {
            _ = try await auth.awaitToken(for: code)
            XCTFail("Expected expiry")
        } catch let error as AppError {
            XCTAssertEqual(error, .quickConnectExpired)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testBeginDeviceCodeDecodes() async throws {
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/oauth/device/code", json: """
        {"device_code":"dc","user_code":"WXYZ","verification_url":"https://trakt.tv/activate","expires_in":600,"interval":5}
        """)
        let auth = TraktAuthService(config: configured(), http: http, sleep: { _ in })

        let code = try await auth.beginDeviceCode()

        XCTAssertEqual(code.userCode, "WXYZ")
        XCTAssertEqual(code.verificationURL, "https://trakt.tv/activate")
        XCTAssertEqual(code.interval, 5)
    }
}
