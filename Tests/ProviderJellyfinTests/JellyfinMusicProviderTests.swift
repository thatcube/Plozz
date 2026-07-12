import XCTest
import CoreModels
import CoreNetworking
@testable import ProviderJellyfin

final class JellyfinMusicProviderTests: XCTestCase {
    private func makeSession() -> UserSession {
        UserSession(
            server: MediaServer(id: "s", name: "Home", baseURL: URL(string: "http://host:8096")!, provider: .jellyfin),
            userID: "u1", userName: "Alice", deviceID: "d1", accessToken: "TOKEN"
        )
    }

    func testMusicLibrariesFilterCollectionType() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Users/u1/Views", json: """
        {"Items":[
          {"Id":"v1","Name":"Movies","Type":"CollectionFolder","CollectionType":"movies"},
          {"Id":"v2","Name":"Tunes","Type":"CollectionFolder","CollectionType":"music"}
        ],"TotalRecordCount":2}
        """)
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        let libraries = try await provider.musicLibraries()
        XCTAssertEqual(libraries.count, 1)
        XCTAssertEqual(libraries[0].id, "v2")
        XCTAssertEqual(libraries[0].title, "Tunes")
    }

    func testAlbumBrowseMapsFields() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Users/u1/Items", json: """
        {"Items":[{"Id":"al1","Name":"Greatest Hits","Type":"MusicAlbum",
          "AlbumArtist":"The Band","ProductionYear":1999,"ChildCount":12,
          "RunTimeTicks":36000000000,"Genres":["Rock"]}],"TotalRecordCount":1}
        """)
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        let page = try await provider.musicItems(in: "", kind: .album, page: PageRequest(startIndex: 0, limit: 50))
        XCTAssertEqual(page.totalCount, 1)
        let album = try XCTUnwrap(page.albums.first)
        XCTAssertEqual(album.id, "al1")
        XCTAssertEqual(album.title, "Greatest Hits")
        XCTAssertEqual(album.artistName, "The Band")
        XCTAssertEqual(album.year, 1999)
        XCTAssertEqual(album.trackCount, 12)
        XCTAssertEqual(album.totalDuration ?? 0, 3600, accuracy: 0.001)
        XCTAssertEqual(album.genres, ["Rock"])
    }

    func testArtistBrowseMapsFields() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Artists", json: """
        {"Items":[{"Id":"ar1","Name":"The Band","Type":"MusicArtist",
          "ChildCount":4,"Genres":["Rock","Folk"]}],"TotalRecordCount":1}
        """)
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        let page = try await provider.musicItems(in: "", kind: .artist, page: PageRequest(startIndex: 0, limit: 50))
        let artist = try XCTUnwrap(page.artists.first)
        XCTAssertEqual(artist.id, "ar1")
        XCTAssertEqual(artist.name, "The Band")
        XCTAssertEqual(artist.albumCount, 4)
        XCTAssertEqual(artist.genres, ["Rock", "Folk"])
    }

    func testTrackMappingFromAlbumChildren() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Users/u1/Items", json: """
        {"Items":[{"Id":"t1","Name":"Opening","Type":"Audio","Album":"Greatest Hits",
          "AlbumId":"al1","Artists":["The Band"],"IndexNumber":1,"ParentIndexNumber":1,
          "RunTimeTicks":1870000000}],"TotalRecordCount":1}
        """)
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        let tracks = try await provider.tracks(in: "al1")
        let track = try XCTUnwrap(tracks.first)
        XCTAssertEqual(track.id, "t1")
        XCTAssertEqual(track.title, "Opening")
        XCTAssertEqual(track.albumTitle, "Greatest Hits")
        XCTAssertEqual(track.albumID, "al1")
        XCTAssertEqual(track.artistName, "The Band")
        XCTAssertEqual(track.trackNumber, 1)
        XCTAssertEqual(track.discNumber, 1)
        XCTAssertEqual(track.duration ?? 0, 187, accuracy: 0.001)
    }

    func testGenreBrowseMapsFields() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/MusicGenres", json: """
        {"Items":[{"Id":"g1","Name":"Jazz","Type":"MusicGenre"}],"TotalRecordCount":1}
        """)
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        let page = try await provider.musicItems(in: "", kind: .genre, page: PageRequest(startIndex: 0, limit: 50))
        XCTAssertEqual(page.genres.first?.name, "Jazz")
    }

    func testAudioPlaybackInfoBuildsUniversalStreamURL() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Users/u1/Items/t1", json: """
        {"Id":"t1","Name":"Opening","Type":"Audio","Album":"Greatest Hits","AlbumId":"al1",
         "Artists":["The Band"],"RunTimeTicks":1870000000}
        """)
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        let request = try await provider.audioPlaybackInfo(for: "t1", queueContext: nil)
        guard case .authenticatedHTTP(let locator) = request.playbackSource else {
            return XCTFail("expected authenticated HTTP audio locator")
        }
        XCTAssertEqual(locator.resource.path, "Audio/t1/universal")
        XCTAssertEqual(locator.purpose, .audioStream)
        XCTAssertEqual(locator.playSessionID, request.playSessionID)
        XCTAssertFalse(
            locator.resource.queryItems.contains {
                $0.name.localizedCaseInsensitiveContains("token")
                    || $0.name.localizedCaseInsensitiveContains("session")
            }
        )
        XCTAssertNil(request.streamURL)
        XCTAssertNotNil(request.playSessionID)
        XCTAssertEqual(request.track.title, "Opening")
        XCTAssertEqual(request.queue.count, 1)
    }
}
