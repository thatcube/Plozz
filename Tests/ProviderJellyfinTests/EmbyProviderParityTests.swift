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
         "Studios":[{"Name":"Emby Studio","Id":1234}],
         "MediaStreams":[
           {"Index":0,"Type":"Video","Codec":"hevc","Width":3840,"Height":2160,
            "VideoRange":"SDR","ExtendedVideoType":"DolbyVision",
            "ExtendedVideoSubType":"DoviProfile81"},
           {"Index":1,"Type":"Audio","Codec":"truehd","Channels":8,"IsDefault":true}
         ],
         "MediaSources":[
           {"Id":"src1","Name":"4K Remux","Container":"mkv",
            "MediaStreams":[
              {"Index":0,"Type":"Video","Codec":"hevc","Width":3840,"Height":2160,
               "VideoRange":"SDR"},
              {"Index":1,"Type":"Audio","Codec":"truehd","Channels":8,"IsDefault":true}
            ]},
           {"Id":"src2","Name":"1080p","Container":"mp4",
            "MediaStreams":[
              {"Index":0,"Type":"Video","Codec":"h264","Width":1920,"Height":1080,
               "VideoRange":"SDR"}
            ]}
         ]}
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
        XCTAssertEqual(
            request.item.technicalBadges.map(\.label),
            ["4K", "Dolby Vision", "Dolby TrueHD", "HDR10"]
        )
        XCTAssertEqual(request.sourceMetadata?.video?.dolbyVisionProfile, 8)
        XCTAssertEqual(request.sourceMetadata?.video?.videoRangeType, "DOVIWithHDR10")
        XCTAssertEqual(
            request.item.versions.first?.technicalBadges.map(\.label),
            ["4K", "Dolby Vision", "Dolby TrueHD", "HDR10"]
        )
        XCTAssertEqual(
            request.item.versions.last?.technicalBadges.map(\.label),
            ["1080p", "SDR"]
        )
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

    func testEmbyExtendedHDRTypeOverridesCoarseSDRRange() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Users/u1/Items/air", json: """
        {"Id":"air","Name":"Air","Type":"Movie",
         "MediaStreams":[
           {"Index":0,"Type":"Video","Codec":"hevc","Width":3840,"Height":2160,
            "VideoRange":"SDR","ExtendedVideoType":"Hdr10"}
         ]}
        """)
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        let item = try await provider.item(id: "air")

        XCTAssertEqual(item.technicalBadges.map(\.label), ["4K", "HDR10"])
        XCTAssertFalse(item.technicalBadges.map(\.label).contains("SDR"))
    }

    func testEmbyEpisodesAreNormalizedIntoNumericOrder() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Users/u1/Items", json: """
        {"Items":[
          {"Id":"extra","Name":"Behind the Scenes","Type":"Video"},
          {"Id":"e10","Name":"Episode 10","Type":"Episode","ParentIndexNumber":1,"IndexNumber":10},
          {"Id":"e2","Name":"Episode 2","Type":"Episode","ParentIndexNumber":1,"IndexNumber":2},
          {"Id":"e1","Name":"Episode 1","Type":"Episode","ParentIndexNumber":1,"IndexNumber":1}
        ],"TotalRecordCount":4}
        """)
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        let children = try await provider.children(of: "season1")

        XCTAssertEqual(children.map(\.id), ["e1", "e2", "e10", "extra"])
        let query = try XCTUnwrap(
            stub.queryItems(forPathSuffix: "/Users/u1/Items")
        )
        XCTAssertEqual(
            query.first(where: { $0.name == "SortBy" })?.value,
            "ParentIndexNumber,IndexNumber,SortName"
        )
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
