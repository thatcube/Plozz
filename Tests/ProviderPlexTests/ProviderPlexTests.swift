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
        XCTAssertEqual(item.posterURL?.absoluteString, "https://plex.host:32400/photo/:/transcode?width=500&height=750&minSize=1&url=/show.png&X-Plex-Token=TOKEN")
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

    func testPlaybackInfoResolvesDirectStreamAndTracks() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/library/metadata/77", json: """
        {"MediaContainer":{"Metadata":[
          {"ratingKey":"77","type":"movie","title":"Movie","duration":3600000,"viewOffset":600000,
           "Media":[{"id":1,"Part":[{"id":2,"key":"/library/parts/2/16000/file.mkv","Stream":[
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

        let url = request.streamURL.absoluteString
        XCTAssertTrue(url.hasPrefix("https://plex.host:32400/library/parts/2/16000/file.mkv"), url)
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

        let query = try XCTUnwrap(stub.queryItems(forPathSuffix: "/api/v2/pins"))
        XCTAssertEqual(query.first(where: { $0.name == "strong" })?.value, "true")
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
}
