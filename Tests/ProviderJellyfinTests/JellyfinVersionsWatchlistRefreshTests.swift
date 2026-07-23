import XCTest
import CoreModels
import CoreNetworking
@testable import ProviderJellyfin

/// Tests for Feature A (version mapping), B (Favorites-backed watchlist) and
/// C (metadata refresh) on the Jellyfin provider.
final class JellyfinVersionsWatchlistRefreshTests: XCTestCase {
    private func makeSession() -> UserSession {
        UserSession(
            server: MediaServer(id: "s", name: "Home", baseURL: URL(string: "http://host:8096")!, provider: .jellyfin),
            userID: "u1", userName: "Alice", deviceID: "d1", accessToken: "TOKEN"
        )
    }

    // MARK: - Feature A: versions mapping

    func testItemMapsMultipleMediaSourcesToVersions() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Users/u1/Items/i1", json: """
        {"Id":"i1","Name":"Movie","Type":"Movie",
         "UserData":{"IsFavorite":true},
         "MediaSources":[
           {"Id":"src4k","Name":"4K Remux","Path":"/media/Movie.Extended.mkv",
            "Size":42000000000,"Bitrate":80000000,"RunTimeTicks":72000000000,
            "MediaStreams":[
              {"Index":0,"Type":"Video","Codec":"hevc","Width":3840,"Height":2160,"VideoRangeType":"DOVI"},
              {"Index":1,"Type":"Audio","Codec":"truehd","Channels":8,"Profile":"Dolby Atmos"}]},
           {"Id":"src1080","Name":"1080p","Size":9000000000,
            "MediaStreams":[
              {"Index":0,"Type":"Video","Codec":"h264","Width":1920,"Height":1080,"VideoRangeType":"SDR"},
              {"Index":1,"Type":"Audio","Codec":"aac","Channels":2}]}
         ]}
        """)
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        let item = try await provider.item(id: "i1")
        XCTAssertTrue(item.hasMultipleVersions)
        XCTAssertEqual(item.versions.map(\.id), ["src4k", "src1080"])
        XCTAssertTrue(item.isFavorite)

        let uhd = item.versions[0]
        XCTAssertEqual(uhd.height, 2160)
        XCTAssertEqual(uhd.videoCodec, "hevc")
        XCTAssertEqual(uhd.hdrLabel, "Dolby Vision")
        XCTAssertEqual(uhd.audioLabel, "Atmos")
        XCTAssertEqual(uhd.fileName, "Movie.Extended.mkv")
        XCTAssertEqual(uhd.bitrateLabel, "80 Mbps")
        XCTAssertEqual(uhd.duration, 7200)
        XCTAssertTrue(uhd.isDefault)

        let hd = item.versions[1]
        XCTAssertEqual(hd.resolutionLabel, "1080p")
        XCTAssertEqual(hd.videoCodec, "h264")
        XCTAssertFalse(hd.isDefault)
    }

    func testSingleMediaSourceProducesNoVersionPicker() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Users/u1/Items/i2", json: """
        {"Id":"i2","Name":"Solo","Type":"Movie",
         "MediaSources":[{"Id":"only","MediaStreams":[
           {"Index":0,"Type":"Video","Codec":"h264","Height":1080}]}]}
        """)
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        let item = try await provider.item(id: "i2")
        XCTAssertFalse(item.hasMultipleVersions)
        XCTAssertEqual(item.versions, [])
    }

    // MARK: - Feature B: Favorites-backed watchlist

    func testSetWatchlistedPostsFavorite() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Users/u1/FavoriteItems/i1", json: "{}")
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        try await provider.setWatchlisted(true, item: MediaItem(id: "i1", title: "M", kind: .movie))
        XCTAssertEqual(stub.method(forPathSuffix: "/Users/u1/FavoriteItems/i1"), .post)

        try await provider.setWatchlisted(false, item: MediaItem(id: "i1", title: "M", kind: .movie))
        XCTAssertEqual(stub.method(forPathSuffix: "/Users/u1/FavoriteItems/i1"), .delete)
    }

    func testWatchlistFetchesFavoriteItems() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Users/u1/Items", json: """
        {"Items":[{"Id":"f1","Name":"Saved Movie","Type":"Movie","ProviderIds":{"Tmdb":"11"}}],"TotalRecordCount":1}
        """)
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        let saved = try await provider.watchlist()
        XCTAssertEqual(saved.map(\.title), ["Saved Movie"])
        XCTAssertEqual(saved.first?.providerIDs["Tmdb"], "11")
        let query = stub.queryItems(forPathSuffix: "/Users/u1/Items")
        XCTAssertEqual(query?.first { $0.name == "Filters" }?.value, "IsFavorite")
        let fields = query?.first { $0.name == "Fields" }?.value ?? ""
        XCTAssertTrue(
            fields.split(separator: ",").contains(where: { $0.lowercased() == "providerids" }),
            "Favorites requests must include ProviderIds so Home watchlist de-dup can match across servers"
        )
    }

    // MARK: - Feature C: metadata refresh

    func testRefreshMetadataPostsFullRefresh() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Items/i1/Refresh", json: "{}")
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        try await provider.refreshMetadata(itemID: "i1")
        XCTAssertEqual(stub.method(forPathSuffix: "/Items/i1/Refresh"), .post)
        let query = stub.queryItems(forPathSuffix: "/Items/i1/Refresh")
        XCTAssertEqual(query?.first { $0.name == "ReplaceAllMetadata" }?.value, "true")
    }
}
