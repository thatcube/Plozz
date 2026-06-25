import XCTest
import CoreModels
import CoreNetworking
@testable import TraktService

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
