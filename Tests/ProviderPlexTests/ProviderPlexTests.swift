import XCTest
import CoreModels
import CoreNetworking
@testable import ProviderPlex

// MARK: - Pure logic

final class PlexPinFlowTests: XCTestCase {
    func testPendingWhenAuthTokenNil() {
        let pin = decodePin(#"{"id":1,"code":"abcd","authToken":null}"#)
        XCTAssertEqual(PlexPinFlow.evaluate(pin: pin), .pending)
    }

    func testPendingWhenAuthTokenEmptyOrWhitespace() {
        XCTAssertEqual(PlexPinFlow.evaluate(pin: decodePin(#"{"id":1,"code":"a","authToken":""}"#)), .pending)
        XCTAssertEqual(PlexPinFlow.evaluate(pin: decodePin(#"{"id":1,"code":"a","authToken":"   "}"#)), .pending)
    }

    func testClaimedWhenAuthTokenPresent() {
        let pin = decodePin(#"{"id":1,"code":"abcd","authToken":"TOKEN123"}"#)
        XCTAssertEqual(PlexPinFlow.evaluate(pin: pin), .claimed(authToken: "TOKEN123"))
    }

    private func decodePin(_ json: String) -> PlexPinDTO {
        try! JSONDecoder.plozz.decode(PlexPinDTO.self, from: Data(json.utf8))
    }
}

final class PlexConnectionSelectorTests: XCTestCase {
    private func connections(_ json: String) -> [PlexConnectionDTO] {
        try! JSONDecoder.plozz.decode([PlexConnectionDTO].self, from: Data(json.utf8))
    }

    func testPrefersLocalNonRelayOverRemoteAndRelay() {
        let conns = connections("""
        [
          {"protocol":"https","uri":"https://relay.plex.direct:443","local":false,"relay":true},
          {"protocol":"https","uri":"https://remote.plex.direct:32400","local":false,"relay":false},
          {"protocol":"https","uri":"https://local.plex.direct:32400","local":true,"relay":false}
        ]
        """)
        XCTAssertEqual(PlexConnectionSelector.best(from: conns)?.absoluteString, "https://local.plex.direct:32400")
    }

    func testPrefersRemoteDirectOverRelay() {
        let conns = connections("""
        [
          {"protocol":"https","uri":"https://relay.plex.direct:443","local":false,"relay":true},
          {"protocol":"https","uri":"https://remote.plex.direct:32400","local":false,"relay":false}
        ]
        """)
        XCTAssertEqual(PlexConnectionSelector.best(from: conns)?.absoluteString, "https://remote.plex.direct:32400")
    }

    func testRelayUsedAsLastResort() {
        let conns = connections(#"[{"protocol":"https","uri":"https://relay.plex.direct:443","local":false,"relay":true}]"#)
        XCTAssertEqual(PlexConnectionSelector.best(from: conns)?.absoluteString, "https://relay.plex.direct:443")
    }

    func testPrefersSecureWithinSameTier() {
        let conns = connections("""
        [
          {"protocol":"http","uri":"http://local.example:32400","local":true,"relay":false},
          {"protocol":"https","uri":"https://local.plex.direct:32400","local":true,"relay":false}
        ]
        """)
        XCTAssertEqual(PlexConnectionSelector.best(from: conns)?.absoluteString, "https://local.plex.direct:32400")
    }

    func testNilWhenNoUsableConnections() {
        XCTAssertNil(PlexConnectionSelector.best(from: connections("[]")))
    }
}

// MARK: - Provider mapping

final class PlexProviderMappingTests: XCTestCase {
    private func makeSession() -> UserSession {
        UserSession(
            server: MediaServer(id: "srv", name: "Home", baseURL: URL(string: "https://plex.host:32400")!, provider: .plex),
            userID: "u1", userName: "Alice", deviceID: "d1", accessToken: "TOKEN"
        )
    }

    func testLibrariesMapSectionType() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/library/sections", json: """
        {"MediaContainer":{"size":2,"Directory":[
          {"key":"1","title":"Movies","type":"movie","thumb":"/m.png"},
          {"key":"2","title":"Shows","type":"show"}
        ]}}
        """)
        let provider = PlexProvider(session: makeSession(), http: stub)

        let libs = try await provider.libraries()
        XCTAssertEqual(libs.map(\.title), ["Movies", "Shows"])
        XCTAssertEqual(libs.map(\.id), ["1", "2"])
        XCTAssertEqual(libs[0].kind, .movie)
        XCTAssertEqual(libs[1].kind, .series)
    }

    func testTrailersFilterToTrailerSubtype() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/library/metadata/101/extras", json: """
        {"MediaContainer":{"size":2,"Metadata":[
          {"ratingKey":"e1","type":"clip","subtype":"trailer","title":"Trailer"},
          {"ratingKey":"e2","type":"clip","subtype":"behindTheScenes","title":"Making Of"}
        ]}}
        """)
        let provider = PlexProvider(session: makeSession(), http: stub)

        let trailers = try await provider.trailers(for: "101")

        XCTAssertEqual(trailers.map(\.id), ["e1"])
        XCTAssertEqual(trailers.first?.title, "Trailer")
        XCTAssertEqual(trailers.first?.kind, .video)
    }

    func testTrailersEmptyWhenNoExtras() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/library/metadata/101/extras", json: """
        {"MediaContainer":{"size":0}}
        """)
        let provider = PlexProvider(session: makeSession(), http: stub)

        let trailers = try await provider.trailers(for: "101")
        XCTAssertTrue(trailers.isEmpty)
    }

    func testContinueWatchingMapsResumeFields() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/library/onDeck", json: """
        {"MediaContainer":{"size":1,"Metadata":[
          {"ratingKey":"101","type":"movie","title":"Blade Runner","year":1982,
           "duration":7200000,"viewOffset":1800000}
        ]}}
        """)
        let provider = PlexProvider(session: makeSession(), http: stub)

        let items = try await provider.continueWatching(limit: 10)
        XCTAssertEqual(items.count, 1)
        let item = items[0]
        XCTAssertEqual(item.id, "101")
        XCTAssertEqual(item.title, "Blade Runner")
        XCTAssertEqual(item.kind, .movie)
        XCTAssertEqual(item.productionYear, 1982)
        XCTAssertEqual(item.runtime, 7200)
        XCTAssertEqual(item.resumePosition, 1800)
        XCTAssertEqual(item.playedPercentage ?? 0, 0.25, accuracy: 0.001)
    }

    func testEpisodeMapsSeriesTitleAndNumbers() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/library/metadata/55", json: """
        {"MediaContainer":{"Metadata":[
          {"ratingKey":"55","type":"episode","title":"Pilot",
           "grandparentTitle":"The Show","parentTitle":"Season 1",
           "index":3,"parentIndex":1,"duration":1500000,
           "grandparentThumb":"/show.png","art":"/art.png","summary":"First episode"}
        ]}}
        """)
        let provider = PlexProvider(session: makeSession(), http: stub)

        let item = try await provider.item(id: "55")
        XCTAssertEqual(item.kind, .episode)
        XCTAssertEqual(item.parentTitle, "The Show")
        XCTAssertEqual(item.seasonNumber, 1)
        XCTAssertEqual(item.episodeNumber, 3)
        XCTAssertEqual(item.overview, "First episode")
        XCTAssertEqual(item.subtitle, "S1 · E3")
        XCTAssertEqual(item.posterURL?.absoluteString, "https://plex.host:32400/photo/:/transcode?width=500&height=750&minSize=1&upscale=1&url=%2Fshow.png%3FX-Plex-Token%3DTOKEN&X-Plex-Token=TOKEN")
    }

    func testItemsPagePassesContainerParamsAndType() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/library/sections/1/all", json: """
        {"MediaContainer":{"size":2,"totalSize":250,"offset":60,"Metadata":[
          {"ratingKey":"m1","type":"movie","title":"Alien"},
          {"ratingKey":"m2","type":"movie","title":"Aliens"}
        ]}}
        """)
        let provider = PlexProvider(session: makeSession(), http: stub)

        let page = try await provider.items(in: "1", kind: .movie, page: PageRequest(startIndex: 60, limit: 60))
        XCTAssertEqual(page.items.map(\.title), ["Alien", "Aliens"])
        XCTAssertEqual(page.items.first?.kind, .movie)
        XCTAssertEqual(page.startIndex, 60)
        XCTAssertEqual(page.totalCount, 250)
        XCTAssertTrue(page.hasMore)

        let query = try XCTUnwrap(stub.queryItems(forPathSuffix: "/library/sections/1/all"))
        XCTAssertEqual(query.first(where: { $0.name == "X-Plex-Container-Start" })?.value, "60")
        XCTAssertEqual(query.first(where: { $0.name == "X-Plex-Container-Size" })?.value, "60")
        XCTAssertEqual(query.first(where: { $0.name == "type" })?.value, "1")
    }

    func testSeriesLibraryUsesShowType() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/library/sections/2/all", json: #"{"MediaContainer":{"size":0,"totalSize":0,"Metadata":[]}}"#)
        let provider = PlexProvider(session: makeSession(), http: stub)

        _ = try await provider.items(in: "2", kind: .series, page: PageRequest())
        let query = try XCTUnwrap(stub.queryItems(forPathSuffix: "/library/sections/2/all"))
        XCTAssertEqual(query.first(where: { $0.name == "type" })?.value, "2")
    }

    func testChildrenMapSeasons() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/library/metadata/9/children", json: """
        {"MediaContainer":{"size":1,"Metadata":[
          {"ratingKey":"s1","type":"season","title":"Season 1","index":1}
        ]}}
        """)
        let provider = PlexProvider(session: makeSession(), http: stub)

        let children = try await provider.children(of: "9")
        XCTAssertEqual(children.count, 1)
        XCTAssertEqual(children[0].kind, .season)
        XCTAssertEqual(children[0].id, "s1")
    }

    func testPlaybackInfoTranscodesUnsupportedContainer() async throws {
        // An MKV part cannot be demuxed by AVFoundation, so the provider must
        // resolve a server-side HLS transcode URL rather than the raw file —
        // this is the fix for "Plex doesn't play while Jellyfin does".
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/library/metadata/77", json: """
        {"MediaContainer":{"Metadata":[
          {"ratingKey":"77","type":"movie","title":"Movie","duration":3600000,"viewOffset":600000,
           "Media":[{"id":1,"container":"mkv","videoCodec":"h264","audioCodec":"ac3","Part":[{"id":2,"key":"/library/parts/2/16000/file.mkv","container":"mkv","Stream":[
             {"id":10,"streamType":1,"index":0,"codec":"h264"},
             {"id":11,"streamType":2,"index":1,"codec":"ac3","language":"English","languageTag":"en","displayTitle":"English (AC3)","selected":true},
             {"id":12,"streamType":3,"index":2,"language":"English","displayTitle":"English (SRT)","forced":false}
           ]}]}]}
        ]}}
        """)
        let provider = PlexProvider(session: makeSession(), http: stub)

        let request = try await provider.playbackInfo(for: "77")
        XCTAssertEqual(request.playSessionID, "77")
        XCTAssertEqual(request.startPosition, 600)
        XCTAssertEqual(request.audioTracks.count, 1)
        XCTAssertEqual(request.subtitleTracks.count, 1)
        XCTAssertEqual(request.audioTracks.first?.language, "en")
        XCTAssertTrue(request.audioTracks.first?.isDefault == true)
        XCTAssertTrue(request.isTranscoding)

        let url = request.streamURL.absoluteString
        XCTAssertTrue(url.hasPrefix("https://plex.host:32400/video/:/transcode/universal/start.m3u8"), url)
        XCTAssertTrue(url.contains("protocol=hls"), url)
        XCTAssertTrue(url.contains("path=/library/metadata/77"), url)
        XCTAssertTrue(url.contains("X-Plex-Token=TOKEN"), url)
    }

    func testPlaybackInfoDirectPlaysSupportedContainer() async throws {
        // An MP4/h264/aac file is natively playable, so the provider should hand
        // AVPlayer the original part URL (direct play, no transcode).
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/library/metadata/88", json: """
        {"MediaContainer":{"Metadata":[
          {"ratingKey":"88","type":"movie","title":"Movie","duration":3600000,
           "Media":[{"id":1,"container":"mp4","videoCodec":"h264","audioCodec":"aac","Part":[{"id":2,"key":"/library/parts/2/16000/file.mp4","container":"mp4","Stream":[
             {"id":10,"streamType":1,"index":0,"codec":"h264"},
             {"id":11,"streamType":2,"index":1,"codec":"aac","language":"English","languageTag":"en","selected":true}
           ]}]}]}
        ]}}
        """)
        let provider = PlexProvider(session: makeSession(), http: stub)

        let request = try await provider.playbackInfo(for: "88")
        XCTAssertFalse(request.isTranscoding)
        let url = request.streamURL.absoluteString
        XCTAssertTrue(url.hasPrefix("https://plex.host:32400/library/parts/2/16000/file.mp4"), url)
        XCTAssertTrue(url.contains("X-Plex-Token=TOKEN"), url)
    }

    func testReportPlaybackSendsTimelineState() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/:/timeline", json: "")
        let provider = PlexProvider(session: makeSession(), http: stub)

        try await provider.reportPlayback(
            PlaybackProgress(itemID: "77", playSessionID: "77", positionSeconds: 120, isPaused: true),
            event: .pause
        )

        let query = try XCTUnwrap(stub.queryItems(forPathSuffix: "/:/timeline"))
        XCTAssertEqual(query.first(where: { $0.name == "ratingKey" })?.value, "77")
        XCTAssertEqual(query.first(where: { $0.name == "state" })?.value, "paused")
        XCTAssertEqual(query.first(where: { $0.name == "time" })?.value, "120000")
    }

    func testReportPlaybackStopMapsToStopped() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/:/timeline", json: "")
        let provider = PlexProvider(session: makeSession(), http: stub)

        try await provider.reportPlayback(
            PlaybackProgress(itemID: "77", playSessionID: "77", positionSeconds: 0, isPaused: false),
            event: .stop
        )
        let query = try XCTUnwrap(stub.queryItems(forPathSuffix: "/:/timeline"))
        XCTAssertEqual(query.first(where: { $0.name == "state" })?.value, "stopped")
    }
}

// MARK: - Auth client

final class PlexAuthClientTests: XCTestCase {
    private func client(_ stub: StubHTTPClient) -> PlexAuthClient {
        PlexAuthClient(deviceProfile: PlexDeviceProfile(clientIdentifier: "dev1"), http: stub)
    }

    func testCreatePinParsesChallenge() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/api/v2/pins", json: #"{"id":424242,"code":"WXYZ","authToken":null}"#)
        let pin = try await client(stub).createPin()
        XCTAssertEqual(pin.id, 424242)
        XCTAssertEqual(pin.code, "WXYZ")

        // We must NOT request a strong PIN: strong codes are long and not
        // usable for the plex.tv/link manual-entry flow.
        let query = stub.queryItems(forPathSuffix: "/api/v2/pins")
        XCTAssertNil(query?.first(where: { $0.name == "strong" }))
    }

    func testPollPinPendingThenClaimed() async throws {
        let stub = StubHTTPClient()
        stub.stubSequence(pathSuffix: "/api/v2/pins/1", jsons: [
            #"{"id":1,"code":"WXYZ","authToken":null}"#,
            #"{"id":1,"code":"WXYZ","authToken":"ACCOUNT_TOKEN"}"#
        ])
        let c = client(stub)
        let first = try await c.pollPin(id: 1)
        XCTAssertEqual(first, .pending)
        let second = try await c.pollPin(id: 1)
        XCTAssertEqual(second, .claimed(authToken: "ACCOUNT_TOKEN"))
    }

    func testServersFilterToServerProvidesAndPickConnection() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/api/v2/resources", json: """
        [
          {"name":"Player","provides":"client","clientIdentifier":"c1","connections":[]},
          {"name":"My Server","provides":"server","clientIdentifier":"srv1","accessToken":"SRVTOKEN","owned":true,
           "connections":[
             {"protocol":"https","uri":"https://remote.plex.direct:32400","local":false,"relay":false},
             {"protocol":"https","uri":"https://local.plex.direct:32400","local":true,"relay":false}
           ]}
        ]
        """)
        let servers = try await client(stub).servers(authToken: "ACCOUNT_TOKEN")
        XCTAssertEqual(servers.count, 1)
        XCTAssertEqual(servers[0].id, "srv1")
        XCTAssertEqual(servers[0].name, "My Server")
        XCTAssertEqual(servers[0].accessToken, "SRVTOKEN")
        XCTAssertTrue(servers[0].isOwned)
        XCTAssertEqual(servers[0].baseURL.absoluteString, "https://local.plex.direct:32400")
    }

    func testUserParsesIdentity() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/api/v2/user", json: #"{"id":9,"uuid":"uuid-9","username":"alice","title":"Alice T"}"#)
        let user = try await client(stub).user(authToken: "ACCOUNT_TOKEN")
        XCTAssertEqual(user.id, "uuid-9")
        XCTAssertEqual(user.userName, "Alice T")
    }

    func testHomeUsersParsesAndMapsFlags() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/api/v2/home/users", json: """
        {"users":[
          {"id":1,"uuid":"owner-uuid","title":"Brandon","admin":true,"protected":false,"restricted":false},
          {"id":2,"uuid":"kid-uuid","title":"Kiddo","admin":false,"protected":true,"restricted":true}
        ]}
        """)
        let users = try await client(stub).homeUsers(authToken: "ADMIN_TOKEN")
        XCTAssertEqual(users.count, 2)
        XCTAssertEqual(users[0].id, "owner-uuid")
        XCTAssertEqual(users[0].name, "Brandon")
        XCTAssertTrue(users[0].isAdmin)
        XCTAssertFalse(users[0].requiresPIN)
        XCTAssertEqual(users[1].id, "kid-uuid")
        XCTAssertTrue(users[1].requiresPIN)
        XCTAssertTrue(users[1].isRestricted)
        XCTAssertEqual(stub.method(forPathSuffix: "/api/v2/home/users"), .get)
    }

    func testHomeUsersTreatsHasPasswordAsRequiresPIN() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/api/v2/home/users", json: """
        {"users":[{"uuid":"u","title":"Guest","hasPassword":true}]}
        """)
        let users = try await client(stub).homeUsers(authToken: "ADMIN_TOKEN")
        XCTAssertEqual(users.count, 1)
        XCTAssertTrue(users[0].requiresPIN)
    }

    func testSwitchHomeUserPassesPinAndReturnsToken() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/kid-uuid/switch", json: #"{"authToken":"KID_TOKEN"}"#)
        let token = try await client(stub).switchHomeUser(uuid: "kid-uuid", pin: "1234", authToken: "ADMIN_TOKEN")
        XCTAssertEqual(token, "KID_TOKEN")
        XCTAssertEqual(stub.method(forPathSuffix: "/kid-uuid/switch"), .post)
        let pin = stub.queryItems(forPathSuffix: "/kid-uuid/switch")?.first { $0.name == "pin" }
        XCTAssertEqual(pin?.value, "1234")
    }

    func testSwitchHomeUserOmitsPinWhenNil() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/owner-uuid/switch", json: #"{"authenticationToken":"OWNER_TOKEN"}"#)
        let token = try await client(stub).switchHomeUser(uuid: "owner-uuid", pin: nil, authToken: "ADMIN_TOKEN")
        XCTAssertEqual(token, "OWNER_TOKEN")
        let query = stub.queryItems(forPathSuffix: "/owner-uuid/switch")
        XCTAssertNil(query?.first { $0.name == "pin" })
    }

    func testSwitchHomeUserUnauthorizedWhenNoToken() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/kid-uuid/switch", json: #"{"authToken":null}"#)
        do {
            _ = try await client(stub).switchHomeUser(uuid: "kid-uuid", pin: "0000", authToken: "ADMIN_TOKEN")
            XCTFail("Expected unauthorized")
        } catch let error as AppError {
            XCTAssertEqual(error, .unauthorized)
        }
    }
}

// MARK: - Capability-driven direct play

final class PlexDirectPlayCapabilityTests: XCTestCase {

    private func makeClient(_ caps: MediaCapabilities) -> PlexClient {
        PlexClient(
            baseURL: URL(string: "https://plex.host:32400")!,
            deviceProfile: PlexDeviceProfile(clientIdentifier: "dev1"),
            token: "TOKEN",
            http: StubHTTPClient(),
            capabilities: caps
        )
    }

    /// Decodes a single `Media`/`Part` pair from a Plex metadata JSON fragment.
    private func decodeMedia(_ json: String) throws -> (PlexMedia, PlexPart) {
        let wrapper = "{\"MediaContainer\":{\"Metadata\":[{\"ratingKey\":\"1\",\"Media\":[\(json)]}]}}"
        let response = try JSONDecoder().decode(PlexMediaContainerResponse.self, from: Data(wrapper.utf8))
        let media = try XCTUnwrap(response.MediaContainer.Metadata?.first?.Media?.first)
        let part = try XCTUnwrap(media.Part?.first)
        return (media, part)
    }

    private func canDirectPlay(_ json: String, caps: MediaCapabilities) throws -> Bool {
        let (media, part) = try decodeMedia(json)
        return makeClient(caps).canDirectPlay(media: media, part: part)
    }

    // The bread-and-butter case must be unaffected by the rework: an MP4 with
    // h264 video + AAC audio direct-plays under the conservative default profile.
    func testCommonH264AacMp4DirectPlaysUnderDefault() throws {
        let json = """
        {"id":1,"container":"mp4","videoCodec":"h264","audioCodec":"aac",
         "Part":[{"id":2,"key":"/library/parts/2/16000/file.mp4","container":"mp4","Stream":[
           {"id":10,"streamType":1,"index":0,"codec":"h264"},
           {"id":11,"streamType":2,"index":1,"codec":"aac"}
         ]}]}
        """
        XCTAssertTrue(try canDirectPlay(json, caps: .default))
    }

    func testHevcGatedOnSupport() throws {
        // Plex labels HEVC as "h265" here; it must fold onto .hevc.
        let json = """
        {"id":1,"container":"mp4","videoCodec":"h265","audioCodec":"aac",
         "Part":[{"id":2,"key":"/library/parts/2/16000/file.mp4","container":"mp4","Stream":[
           {"id":10,"streamType":1,"index":0,"codec":"hevc"},
           {"id":11,"streamType":2,"index":1,"codec":"aac"}
         ]}]}
        """
        let hevcYes = MediaCapabilities(supportsHEVC: true)
        let hevcNo = MediaCapabilities(supportsHEVC: false)
        XCTAssertTrue(try canDirectPlay(json, caps: hevcYes))
        XCTAssertFalse(try canDirectPlay(json, caps: hevcNo))
    }

    func testAV1GatedOnSupport() throws {
        let json = """
        {"id":1,"container":"mp4","videoCodec":"av1","audioCodec":"aac",
         "Part":[{"id":2,"key":"/library/parts/2/16000/file.mp4","container":"mp4","Stream":[
           {"id":10,"streamType":1,"index":0,"codec":"av1"},
           {"id":11,"streamType":2,"index":1,"codec":"aac"}
         ]}]}
        """
        let av1Yes = MediaCapabilities(supportsAV1: true)
        XCTAssertFalse(try canDirectPlay(json, caps: .default), "AV1 must transcode without support")
        XCTAssertTrue(try canDirectPlay(json, caps: av1Yes))
    }

    func testDTSDirectPlayOnlyWhenPassthroughSupported() throws {
        // Plex commonly labels DTS as "dca"; it must fold onto .dts.
        let json = """
        {"id":1,"container":"mp4","videoCodec":"h264","audioCodec":"dca",
         "Part":[{"id":2,"key":"/library/parts/2/16000/file.mp4","container":"mp4","Stream":[
           {"id":10,"streamType":1,"index":0,"codec":"h264"},
           {"id":11,"streamType":2,"index":1,"codec":"dca"}
         ]}]}
        """
        let dtsYes = MediaCapabilities(maxOutputChannels: 8, supportsDTSPassthrough: true)
        XCTAssertFalse(try canDirectPlay(json, caps: .default), "stereo output must not claim DTS passthrough")
        XCTAssertTrue(try canDirectPlay(json, caps: dtsYes))
    }

    func testEAC3AlwaysPassthroughEligible() throws {
        let json = """
        {"id":1,"container":"mp4","videoCodec":"h264","audioCodec":"eac3",
         "Part":[{"id":2,"key":"/library/parts/2/16000/file.mp4","container":"mp4","Stream":[
           {"id":10,"streamType":1,"index":0,"codec":"h264"},
           {"id":11,"streamType":2,"index":1,"codec":"eac3"}
         ]}]}
        """
        XCTAssertTrue(try canDirectPlay(json, caps: .default))
    }

    func testDolbyVisionProfile7TranscodesEvenWithDoViDisplay() throws {
        let json = """
        {"id":1,"container":"mp4","videoCodec":"hevc","audioCodec":"aac",
         "Part":[{"id":2,"key":"/library/parts/2/16000/file.mp4","container":"mp4","Stream":[
           {"id":10,"streamType":1,"index":0,"codec":"hevc","DOVIPresent":true,"DOVIProfile":7},
           {"id":11,"streamType":2,"index":1,"codec":"aac"}
         ]}]}
        """
        let doviDisplay = MediaCapabilities(supportsHEVC: true, supportsDolbyVision: true)
        XCTAssertFalse(try canDirectPlay(json, caps: doviDisplay))
    }

    func testDolbyVisionProfile8DirectPlaysOnDoViDisplayOnly() throws {
        let json = """
        {"id":1,"container":"mp4","videoCodec":"hevc","audioCodec":"aac",
         "Part":[{"id":2,"key":"/library/parts/2/16000/file.mp4","container":"mp4","Stream":[
           {"id":10,"streamType":1,"index":0,"codec":"hevc","DOVIPresent":true,"DOVIProfile":8},
           {"id":11,"streamType":2,"index":1,"codec":"aac"}
         ]}]}
        """
        let doviDisplay = MediaCapabilities(supportsHEVC: true, supportsDolbyVision: true)
        XCTAssertTrue(try canDirectPlay(json, caps: doviDisplay))
        XCTAssertFalse(try canDirectPlay(json, caps: .default), "non-DoVi display must transcode DoVi")
    }

    func testUnknownDolbyVisionProfileIsConservative() throws {
        // DOVIPresent but no profile reported → don't assume P5/P8.
        let json = """
        {"id":1,"container":"mp4","videoCodec":"hevc","audioCodec":"aac",
         "Part":[{"id":2,"key":"/library/parts/2/16000/file.mp4","container":"mp4","Stream":[
           {"id":10,"streamType":1,"index":0,"codec":"hevc","DOVIPresent":true},
           {"id":11,"streamType":2,"index":1,"codec":"aac"}
         ]}]}
        """
        let doviDisplay = MediaCapabilities(supportsHEVC: true, supportsDolbyVision: true)
        XCTAssertFalse(try canDirectPlay(json, caps: doviDisplay))
    }

    func testHDR10GatedOnDisplay() throws {
        let json = """
        {"id":1,"container":"mp4","videoCodec":"hevc","audioCodec":"aac",
         "Part":[{"id":2,"key":"/library/parts/2/16000/file.mp4","container":"mp4","Stream":[
           {"id":10,"streamType":1,"index":0,"codec":"hevc","colorTrc":"smpte2084"},
           {"id":11,"streamType":2,"index":1,"codec":"aac"}
         ]}]}
        """
        let hdrDisplay = MediaCapabilities(supportsHEVC: true, supportsHDR10: true)
        let sdrOnly = MediaCapabilities(supportsHEVC: true, supportsHDR10: false, supportsHLG: false)
        XCTAssertTrue(try canDirectPlay(json, caps: hdrDisplay))
        XCTAssertFalse(try canDirectPlay(json, caps: sdrOnly))
    }

    func testUnsupportedContainerStillTranscodes() throws {
        let json = """
        {"id":1,"container":"mkv","videoCodec":"h264","audioCodec":"aac",
         "Part":[{"id":2,"key":"/library/parts/2/16000/file.mkv","container":"mkv","Stream":[
           {"id":10,"streamType":1,"index":0,"codec":"h264"},
           {"id":11,"streamType":2,"index":1,"codec":"aac"}
         ]}]}
        """
        XCTAssertFalse(try canDirectPlay(json, caps: .default))
    }
}

final class PlexWatchStateTests: XCTestCase {
    private func makeSession() -> UserSession {
        UserSession(
            server: MediaServer(id: "srv", name: "Home", baseURL: URL(string: "https://plex.host:32400")!, provider: .plex),
            userID: "u1", userName: "Alice", deviceID: "d1", accessToken: "TOKEN"
        )
    }

    func testSetPlayedTrueScrobbles() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/:/scrobble", json: "")
        let provider = PlexProvider(session: makeSession(), http: stub)

        try await provider.setPlayed(true, itemID: "42")

        XCTAssertTrue(stub.sentPaths.contains { $0.hasSuffix("/:/scrobble") })
        let query = stub.queryItems(forPathSuffix: "/:/scrobble")
        XCTAssertEqual(query?.first(where: { $0.name == "key" })?.value, "42")
        XCTAssertEqual(
            query?.first(where: { $0.name == "identifier" })?.value,
            "com.plexapp.plugins.library"
        )
    }

    func testSetPlayedFalseUnscrobbles() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/:/unscrobble", json: "")
        let provider = PlexProvider(session: makeSession(), http: stub)

        try await provider.setPlayed(false, itemID: "42")

        XCTAssertTrue(stub.sentPaths.contains { $0.hasSuffix("/:/unscrobble") })
        XCTAssertEqual(
            stub.queryItems(forPathSuffix: "/:/unscrobble")?.first(where: { $0.name == "key" })?.value,
            "42"
        )
    }
}
