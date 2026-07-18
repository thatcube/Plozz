import XCTest
@testable import FeaturePlayback

final class TrailerAudioMuxComposerTests: XCTestCase {
    private func makeComposer(duration: Double = 132.5) -> TrailerAudioMuxComposer {
        TrailerAudioMuxComposer(
            videoURL: URL(string: "https://rr1.googlevideo.com/video?itag=137")!,
            audioURL: URL(string: "https://rr1.googlevideo.com/audio?itag=140")!,
            durationSeconds: duration
        )
    }

    func testMasterPlaylistPairsVideoVariantWithAlternateAudio() {
        let master = makeComposer().masterPlaylist()

        XCTAssertTrue(master.hasPrefix("#EXTM3U"))
        // A single alternate-audio rendition, auto-selected, pointing at the
        // custom-scheme audio media playlist.
        XCTAssertTrue(master.contains(
            "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"Audio\",DEFAULT=YES,AUTOSELECT=YES,URI=\"plozztrailer://mux/audio.m3u8\""
        ))
        // One video variant tied to that audio group.
        XCTAssertTrue(master.contains("#EXT-X-STREAM-INF:BANDWIDTH=8000000,AUDIO=\"aud\""))
        XCTAssertTrue(master.contains("plozztrailer://mux/video.m3u8"))
    }

    func testVideoMediaPlaylistWrapsRealURLAsSingleVODSegment() {
        let video = makeComposer(duration: 90).videoMediaPlaylist()

        XCTAssertTrue(video.contains("#EXT-X-PLAYLIST-TYPE:VOD"))
        XCTAssertTrue(video.contains("#EXT-X-TARGETDURATION:90"))
        XCTAssertTrue(video.contains("#EXTINF:90.000,"))
        // The segment URI is the real https stream, not the custom scheme.
        XCTAssertTrue(video.contains("https://rr1.googlevideo.com/video?itag=137"))
        XCTAssertTrue(video.contains("#EXT-X-ENDLIST"))
    }

    func testAudioMediaPlaylistPointsAtAudioURL() {
        let audio = makeComposer().audioMediaPlaylist()

        XCTAssertTrue(audio.contains("https://rr1.googlevideo.com/audio?itag=140"))
        XCTAssertFalse(audio.contains("itag=137"))
    }

    func testTargetDurationRoundsUp() {
        let video = makeComposer(duration: 132.5).videoMediaPlaylist()
        // Ceil of 132.5 == 133; EXTINF keeps the precise value.
        XCTAssertTrue(video.contains("#EXT-X-TARGETDURATION:133"))
        XCTAssertTrue(video.contains("#EXTINF:132.500,"))
    }
}
