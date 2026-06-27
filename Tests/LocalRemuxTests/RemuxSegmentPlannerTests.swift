#if canImport(UIKit)
import XCTest
@testable import LocalRemux

/// Pure-logic tests for the VOD playlist generator — the crux of "the app owns
/// the whole stream so AVPlayer seek-ahead never 404s." Verifies the full-timeline
/// VOD shape (every segment declared up front + `EXT-X-ENDLIST`), the shared
/// `EXT-X-MAP` init segment, and the exact Dolby Vision / E-AC-3 `CODECS` tokens
/// AVPlayer needs to negotiate true DoVi + Atmos.
final class RemuxSegmentPlannerTests: XCTestCase {

    private func planner(
        durations: [Double] = [6, 6, 6, 4.5],
        width: Int = 3840,
        height: Int = 2160,
        profile: Int = 5,
        level: Int = 6,
        eac3: Bool = true,
        bandwidth: Int = 0
    ) -> RemuxSegmentPlanner {
        RemuxSegmentPlanner(
            segmentDurations: durations,
            stream: .init(
                width: width, height: height,
                dolbyVisionProfile: profile, dolbyVisionLevel: level,
                audioIsEAC3: eac3, bandwidth: bandwidth
            )
        )
    }

    // MARK: - CODECS tokens (make-or-break)

    func testVideoCodecToken_Profile5() {
        // P5 has no HDR10 fallback; the dvh1.05.06 brand is what makes AVPlayer
        // render Dolby Vision rather than fall back (and go black).
        XCTAssertEqual(planner(profile: 5, level: 6).videoCodecToken, "dvh1.05.06")
    }

    func testVideoCodecToken_Profile8() {
        XCTAssertEqual(planner(profile: 8, level: 6).videoCodecToken, "dvh1.08.06")
    }

    func testVideoCodecToken_ZeroPadsBothFields() {
        XCTAssertEqual(planner(profile: 8, level: 9).videoCodecToken, "dvh1.08.09")
    }

    func testAudioCodecToken_EAC3() {
        XCTAssertEqual(planner(eac3: true).audioCodecToken, "ec-3")
    }

    func testAudioCodecToken_AC3() {
        XCTAssertEqual(planner(eac3: false).audioCodecToken, "ac-3")
    }

    // MARK: - Master playlist

    func testMasterPlaylistDeclaresDoViVariant() {
        let m = planner(profile: 8, level: 6, eac3: true).masterPlaylist()
        XCTAssertTrue(m.hasPrefix("#EXTM3U"))
        XCTAssertTrue(m.contains("#EXT-X-STREAM-INF:"))
        XCTAssertTrue(m.contains("CODECS=\"dvh1.08.06,ec-3\""))
        XCTAssertTrue(m.contains("RESOLUTION=3840x2160"))
        XCTAssertTrue(m.contains("VIDEO-RANGE=PQ"))
        XCTAssertTrue(m.contains(RemuxSegmentPlanner.mediaName))
    }

    func testMasterPlaylistUsesDeclaredBandwidth() {
        XCTAssertTrue(planner(bandwidth: 42_000_000).masterPlaylist().contains("BANDWIDTH=42000000"))
    }

    func testMasterPlaylistEstimatesBandwidthWhenUnknown() {
        XCTAssertTrue(planner(bandwidth: 0).masterPlaylist().contains("BANDWIDTH=30000000"))
    }

    // MARK: - Media playlist (full-timeline VOD)

    func testMediaPlaylistIsFullTimelineVOD() {
        let p = planner(durations: [6, 6, 6, 4.5])
        let m = p.mediaPlaylist()
        // VOD + ENDLIST = the whole timeline declared up front → seek-ahead can
        // never request an undeclared (404) segment.
        XCTAssertTrue(m.contains("#EXT-X-PLAYLIST-TYPE:VOD"))
        XCTAssertTrue(m.contains("#EXT-X-ENDLIST"))
        XCTAssertTrue(m.contains("#EXT-X-MAP:URI=\"\(RemuxSegmentPlanner.initName)\""))
    }

    func testMediaPlaylistHasOneSegmentPerDuration() {
        let durations = [6.0, 6.0, 6.0, 6.0, 2.25]
        let m = planner(durations: durations).mediaPlaylist()
        let extinf = m.components(separatedBy: "\n").filter { $0.hasPrefix("#EXTINF:") }
        XCTAssertEqual(extinf.count, durations.count)
        for i in durations.indices {
            XCTAssertTrue(m.contains(RemuxSegmentPlanner.segmentName(i)), "missing seg\(i)")
        }
        // No segment beyond the declared count.
        XCTAssertFalse(m.contains(RemuxSegmentPlanner.segmentName(durations.count)))
    }

    func testMediaPlaylistTargetDurationIsCeilOfMax() {
        let m = planner(durations: [6, 6, 5.99, 6.01]).mediaPlaylist()
        XCTAssertTrue(m.contains("#EXT-X-TARGETDURATION:7"))
    }

    func testMediaPlaylistExtinfPrecisionMatchesSegment() {
        let m = planner(durations: [6.123456]).mediaPlaylist()
        XCTAssertTrue(m.contains("#EXTINF:6.123456,"))
    }

    func testTotalDurationSumsSegments() {
        XCTAssertEqual(planner(durations: [6, 6, 6, 4.5]).totalDuration, 22.5, accuracy: 0.0001)
    }

    func testMediaSequenceStartsAtZero() {
        XCTAssertTrue(planner().mediaPlaylist().contains("#EXT-X-MEDIA-SEQUENCE:0"))
    }
}
#endif
