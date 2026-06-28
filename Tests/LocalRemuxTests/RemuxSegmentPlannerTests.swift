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

    func testMediaPlaylistHasNoVariantGateTags() {
        // The media playlist is what we hand AVPlayer directly (NOT the master), so
        // there is no `#EXT-X-STREAM-INF`/`CODECS`/`VIDEO-RANGE` for tvOS AVPlayer to
        // evaluate against the display's momentary capability mid-DoVi-HDMI-handshake
        // — which is what makes it reject the master URL with -1002 before fetching
        // any media. A media playlist has no variant to reject. Guard that property.
        let m = planner(profile: 8, level: 9).mediaPlaylist()
        XCTAssertFalse(m.contains("#EXT-X-STREAM-INF"), "media playlist must not advertise a variant")
        XCTAssertFalse(m.contains("CODECS="), "media playlist must not carry a CODECS gate")
        XCTAssertFalse(m.contains("VIDEO-RANGE"), "media playlist must not carry a VIDEO-RANGE gate")
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

    // MARK: - B7 EVENT (progressive lazy/windowed) media playlist

    func testEventPlaylistWhileIncompleteHasNoEndlist() {
        // While the lazy index is still discovering, the media playlist is an EVENT
        // playlist carrying only the segments found so far — and MUST NOT carry
        // ENDLIST (that would tell AVPlayer the timeline is final and freeze growth).
        let m = planner().mediaPlaylist(durations: [11.4, 12.8], complete: false)
        XCTAssertTrue(m.contains("#EXT-X-PLAYLIST-TYPE:EVENT"))
        XCTAssertFalse(m.contains("#EXT-X-ENDLIST"))
        XCTAssertTrue(m.contains("#EXT-X-MAP:URI=\"\(RemuxSegmentPlanner.initName)\""))
        // Exactly the two discovered segments, with their real spans.
        XCTAssertTrue(m.contains("#EXTINF:11.400000,"))
        XCTAssertTrue(m.contains("#EXTINF:12.800000,"))
        XCTAssertTrue(m.contains(RemuxSegmentPlanner.segmentName(0)))
        XCTAssertTrue(m.contains(RemuxSegmentPlanner.segmentName(1)))
        XCTAssertFalse(m.contains(RemuxSegmentPlanner.segmentName(2)))
    }

    func testEventPlaylistGrowsThenCompletesToVOD() {
        // A later reload carries more segments; once discovery completes the same
        // generator emits the proven VOD form (PLAYLIST-TYPE:VOD + ENDLIST) so
        // far-scrub is instant. Earlier EXTINFs are byte-identical across reloads —
        // the no-desync invariant (published durations never change).
        let p = planner()
        let early = p.mediaPlaylist(durations: [11.4, 12.8], complete: false)
        let later = p.mediaPlaylist(durations: [11.4, 12.8, 12.0, 6.5], complete: true)
        // Prefix stability: the first two EXTINFs are unchanged.
        XCTAssertTrue(later.contains("#EXTINF:11.400000,"))
        XCTAssertTrue(later.contains("#EXTINF:12.800000,"))
        XCTAssertTrue(early.contains("#EXTINF:11.400000,"))
        // Completed form.
        XCTAssertTrue(later.contains("#EXT-X-PLAYLIST-TYPE:VOD"))
        XCTAssertTrue(later.contains("#EXT-X-ENDLIST"))
        XCTAssertTrue(later.contains(RemuxSegmentPlanner.segmentName(3)))
    }

    func testEventPlaylistTargetDurationIsNonDecreasingCeil() {
        // TARGETDURATION must cover the longest known segment and not shrink as the
        // list grows (a decreasing target is an HLS violation AVPlayer can reject).
        let p = planner()
        let early = p.mediaPlaylist(durations: [11.4], complete: false)
        let later = p.mediaPlaylist(durations: [11.4, 12.8], complete: false)
        XCTAssertTrue(early.contains("#EXT-X-TARGETDURATION:12"))
        XCTAssertTrue(later.contains("#EXT-X-TARGETDURATION:13"))
    }
}
#endif
