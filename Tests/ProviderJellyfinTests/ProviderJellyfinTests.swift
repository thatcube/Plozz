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
        "ProviderIds":{"Tmdb":"438631"},
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
        XCTAssertEqual(items[0].providerIDs["Tmdb"], "438631")

        let query = try XCTUnwrap(stub.queryItems(forPathSuffix: "/Users/u1/Items/Resume"))
        let fields = query.first(where: { $0.name == "Fields" })?.value ?? ""
        XCTAssertTrue(
            fields.split(separator: ",").contains(where: { $0.lowercased() == "providerids" }),
            "Resume requests must include ProviderIds so Home de-dup can match across servers"
        )
    }

    func testLatestIncludesProviderIDsForHomeDedup() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Users/u1/Items/Latest", json: """
        [{"Id":"m1","Name":"Dune","Type":"Movie","ProviderIds":{"Imdb":"tt1160419"}}]
        """)
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        let latest = try await provider.latest(limit: 20)
        XCTAssertEqual(latest.map(\.id), ["m1"])
        XCTAssertEqual(latest.first?.providerIDs["Imdb"], "tt1160419")

        let query = try XCTUnwrap(stub.queryItems(forPathSuffix: "/Users/u1/Items/Latest"))
        let fields = query.first(where: { $0.name == "Fields" })?.value ?? ""
        XCTAssertTrue(
            fields.split(separator: ",").contains(where: { $0.lowercased() == "providerids" }),
            "Latest requests must include ProviderIds so Home de-dup can match across servers"
        )
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

        let page = try await provider.items(in: "lib1", kind: .movie, page: PageRequest(startIndex: 60, limit: 60))

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
        // Movie libraries use the fast recursive/indexed query path.
        XCTAssertEqual(query.first(where: { $0.name == "Recursive" })?.value, "true")
        XCTAssertEqual(query.first(where: { $0.name == "IncludeItemTypes" })?.value, "Movie")
    }

    func testTrailersMapLocalTrailers() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Items/m1/LocalTrailers", json: """
        [{"Id":"t1","Name":"Official Trailer","Type":"Trailer","Container":"mp4"}]
        """)
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        let trailers = try await provider.trailers(for: "m1")

        XCTAssertEqual(trailers.map(\.id), ["t1"])
        XCTAssertEqual(trailers.first?.title, "Official Trailer")
        XCTAssertTrue(stub.sentPaths.contains { $0.hasSuffix("/Users/u1/Items/m1/LocalTrailers") })
    }

    func testTrailersEmptyWhenNoneReported() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Items/m1/LocalTrailers", json: "[]")
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        let trailers = try await provider.trailers(for: "m1")
        XCTAssertTrue(trailers.isEmpty)
    }

    func testItemsPageUsesSeriesTypeForTVLibrary() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Users/u1/Items", json: #"{"Items":[],"TotalRecordCount":0}"#)
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        _ = try await provider.items(in: "lib2", kind: .series, page: PageRequest())

        let query = try XCTUnwrap(stub.queryItems(forPathSuffix: "/Users/u1/Items"))
        XCTAssertEqual(query.first(where: { $0.name == "Recursive" })?.value, "true")
        XCTAssertEqual(query.first(where: { $0.name == "IncludeItemTypes" })?.value, "Series")
    }

    func testItemsPageFolderUsesNonRecursiveDirectChildren() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Users/u1/Items", json: #"{"Items":[],"TotalRecordCount":0}"#)
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        _ = try await provider.items(in: "folder1", kind: .folder, page: PageRequest())

        let query = try XCTUnwrap(stub.queryItems(forPathSuffix: "/Users/u1/Items"))
        XCTAssertNil(query.first(where: { $0.name == "Recursive" }))
        XCTAssertNil(query.first(where: { $0.name == "IncludeItemTypes" }))
        XCTAssertEqual(query.first(where: { $0.name == "ParentId" })?.value, "folder1")
    }

    func testItemsPageDefaultsTotalCountToItemCountWhenMissing() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Users/u1/Items", json: """
        {"Items":[{"Id":"m1","Name":"Solo","Type":"Movie"}]}
        """)
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        let page = try await provider.items(in: "lib1", kind: .movie, page: PageRequest(startIndex: 0, limit: 60))
        XCTAssertEqual(page.totalCount, 1)
        XCTAssertFalse(page.hasMore)
    }

    func testItemsPageDefaultSortIsNameAscending() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Users/u1/Items", json: #"{"Items":[],"TotalRecordCount":0}"#)
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        _ = try await provider.items(in: "lib1", kind: .movie, page: PageRequest())

        let query = try XCTUnwrap(stub.queryItems(forPathSuffix: "/Users/u1/Items"))
        XCTAssertEqual(query.first(where: { $0.name == "SortBy" })?.value, "SortName")
        XCTAssertEqual(query.first(where: { $0.name == "SortOrder" })?.value, "Ascending")
    }

    func testItemsPageMapsEachSortFieldToJellyfinSortBy() async throws {
        let expected: [SortField: String] = [
            .name: "SortName",
            .dateAdded: "DateCreated",
            .releaseDate: "PremiereDate",
            .communityRating: "CommunityRating",
            .runtime: "Runtime",
            .random: "Random"
        ]
        for field in SortField.allCases {
            let stub = StubHTTPClient()
            stub.stub(pathSuffix: "/Users/u1/Items", json: #"{"Items":[],"TotalRecordCount":0}"#)
            let provider = JellyfinProvider(session: makeSession(), http: stub)

            _ = try await provider.items(
                in: "lib1",
                kind: .movie,
                page: PageRequest(sort: CoreModels.SortDescriptor(field: field, direction: .ascending))
            )

            let query = try XCTUnwrap(stub.queryItems(forPathSuffix: "/Users/u1/Items"))
            XCTAssertEqual(
                query.first(where: { $0.name == "SortBy" })?.value,
                expected[field],
                "SortBy mapping for \(field)"
            )
        }
    }

    func testItemsPageMapsSortDirectionToSortOrder() async throws {
        let expected: [SortDirection: String] = [
            .ascending: "Ascending",
            .descending: "Descending"
        ]
        for direction in SortDirection.allCases {
            let stub = StubHTTPClient()
            stub.stub(pathSuffix: "/Users/u1/Items", json: #"{"Items":[],"TotalRecordCount":0}"#)
            let provider = JellyfinProvider(session: makeSession(), http: stub)

            _ = try await provider.items(
                in: "lib1",
                kind: .movie,
                page: PageRequest(sort: CoreModels.SortDescriptor(field: .releaseDate, direction: direction))
            )

            let query = try XCTUnwrap(stub.queryItems(forPathSuffix: "/Users/u1/Items"))
            XCTAssertEqual(
                query.first(where: { $0.name == "SortOrder" })?.value,
                expected[direction],
                "SortOrder mapping for \(direction)"
            )
            // The chosen field must still be carried alongside the direction.
            XCTAssertEqual(query.first(where: { $0.name == "SortBy" })?.value, "PremiereDate")
        }
    }

    func testSearchSendsExpectedQueryAndMapsResults() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Users/u1/Items", json: """
        {"Items":[
          {"Id":"m1","Name":"Dune","Type":"Movie","ProviderIds":{"Imdb":"tt1160419"}},
          {"Id":"s1","Name":"Dune: Prophecy","Type":"Series","ProviderIds":{"Tmdb":"225634"}}
        ]}
        """)
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        let results = try await provider.search(query: "  dune ", limit: 25)

        XCTAssertEqual(results.map(\.title), ["Dune", "Dune: Prophecy"])
        XCTAssertEqual(results.map(\.kind), [.movie, .series])
        XCTAssertEqual(results[0].providerIDs["Imdb"], "tt1160419")
        XCTAssertEqual(results[1].providerIDs["Tmdb"], "225634")

        let query = try XCTUnwrap(stub.queryItems(forPathSuffix: "/Users/u1/Items"))
        // Whitespace is trimmed before the request is issued.
        XCTAssertEqual(query.first(where: { $0.name == "searchTerm" })?.value, "dune")
        XCTAssertEqual(query.first(where: { $0.name == "Recursive" })?.value, "true")
        XCTAssertEqual(query.first(where: { $0.name == "IncludeItemTypes" })?.value, "Movie,Series,Episode")
        XCTAssertEqual(query.first(where: { $0.name == "Limit" })?.value, "25")
        let fields = query.first(where: { $0.name == "Fields" })?.value ?? ""
        XCTAssertTrue(
            fields.split(separator: ",").contains(where: { $0.lowercased() == "providerids" }),
            "Search requests must include ProviderIds so cross-server de-dup has strong ids"
        )
        XCTAssertEqual(query.first(where: { $0.name == "EnableTotalRecordCount" })?.value, "false")
        XCTAssertEqual(query.first(where: { $0.name == "ImageTypeLimit" })?.value, "1")
    }

    func testSearchMapsOriginalTitleAndRequestsItInFields() async throws {
        // Problem B: a foreign film whose display Name is localised but whose
        // OriginalTitle is the other server's title. The mapping must carry
        // OriginalTitle, and the search request must ask for it.
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Users/u1/Items", json: """
        {"Items":[
          {"Id":"m1","Name":"Turbulencia en la oficina","OriginalTitle":"Office Turbulence","Type":"Movie","ProviderIds":{"Tmdb":"55555"}}
        ]}
        """)
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        let results = try await provider.search(query: "office turbulence", limit: 25)

        XCTAssertEqual(results.first?.title, "Turbulencia en la oficina")
        XCTAssertEqual(results.first?.originalTitle, "Office Turbulence",
                       "Jellyfin OriginalTitle must map to MediaItem.originalTitle")

        let query = try XCTUnwrap(stub.queryItems(forPathSuffix: "/Users/u1/Items"))
        let fields = query.first(where: { $0.name == "Fields" })?.value ?? ""
        XCTAssertTrue(
            fields.split(separator: ",").contains(where: { $0.lowercased() == "originaltitle" }),
            "Search requests must include OriginalTitle so cross-server discovery can query by it"
        )
    }

    func testSearchWithBlankQuerySkipsNetwork() async throws {
        let stub = StubHTTPClient()
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        let results = try await provider.search(query: "   ", limit: 25)

        XCTAssertTrue(results.isEmpty)
        XCTAssertTrue(stub.sentPaths.isEmpty)
    }

    func testItemMapsNativeRatingsAndProviderIDs() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Users/u1/Items/i1", json: """
        {"Id":"i1","Name":"Movie","Type":"Movie","RunTimeTicks":0,
        "CommunityRating":7.2,"CriticRating":74,
        "ProviderIds":{"Imdb":"tt0111161","Tmdb":"278"},
        "UserData":{"PlaybackPositionTicks":0}}
        """)
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        let item = try await provider.item(id: "i1")

        XCTAssertEqual(item.providerIDs["Imdb"], "tt0111161")
        XCTAssertEqual(item.providerIDs["Tmdb"], "278")

        let community = item.ratings.first { $0.source == .tmdb }
        XCTAssertEqual(community?.value, 7.2)
        XCTAssertEqual(community?.scale, .outOfTen)

        let critic = item.ratings.first { $0.source == .rottenTomatoes }
        XCTAssertEqual(critic?.value, 74)
        XCTAssertEqual(critic?.scale, .percent)
    }

    func testItemCommunityRatingMapsToTMDBEvenWithoutTMDBProviderID() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Users/u1/Items/i3", json: """
        {"Id":"i3","Name":"Show","Type":"Series","RunTimeTicks":0,
        "CommunityRating":7.9,
        "ProviderIds":{"Imdb":"tt1234567"},
        "UserData":{"PlaybackPositionTicks":0}}
        """)
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        let item = try await provider.item(id: "i3")

        // The native community score is TMDB-sourced regardless of item type or
        // which provider ids happen to be present, so it always brands as TMDB.
        let tmdb = item.ratings.first { $0.source == .tmdb }
        XCTAssertEqual(tmdb?.value, 7.9)
        XCTAssertEqual(tmdb?.scale, .outOfTen)
        XCTAssertFalse(item.ratings.contains { $0.source == .community })
    }

    func testItemWithoutRatingFieldsHasEmptyRatings() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Users/u1/Items/i2", json: """
        {"Id":"i2","Name":"Movie","Type":"Movie","RunTimeTicks":0,
        "UserData":{"PlaybackPositionTicks":0}}
        """)
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        let item = try await provider.item(id: "i2")
        XCTAssertTrue(item.ratings.isEmpty)
        XCTAssertTrue(item.providerIDs.isEmpty)
    }

    func testPlaybackInfoResolvesDirectStreamWithApiKey() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Users/u1/Items/i1", json: """
        {"Id":"i1","Name":"Movie","Type":"Movie","RunTimeTicks":0,
        "UserData":{"PlaybackPositionTicks":0}}
        """)
        stub.stub(pathSuffix: "/Items/i1/PlaybackInfo", json: """
        {"MediaSources":[{"Id":"src1","ETag":"etag9","Container":"mp4","SupportsDirectPlay":true,
        "MediaStreams":[{"Index":0,"Type":"Video","Codec":"h264","IsInterlaced":true},
        {"Index":1,"Type":"Audio","Language":"eng","DisplayTitle":"English"},
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
        XCTAssertEqual(request.sourceMetadata?.video?.isInterlaced, true)
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

    func testPlaybackInfoParsesTrickplayManifest() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Users/u1/Items/i1", json: """
        {"Id":"i1","Name":"Movie","Type":"Movie","RunTimeTicks":0,
        "Trickplay":{"src1":{"320":{"Width":320,"Height":180,"TileWidth":10,"TileHeight":10,
        "ThumbnailCount":250,"Interval":10000,"Bandwidth":1000}}}}
        """)
        stub.stub(pathSuffix: "/Items/i1/PlaybackInfo", json: """
        {"MediaSources":[{"Id":"src1","Container":"mp4","SupportsDirectPlay":true}],
        "PlaySessionId":"ps1"}
        """)
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        let request = try await provider.playbackInfo(for: "i1")
        let manifest = try XCTUnwrap(request.scrubPreview?.tiledManifest)
        XCTAssertEqual(manifest.thumbnailWidth, 320)
        XCTAssertEqual(manifest.thumbnailHeight, 180)
        XCTAssertEqual(manifest.tileColumns, 10)
        XCTAssertEqual(manifest.tileRows, 10)
        XCTAssertEqual(manifest.thumbnailCount, 250)
        XCTAssertEqual(manifest.intervalMs, 10000)
        // 250 thumbs / 100 per tile -> 3 tiles.
        XCTAssertEqual(manifest.tileURLs.count, 3)
        let first = manifest.tileURLs[0].absoluteString
        XCTAssertTrue(first.contains("/Videos/i1/Trickplay/320/0.jpg"), first)
        XCTAssertTrue(first.contains("api_key=TOKEN"), first)
        XCTAssertTrue(first.contains("mediaSourceId=src1"), first)
    }

    func testPlaybackInfoParsesTrickplayManifestForEpisode() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Users/u1/Items/e1", json: """
        {"Id":"e1","Name":"Episode 1","Type":"Episode","RunTimeTicks":0,
        "Trickplay":{"src1":{"320":{"Width":320,"Height":180,"TileWidth":10,"TileHeight":10,
        "ThumbnailCount":150,"Interval":10000,"Bandwidth":1000}}}}
        """)
        stub.stub(pathSuffix: "/Items/e1/PlaybackInfo", json: """
        {"MediaSources":[{"Id":"src1","Container":"mp4","SupportsDirectPlay":true}],
        "PlaySessionId":"ps-episode"}
        """)
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        let request = try await provider.playbackInfo(for: "e1")
        let manifest = try XCTUnwrap(request.scrubPreview?.tiledManifest)
        XCTAssertEqual(manifest.thumbnailCount, 150)
        XCTAssertTrue(manifest.tileURLs[0].absoluteString.contains("/Videos/e1/Trickplay/320/0.jpg"))
    }

    func testPlaybackInfoTrickplayFallbackUsesManifestSourceID() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Users/u1/Items/i2", json: """
        {"Id":"i2","Name":"Movie","Type":"Movie","RunTimeTicks":0,
        "Trickplay":{"actual-src":{"320":{"Width":320,"Height":180,"TileWidth":10,"TileHeight":10,
        "ThumbnailCount":100,"Interval":10000,"Bandwidth":1000}}}}
        """)
        stub.stub(pathSuffix: "/Items/i2/PlaybackInfo", json: """
        {"MediaSources":[{"Id":"playback-src","Container":"mp4","SupportsDirectPlay":true}],
        "PlaySessionId":"ps1"}
        """)
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        let request = try await provider.playbackInfo(for: "i2")
        let manifest = try XCTUnwrap(request.scrubPreview?.tiledManifest)
        let first = manifest.tileURLs[0].absoluteString
        XCTAssertTrue(first.contains("mediaSourceId=actual-src"), first)
        XCTAssertFalse(first.contains("mediaSourceId=playback-src"), first)
    }

    func testPlaybackInfoTrickplayParsesCompositeWidthKey() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Users/u1/Items/i3", json: """
        {"Id":"i3","Name":"Movie","Type":"Movie","RunTimeTicks":0,
        "Trickplay":{"src1":{"320x180":{"Width":320,"Height":180,"TileWidth":10,"TileHeight":10,
        "ThumbnailCount":100,"Interval":10000,"Bandwidth":1000}}}}
        """)
        stub.stub(pathSuffix: "/Items/i3/PlaybackInfo", json: """
        {"MediaSources":[{"Id":"src1","Container":"mp4","SupportsDirectPlay":true}],
        "PlaySessionId":"ps1"}
        """)
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        let request = try await provider.playbackInfo(for: "i3")
        let manifest = try XCTUnwrap(request.scrubPreview?.tiledManifest)
        XCTAssertEqual(manifest.thumbnailWidth, 320)
        XCTAssertTrue(manifest.tileURLs[0].absoluteString.contains("/Trickplay/320/0.jpg"))
    }

    func testPlaybackInfoHasNoTrickplayWhenServerOmitsIt() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Users/u1/Items/i1", json: """
        {"Id":"i1","Name":"Movie","Type":"Movie","RunTimeTicks":0}
        """)
        stub.stub(pathSuffix: "/Items/i1/PlaybackInfo", json: """
        {"MediaSources":[{"Id":"src1","Container":"mp4","SupportsDirectPlay":true}],
        "PlaySessionId":"ps1"}
        """)
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        let request = try await provider.playbackInfo(for: "i1")
        XCTAssertNil(request.scrubPreview)
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

final class JellyfinRemoteSubtitleTests: XCTestCase {
    private func makeSession() -> UserSession {
        UserSession(
            server: MediaServer(id: "s", name: "Home", baseURL: URL(string: "http://host:8096")!, provider: .jellyfin),
            userID: "u1", userName: "Alice", deviceID: "d1", accessToken: "TOKEN"
        )
    }

    func testRemoteSubtitleSearchMapsResultsAndUsesAlpha3Path() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Items/i1/RemoteSearch/Subtitles/eng", json: """
        [{"Id":"sub-1","Name":"English.srt","ProviderName":"OpenSubtitles",
          "ThreeLetterISOLanguageName":"eng","Format":"srt","CommunityRating":8.5,
          "DownloadCount":1200,"IsForced":false}]
        """)
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        // Pass a 2-letter code; the client must convert it to the 3-letter path.
        let results = try await provider.remoteSubtitleSearch(itemID: "i1", language: "en")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].id, "sub-1")
        XCTAssertEqual(results[0].providerName, "OpenSubtitles")
        XCTAssertEqual(results[0].language, "eng")
        XCTAssertEqual(results[0].communityRating, 8.5)
        XCTAssertEqual(results[0].downloadCount, 1200)
        XCTAssertTrue(stub.sentPaths.contains { $0.hasSuffix("/Items/i1/RemoteSearch/Subtitles/eng") })
    }

    func testDownloadRemoteSubtitlePOSTsToExpectedPath() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Items/i1/RemoteSearch/Subtitles/sub-1", json: "")
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        try await provider.downloadRemoteSubtitle(itemID: "i1", subtitleID: "sub-1")
        XCTAssertTrue(stub.sentPaths.contains { $0.hasSuffix("/Items/i1/RemoteSearch/Subtitles/sub-1") })
    }
}

final class JellyfinWatchStateTests: XCTestCase {
    private func makeSession() -> UserSession {
        UserSession(
            server: MediaServer(id: "s", name: "Home", baseURL: URL(string: "http://host:8096")!, provider: .jellyfin),
            userID: "u1", userName: "Alice", deviceID: "d1", accessToken: "TOKEN"
        )
    }

    func testSetPlayedTruePostsToPlayedItems() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Users/u1/PlayedItems/i1", json: "{}")
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        try await provider.setPlayed(true, itemID: "i1")

        XCTAssertTrue(stub.sentPaths.contains { $0.hasSuffix("/Users/u1/PlayedItems/i1") })
        XCTAssertEqual(stub.method(forPathSuffix: "/Users/u1/PlayedItems/i1"), .post)
    }

    func testSetPlayedFalseDeletesPlayedItems() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Users/u1/PlayedItems/i1", json: "{}")
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        try await provider.setPlayed(false, itemID: "i1")

        XCTAssertEqual(stub.method(forPathSuffix: "/Users/u1/PlayedItems/i1"), .delete)
    }
}

final class JellyfinDeliveryModeTests: XCTestCase {
    func testDirectPlayWhenNoTranscodingUrl() {
        XCTAssertEqual(
            JellyfinProvider.deliveryMode(transcoding: false, didRemux: false),
            .directPlay
        )
    }

    func testRemuxWhenWeRequestedDirectStream() {
        XCTAssertEqual(
            JellyfinProvider.deliveryMode(transcoding: true, didRemux: true),
            .remux
        )
    }

    func testTranscodeWhenServerChoseItWithoutOurRemux() {
        XCTAssertEqual(
            JellyfinProvider.deliveryMode(transcoding: true, didRemux: false),
            .transcode
        )
    }
}

final class JellyfinHvc1RemuxTests: XCTestCase {
    private func source(_ json: String) throws -> MediaSourceInfo {
        try JSONDecoder().decode(MediaSourceInfo.self, from: Data(json.utf8))
    }

    func testHev1HevcInMP4WithAppleAudioRequestsRemux() throws {
        let s = try source(#"""
        {"Container":"mp4","MediaStreams":[
          {"Index":0,"Type":"Video","Codec":"hevc","CodecTag":"hev1"},
          {"Index":1,"Type":"Audio","Codec":"aac","IsDefault":true}]}
        """#)
        XCTAssertTrue(JellyfinProvider.shouldRequestHvc1Remux(s))
    }

    func testHvc1HevcIsNotRemuxed() throws {
        let s = try source(#"""
        {"Container":"mp4","MediaStreams":[
          {"Index":0,"Type":"Video","Codec":"hevc","CodecTag":"hvc1"}]}
        """#)
        XCTAssertFalse(JellyfinProvider.shouldRequestHvc1Remux(s))
    }

    func testHev1InMatroskaIsNotRemuxed() throws {
        // hev1 in MKV routes to the on-device hybrid engine instead.
        let s = try source(#"""
        {"Container":"mkv","MediaStreams":[
          {"Index":0,"Type":"Video","Codec":"hevc","CodecTag":"hev1"}]}
        """#)
        XCTAssertFalse(JellyfinProvider.shouldRequestHvc1Remux(s))
    }

    func testAlreadyTranscodingIsNotRemuxed() throws {
        let s = try source(#"""
        {"Container":"mp4","TranscodingUrl":"/v.m3u8","MediaStreams":[
          {"Index":0,"Type":"Video","Codec":"hevc","CodecTag":"hev1"}]}
        """#)
        XCTAssertFalse(JellyfinProvider.shouldRequestHvc1Remux(s))
    }

    func testHev1WithIncompatibleAudioIsNotRemuxed() throws {
        // DTS can't be stream-copied into fMP4 → forcing the remux would transcode
        // audio, so we leave it for the on-device engine net instead.
        let s = try source(#"""
        {"Container":"mp4","MediaStreams":[
          {"Index":0,"Type":"Video","Codec":"hevc","CodecTag":"hev1"},
          {"Index":1,"Type":"Audio","Codec":"dts","IsDefault":true}]}
        """#)
        XCTAssertFalse(JellyfinProvider.shouldRequestHvc1Remux(s))
    }
}

final class JellyfinRemoteTrailersTests: XCTestCase {
    private func makeSession() -> UserSession {
        UserSession(
            server: MediaServer(id: "s", name: "Home", baseURL: URL(string: "http://host:8096")!, provider: .jellyfin),
            userID: "u1", userName: "Alice", deviceID: "d1", accessToken: "TOKEN"
        )
    }

    func testTrailersMergeLocalAndRemoteYouTube() async throws {
        let stub = StubHTTPClient()
        // Local trailer file (own server item).
        stub.stub(pathSuffix: "/Users/u1/Items/i1/LocalTrailers", json: """
        [{"Id":"local1","Name":"Local Trailer","Type":"Trailer"}]
        """)
        // Server-resolved remote trailer (YouTube watch URL).
        stub.stub(pathSuffix: "/Users/u1/Items/i1", json: """
        {"Id":"i1","Name":"Dune","Type":"Movie",
         "RemoteTrailers":[{"Url":"https://www.youtube.com/watch?v=dQw4w9WgXcQ","Name":"Dune Trailer"}]}
        """)
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        let trailers = try await provider.trailers(for: "i1")
        XCTAssertEqual(trailers.count, 2)

        let local = trailers.first { !$0.isYouTubeTrailer }
        let remote = trailers.first { $0.isYouTubeTrailer }
        XCTAssertEqual(local?.id, "local1")
        XCTAssertEqual(remote?.youTubeTrailerVideoID, "dQw4w9WgXcQ")
    }

    func testTrailersSurviveLocalFailure() async throws {
        let stub = StubHTTPClient()
        // No LocalTrailers stub -> notFound thrown for that path, but remote still works.
        stub.stub(pathSuffix: "/Users/u1/Items/i1", json: """
        {"Id":"i1","Name":"Dune","Type":"Movie",
         "RemoteTrailers":[{"Url":"https://youtu.be/dQw4w9WgXcQ","Name":"Trailer"}]}
        """)
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        let trailers = try await provider.trailers(for: "i1")
        XCTAssertEqual(trailers.count, 1)
        XCTAssertEqual(trailers.first?.youTubeTrailerVideoID, "dQw4w9WgXcQ")
    }

    func testTrailersEmptyWhenNoneAvailable() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Users/u1/Items/i1", json: """
        {"Id":"i1","Name":"Dune","Type":"Movie"}
        """)
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        let trailers = try await provider.trailers(for: "i1")
        XCTAssertTrue(trailers.isEmpty)
    }
}
