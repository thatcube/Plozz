import XCTest
@testable import CoreModels

/// Tests for the additive, non-breaking music scaffold (`MusicModels`,
/// `MusicProvider`, `ProviderCapability`). These prove the new types compile and
/// that capability detection (which gates all music UI) works, without touching
/// the existing `MediaProvider` contract.
final class MusicScaffoldTests: XCTestCase {

    // MARK: Value types

    func testTrackSubtitleComposesArtistAndAlbum() {
        let both = MusicTrack(id: "1", title: "Song", albumTitle: "LP", artistName: "Band")
        XCTAssertEqual(both.subtitle, "Band · LP")

        let artistOnly = MusicTrack(id: "2", title: "Song", artistName: "Band")
        XCTAssertEqual(artistOnly.subtitle, "Band")

        let albumOnly = MusicTrack(id: "3", title: "Song", albumTitle: "LP")
        XCTAssertEqual(albumOnly.subtitle, "LP")

        let neither = MusicTrack(id: "4", title: "Song")
        XCTAssertNil(neither.subtitle)
    }

    func testTaggingSourceStampsAccountIDAcrossMusicTypes() {
        XCTAssertEqual(MusicArtist(id: "a", name: "A").taggingSource("acct").sourceAccountID, "acct")
        XCTAssertEqual(MusicAlbum(id: "b", title: "B").taggingSource("acct").sourceAccountID, "acct")
        XCTAssertEqual(MusicTrack(id: "c", title: "C").taggingSource("acct").sourceAccountID, "acct")
        XCTAssertEqual(MusicPlaylist(id: "d", title: "D").taggingSource("acct").sourceAccountID, "acct")
        XCTAssertEqual(MusicGenre(id: "e", name: "E").taggingSource("acct").sourceAccountID, "acct")
    }

    func testMusicTypesRoundTripThroughCodable() throws {
        let album = MusicAlbum(
            id: "1", title: "Album", artistName: "Artist", year: 2001,
            trackCount: 12, totalDuration: 2400, genres: ["Rock"]
        )
        let data = try JSONEncoder().encode(album)
        let decoded = try JSONDecoder().decode(MusicAlbum.self, from: data)
        XCTAssertEqual(decoded, album)
    }

    // MARK: MusicPage paging math

    func testMusicPageCountAndPaging() {
        let page = MusicPage(
            albums: [MusicAlbum(id: "1", title: "A"), MusicAlbum(id: "2", title: "B")],
            startIndex: 0,
            totalCount: 5
        )
        XCTAssertEqual(page.count, 2)
        XCTAssertEqual(page.endIndex, 2)
        XCTAssertTrue(page.hasMore)

        let lastPage = MusicPage(
            albums: [MusicAlbum(id: "5", title: "E")],
            startIndex: 4,
            totalCount: 5
        )
        XCTAssertEqual(lastPage.endIndex, 5)
        XCTAssertFalse(lastPage.hasMore)
    }

    // MARK: AudioPlaybackRequest queue defaults

    func testAudioPlaybackRequestDefaultsToSingleTrackQueue() {
        let track = MusicTrack(id: "t1", title: "Solo")
        let request = AudioPlaybackRequest(
            track: track,
            playbackSource: .publicURL(
                try! SecretFreeURLSource(
                    url: URL(string: "https://x/a.mp3")!
                )
            )
        )
        XCTAssertEqual(request.queue, [track])
        XCTAssertEqual(request.queueIndex, 0)
        XCTAssertEqual(request.streamURL, URL(string: "https://x/a.mp3"))
    }

    // MARK: Capability detection (gates music UI)

    func testProviderCapabilityOptionSet() {
        let caps: ProviderCapability = [.video, .music]
        XCTAssertTrue(caps.contains(.music))
        XCTAssertTrue(caps.contains(.video))
        XCTAssertFalse(ProviderCapability.videoOnly.contains(.music))
    }

    func testMusicProviderConformerIsDetectedAsMusicCapable() {
        let providers: [Any] = [StubVideoOnly(), StubMusicCapable()]
        XCTAssertTrue(providers.advertisesCapability(.music))

        let videoOnly: [Any] = [StubVideoOnly()]
        XCTAssertFalse(videoOnly.advertisesCapability(.music))
    }

    func testCapabilityReportingDefaultsToVideoOnly() {
        XCTAssertEqual(StubVideoOnly().capabilities, .videoOnly)
    }
}

// MARK: - Test doubles

private struct StubVideoOnly: CapabilityReporting {}

private struct StubMusicCapable: MusicProvider {
    func musicLibraries() async throws -> [MediaLibrary] { [] }
    func musicItems(in containerID: String, kind: MusicItemKind, page: PageRequest) async throws -> MusicPage {
        MusicPage()
    }
    func audioPlaybackInfo(for trackID: String, queueContext: [String]?) async throws -> AudioPlaybackRequest {
        AudioPlaybackRequest(
            track: MusicTrack(id: trackID, title: ""),
            playbackSource: .publicURL(
                try SecretFreeURLSource(
                    url: URL(string: "https://x/a.mp3")!
                )
            )
        )
    }
    // artist/album/tracks/musicImageURL intentionally rely on the protocol's
    // default implementations, proving incremental conformance compiles.
}
