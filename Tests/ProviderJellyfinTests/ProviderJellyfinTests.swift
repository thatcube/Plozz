import XCTest
import CoreModels
import CoreNetworking
@testable import ProviderJellyfin

final class JellyfinDeviceProfileTests: XCTestCase {
    func testAuthorizationHeaderFormat() {
        let profile = JellyfinDeviceProfile(client: "Plizz", device: "Apple TV", deviceID: "DID", version: "1.0")
        let header = profile.authorizationHeaderValue()
        XCTAssertTrue(header.hasPrefix("MediaBrowser "))
        XCTAssertTrue(header.contains(#"Client="Plizz""#))
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

    func testPlaybackInfoResolvesDirectStreamWithApiKey() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Users/u1/Items/i1", json: """
        {"Id":"i1","Name":"Movie","Type":"Movie","RunTimeTicks":0,
        "UserData":{"PlaybackPositionTicks":0}}
        """)
        stub.stub(pathSuffix: "/Items/i1/PlaybackInfo", json: """
        {"MediaSources":[{"Id":"src1","Container":"mkv","SupportsDirectPlay":true,
        "MediaStreams":[{"Index":1,"Type":"Audio","Language":"eng","DisplayTitle":"English"},
        {"Index":2,"Type":"Subtitle","Language":"eng","DisplayTitle":"English (SRT)"}]}],
        "PlaySessionId":"ps1"}
        """)
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        let request = try await provider.playbackInfo(for: "i1")
        XCTAssertEqual(request.playSessionID, "ps1")
        XCTAssertEqual(request.audioTracks.count, 1)
        XCTAssertEqual(request.subtitleTracks.count, 1)
        XCTAssertTrue(request.streamURL.absoluteString.contains("/Videos/i1/stream.mkv"))
        XCTAssertTrue(request.streamURL.absoluteString.contains("api_key=TOKEN"))
        XCTAssertTrue(request.streamURL.absoluteString.contains("mediaSourceId=src1"))
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
}
