import XCTest
@testable import CoreModels

final class LocalRemuxPlaylistTests: XCTestCase {
    private func timeline() -> RemuxSegmentTimeline {
        RemuxSegmentTimeline(
            segments: [
                RemuxSegmentPlan(index: 0, startTime: 0, duration: 6, byteStart: 0, byteEnd: 300),
                RemuxSegmentPlan(index: 1, startTime: 6, duration: 6, byteStart: 300, byteEnd: 600),
                RemuxSegmentPlan(index: 2, startTime: 12, duration: 4, byteStart: 600, byteEnd: 800)
            ],
            targetDuration: 6,
            totalDuration: 16
        )
    }

    func testEmitsCompleteVODPlaylist() {
        let playlist = LocalRemuxPlaylistBuilder.makeMediaPlaylist(timeline: timeline())
        let lines = playlist.split(separator: "\n").map(String.init)

        XCTAssertEqual(lines.first, "#EXTM3U")
        XCTAssertTrue(lines.contains("#EXT-X-VERSION:7"))
        XCTAssertTrue(lines.contains("#EXT-X-PLAYLIST-TYPE:VOD"))
        XCTAssertTrue(lines.contains("#EXT-X-INDEPENDENT-SEGMENTS"))
        XCTAssertTrue(lines.contains("#EXT-X-TARGETDURATION:6"))
        XCTAssertTrue(lines.contains("#EXT-X-MAP:URI=\"init.mp4\""))
        XCTAssertEqual(lines.last, "#EXT-X-ENDLIST")
    }

    func testDeclaresEverySegmentUpFront() {
        let playlist = LocalRemuxPlaylistBuilder.makeMediaPlaylist(timeline: timeline())
        let extinfCount = playlist.components(separatedBy: "#EXTINF:").count - 1
        XCTAssertEqual(extinfCount, 3, "the full timeline must be declared so seek-ahead never 404s")
        XCTAssertTrue(playlist.contains("seg0.m4s"))
        XCTAssertTrue(playlist.contains("seg1.m4s"))
        XCTAssertTrue(playlist.contains("seg2.m4s"))
    }

    func testExtinfDurationsAreFormattedToSixDecimals() {
        let playlist = LocalRemuxPlaylistBuilder.makeMediaPlaylist(timeline: timeline())
        XCTAssertTrue(playlist.contains("#EXTINF:6.000000,"))
        XCTAssertTrue(playlist.contains("#EXTINF:4.000000,"))
    }

    func testCustomSegmentURIBuilderIsHonored() {
        let playlist = LocalRemuxPlaylistBuilder.makeMediaPlaylist(
            timeline: timeline(),
            initURI: "https://127.0.0.1:9000/s/init.mp4",
            segmentURI: { "https://127.0.0.1:9000/s/part\($0).m4s" }
        )
        XCTAssertTrue(playlist.contains("#EXT-X-MAP:URI=\"https://127.0.0.1:9000/s/init.mp4\""))
        XCTAssertTrue(playlist.contains("part2.m4s"))
    }
}
