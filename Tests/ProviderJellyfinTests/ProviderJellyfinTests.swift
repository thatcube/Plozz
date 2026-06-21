import XCTest
import CoreModels
import CoreNetworking
@testable import ProviderJellyfin

final class JellyfinDeviceProfileTests: XCTestCase {
    func testAuthorizationHeaderFormat() {
        let profile = JellyfinDeviceProfile(client: "Plozz", device: "Apple TV", deviceID: "DID", version: "1.0")
        let header = profile.authorizationHeaderValue()
        XCTAssertTrue(header.hasPrefix("MediaBrowser "))
        XCTAssertTrue(header.contains(#"Client="Plozz""#))
        XCTAssertTrue(header.contains(#"DeviceId="DID""#))
        XCTAssertFalse(header.contains("Token="))
    }

    func testAuthorizationHeaderIncludesToken() {
        let profile = JellyfinDeviceProfile(deviceID: "DID")
        let header = profile.authorizationHeaderValue(token: "abc")
        XCTAssertTrue(header.contains(#"Token="abc""#))
    }
}

final class JellyfinTicksTests: XCTestCase {
    func testSecondsFromTicks() {
        XCTAssertEqual(JellyfinTicks.seconds(fromTicks: 10_000_000), 1.0)
        XCTAssertNil(JellyfinTicks.seconds(fromTicks: nil))
    }

    func testTicksFromSeconds() {
        XCTAssertEqual(JellyfinTicks.ticks(fromSeconds: 2.0), 20_000_000)
    }
}

final class JellyfinProviderMappingTests: XCTestCase {
    private func makeSession() -> UserSession {
        UserSession(
            server: MediaServer(id: "s", name: "Home", baseURL: URL(string: "http://host:8096")!, provider: .jellyfin),
            userID: "u1", userName: "Alice", deviceID: "d1", accessToken: "TOKEN"
        )
    }

    func testContinueWatchingMapsResumeFields() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Users/u1/Items/Resume", json: """
        {"Items":[{"Id":"i1","Name":"Movie","Type":"Movie","RunTimeTicks":36000000000,
        "UserData":{"PlaybackPositionTicks":18000000000,"PlayedPercentage":50.0,"Played":false}}],
        "TotalRecordCount":1}
        """)
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        let items = try await provider.continueWatching(limit: 10)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].title, "Movie")
        XCTAssertEqual(items[0].kind, .movie)
        XCTAssertEqual(items[0].runtime, 3600)
        XCTAssertEqual(items[0].resumePosition, 1800)
        XCTAssertEqual(items[0].playedPercentage ?? 0, 0.5, accuracy: 0.001)
    }

    func testLibrariesMapCollectionType() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Users/u1/Views", json: """
        {"Items":[{"Id":"lib1","Name":"Movies","CollectionType":"movies"},
        {"Id":"lib2","Name":"Shows","CollectionType":"tvshows"}]}
        """)
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        let libs = try await provider.libraries()
        XCTAssertEqual(libs.map(\.title), ["Movies", "Shows"])
        XCTAssertEqual(libs[0].kind, .movie)
        XCTAssertEqual(libs[1].kind, .series)
    }

    func testImageURLBuildsExpectedPath() {
        let provider = JellyfinProvider(session: makeSession(), http: StubHTTPClient())
        let url = provider.imageURL(itemID: "i1", kind: .primary, maxWidth: 400)
        XCTAssertEqual(url?.absoluteString, "http://host:8096/Items/i1/Images/Primary?maxWidth=400")
    }

    func testItemsPageMapsItemsAndTotalCount() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Users/u1/Items", json: """
        {"Items":[
          {"Id":"m1","Name":"Alien","Type":"Movie"},
          {"Id":"m2","Name":"Aliens","Type":"Movie"}
        ],"TotalRecordCount":250}
        """)
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        let page = try await provider.items(in: "lib1", page: PageRequest(startIndex: 60, limit: 60))

        XCTAssertEqual(page.items.map(\.title), ["Alien", "Aliens"])
        XCTAssertEqual(page.items.first?.kind, .movie)
        XCTAssertEqual(page.startIndex, 60)
        XCTAssertEqual(page.totalCount, 250)
        XCTAssertTrue(page.hasMore)

        let query = try XCTUnwrap(stub.queryItems(forPathSuffix: "/Users/u1/Items"))
        XCTAssertEqual(query.first(where: { $0.name == "ParentId" })?.value, "lib1")
        XCTAssertEqual(query.first(where: { $0.name == "StartIndex" })?.value, "60")
        XCTAssertEqual(query.first(where: { $0.name == "Limit" })?.value, "60")
        XCTAssertEqual(query.first(where: { $0.name == "SortBy" })?.value, "SortName")
    }

    func testItemsPageDefaultsTotalCountToItemCountWhenMissing() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Users/u1/Items", json: """
        {"Items":[{"Id":"m1","Name":"Solo","Type":"Movie"}]}
        """)
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        let page = try await provider.items(in: "lib1", page: PageRequest(startIndex: 0, limit: 60))
        XCTAssertEqual(page.totalCount, 1)
        XCTAssertFalse(page.hasMore)
    }

    func testPlaybackInfoResolvesDirectStreamWithApiKey() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Users/u1/Items/i1", json: """
        {"Id":"i1","Name":"Movie","Type":"Movie","RunTimeTicks":0,
        "UserData":{"PlaybackPositionTicks":0}}
        """)
        stub.stub(pathSuffix: "/Items/i1/PlaybackInfo", json: """
        {"MediaSources":[{"Id":"src1","ETag":"etag9","Container":"mp4","SupportsDirectPlay":true,
        "MediaStreams":[{"Index":1,"Type":"Audio","Language":"eng","DisplayTitle":"English"},
        {"Index":2,"Type":"Subtitle","Language":"eng","DisplayTitle":"English (SRT)"}]}],
        "PlaySessionId":"ps1"}
        """)
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        let request = try await provider.playbackInfo(for: "i1")
        XCTAssertEqual(request.playSessionID, "ps1")
        XCTAssertEqual(request.audioTracks.count, 1)
        XCTAssertEqual(request.subtitleTracks.count, 1)
        let url = request.streamURL.absoluteString
        XCTAssertTrue(url.contains("/Videos/i1/stream.mp4"))
        XCTAssertTrue(url.contains("api_key=TOKEN"))
        XCTAssertTrue(url.contains("mediaSourceId=src1"))
        XCTAssertTrue(url.contains("playSessionId=ps1"))
        XCTAssertTrue(url.contains("tag=etag9"))
    }

    func testPlaybackInfoPrefersTranscodingHLSURL() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Users/u1/Items/i1", json: """
        {"Id":"i1","Name":"Movie","Type":"Movie","RunTimeTicks":0}
        """)
        // MKV that the server decided to remux: it returns a relative HLS URL.
        stub.stub(pathSuffix: "/Items/i1/PlaybackInfo", json: """
        {"MediaSources":[{"Id":"src1","Container":"mkv","SupportsDirectPlay":false,
        "SupportsTranscoding":true,"TranscodingSubProtocol":"hls",
        "TranscodingUrl":"/videos/i1/master.m3u8?api_key=TOKEN&PlaySessionId=ps1"}],
        "PlaySessionId":"ps1"}
        """)
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        let request = try await provider.playbackInfo(for: "i1")
        let url = request.streamURL.absoluteString
        XCTAssertTrue(url.contains("/videos/i1/master.m3u8"), url)
        XCTAssertTrue(url.hasPrefix("http://host:8096"), url)
        XCTAssertFalse(url.contains("static=true"))
    }

    func testStopReleasesActiveEncoding() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Sessions/Playing/Stopped", json: "{}")
        stub.stub(pathSuffix: "/Videos/ActiveEncodings", json: "")
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        try await provider.reportPlayback(
            PlaybackProgress(itemID: "i1", playSessionID: "ps1", positionSeconds: 120, isPaused: true),
            event: .stop
        )

        XCTAssertTrue(stub.sentPaths.contains { $0.hasSuffix("/Sessions/Playing/Stopped") })
        XCTAssertTrue(stub.sentPaths.contains { $0.hasSuffix("/Videos/ActiveEncodings") })
    }

    func testProgressDoesNotReleaseActiveEncoding() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Sessions/Playing/Progress", json: "{}")
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        try await provider.reportPlayback(
            PlaybackProgress(itemID: "i1", playSessionID: "ps1", positionSeconds: 30, isPaused: false),
            event: .progress
        )

        XCTAssertFalse(stub.sentPaths.contains { $0.hasSuffix("/Videos/ActiveEncodings") })
    }

    func testPlaybackInfoSendsDeviceProfile() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Users/u1/Items/i1", json: """
        {"Id":"i1","Name":"Movie","Type":"Movie","RunTimeTicks":0}
        """)
        stub.stub(pathSuffix: "/Items/i1/PlaybackInfo", json: """
        {"MediaSources":[{"Id":"src1","Container":"mp4","SupportsDirectPlay":true}],
        "PlaySessionId":"ps1"}
        """)
        let provider = JellyfinProvider(session: makeSession(), http: stub)
        _ = try await provider.playbackInfo(for: "i1")

        let bodyEntry = try XCTUnwrap(stub.sentBodies.first { $0.key.hasSuffix("/Items/i1/PlaybackInfo") })
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyEntry.value) as? [String: Any])
        XCTAssertEqual(json["UserId"] as? String, "u1")
        XCTAssertEqual(json["AutoOpenLiveStream"] as? Bool, true)
        let deviceProfile = try XCTUnwrap(json["DeviceProfile"] as? [String: Any])
        let direct = try XCTUnwrap(deviceProfile["DirectPlayProfiles"] as? [[String: Any]])
        XCTAssertFalse(direct.isEmpty)
        XCTAssertNotNil(deviceProfile["TranscodingProfiles"])
    }
}

final class JellyfinQuickConnectClientTests: XCTestCase {
    private func client(_ stub: StubHTTPClient) -> JellyfinClient {
        JellyfinClient(
            baseURL: URL(string: "http://host:8096")!,
            deviceProfile: JellyfinDeviceProfile(deviceID: "d1"),
            http: stub
        )
    }

    func testQuickConnectEnabledFalseWhenNotFound() async throws {
        let stub = StubHTTPClient() // returns notFound for unknown paths
        let enabled = try await client(stub).quickConnectEnabled()
        XCTAssertFalse(enabled)
    }

    func testInitiateParsesChallenge() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/QuickConnect/Initiate", json: #"{"Authenticated":false,"Secret":"SEC","Code":"123456"}"#)
        let challenge = try await client(stub).quickConnectInitiate()
        XCTAssertEqual(challenge.userCode, "123456")
        XCTAssertEqual(challenge.secret, "SEC")
        XCTAssertFalse(challenge.isAuthenticated)
    }

    func testStateExpiredWhenSecretUnknown() async {
        let stub = StubHTTPClient() // notFound for Connect
        do {
            _ = try await client(stub).quickConnectState(secret: "SEC")
            XCTFail("Expected expiry")
        } catch let error as AppError {
            XCTAssertEqual(error, .quickConnectExpired)
        } catch {
            XCTFail("Unexpected \(error)")
        }
    }

    func testAuthenticateReturnsTokenAndUser() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Users/AuthenticateWithQuickConnect", json: """
        {"AccessToken":"TOK","ServerId":"srv","User":{"Id":"u9","Name":"Bob"}}
        """)
        let result = try await client(stub).authenticate(withSecret: "SEC")
        XCTAssertEqual(result.token, "TOK")
        XCTAssertEqual(result.userID, "u9")
        XCTAssertEqual(result.userName, "Bob")
        XCTAssertEqual(result.serverID, "srv")
    }

    func testAuthenticateByNameReturnsTokenAndUser() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Users/AuthenticateByName", json: """
        {"AccessToken":"TOK2","ServerId":"srv2","User":{"Id":"u3","Name":"Carol"}}
        """)
        let result = try await client(stub).authenticate(username: "carol", password: "hunter2")
        XCTAssertEqual(result.token, "TOK2")
        XCTAssertEqual(result.userID, "u3")
        XCTAssertEqual(result.userName, "Carol")
        XCTAssertEqual(result.serverID, "srv2")
    }

    func testAuthenticateByNameMapsUnauthorizedToInvalidCredentials() async {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Users/AuthenticateByName", json: "{}", status: 401)
        do {
            _ = try await client(stub).authenticate(username: "x", password: "wrong")
            XCTFail("Expected invalidCredentials")
        } catch let error as AppError {
            XCTAssertEqual(error, .invalidCredentials)
        } catch {
            XCTFail("Unexpected \(error)")
        }
    }
}
