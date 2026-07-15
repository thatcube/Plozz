import CoreModels
import CoreNetworking
import XCTest
@testable import ProviderJellyfin

final class EmbyProviderParityTests: XCTestCase {
    private func makeSession() -> UserSession {
        UserSession(
            server: MediaServer(
                id: "emby-server",
                name: "Emby Home",
                baseURL: URL(string: "http://host:8096")!,
                provider: .emby
            ),
            userID: "u1",
            userName: "Alice",
            deviceID: "d1",
            accessToken: "TOKEN"
        )
    }

    func testProviderUsesEmbyIdentityWhileSharingMediaBrowserImplementation() {
        let provider = JellyfinProvider(session: makeSession(), http: StubHTTPClient())

        XCTAssertEqual(provider.kind, .emby)
        XCTAssertTrue(provider.kind.usesMediaBrowserAPI)
    }

    func testEmbyMapsChapterMarkersToIntroAndCreditsSegments() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Users/u1/Items/episode1", json: """
        {
          "Id":"episode1",
          "Name":"Episode",
          "Type":"Episode",
          "RunTimeTicks":18000000000,
          "Chapters":[
            {"StartPositionTicks":600000000,"MarkerType":"IntroStart"},
            {"StartPositionTicks":1200000000,"MarkerType":"IntroEnd"},
            {"StartPositionTicks":16800000000,"MarkerType":"CreditsStart"}
          ]
        }
        """)
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        let segments = try await provider.mediaSegments(for: "episode1")

        XCTAssertEqual(segments.map(\.kind), [.intro, .credits])
        XCTAssertEqual(segments[0].start, 60)
        XCTAssertEqual(segments[0].end, 120)
        XCTAssertEqual(segments[1].start, 1680)
        XCTAssertEqual(segments[1].end, 1800)
        XCTAssertFalse(stub.sentPaths.contains { $0.contains("MediaSegments") })
    }

    func testEmbyPlaybackUsesBIFTrickplayAndEmbyAuthenticatedResources() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Users/u1/Items/movie1", json: """
        {"Id":"movie1","Name":"Movie","Type":"Movie","RunTimeTicks":36000000000,
         "Studios":[{"Name":"Emby Studio","Id":1234}]}
        """)
        stub.stub(pathSuffix: "/Items/movie1/PlaybackInfo", json: """
        {"MediaSources":[{"Id":"src1","Container":"mp4","SupportsDirectPlay":true}],
         "PlaySessionId":"ps1"}
        """)
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        let request = try await provider.playbackInfo(
            for: "movie1",
            mediaSourceID: "src1",
            forceTranscode: false
        )

        XCTAssertEqual(request.sourceProvider, .emby)
        XCTAssertEqual(request.item.studios, ["Emby Studio"])
        guard case .some(.authenticatedHTTP(let locator)) = request.scrubPreview?.plexBIFResource else {
            return XCTFail("expected authenticated Emby BIF resource")
        }
        XCTAssertEqual(locator.provider, .emby)
        XCTAssertEqual(locator.resource.path, "Videos/movie1/index.bif")
        XCTAssertEqual(locator.resource.queryItems.first?.name, "Width")
        XCTAssertEqual(locator.resource.queryItems.first?.value, "320")

        let body = try XCTUnwrap(stub.sentBodies.first {
            $0.key.hasSuffix("/Items/movie1/PlaybackInfo")
        }?.value)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["MediaSourceId"] as? String, "src1")
        XCTAssertEqual(json["EnableTranscoding"] as? Bool, true)
    }

    func testEmbyThemeMusicUsesCombinedThemeMediaEndpoint() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Items/show1/ThemeMedia", json: """
        {
          "ThemeSongsResult":{
            "Items":[{"Id":"song1","Name":"Main Theme","Type":"Audio"}],
            "TotalRecordCount":1
          }
        }
        """)
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        let resolvedTheme = try await provider.themeMusic(for: "show1")
        let theme = try XCTUnwrap(resolvedTheme)

        XCTAssertEqual(theme.title, "Main Theme")
        guard case .authenticatedHTTP(let locator) = theme.playbackSource else {
            return XCTFail("expected authenticated theme resource")
        }
        XCTAssertEqual(locator.provider, .emby)
        XCTAssertEqual(locator.resource.path, "Audio/song1/universal")
    }
}
