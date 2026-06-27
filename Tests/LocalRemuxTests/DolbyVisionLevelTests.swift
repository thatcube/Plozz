#if canImport(UIKit) && canImport(AVFoundation)
import XCTest
@testable import LocalRemux

/// Tests for the Dolby Vision **level** used in the HLS `CODECS` token. A wrong
/// level (`dvh1.PP.LL`) can make AVPlayer refuse the variant and never render
/// DoVi, so the engine prefers the level libavformat reads from the title's
/// dvcC/dvvC configuration record and only falls back to a resolution heuristic
/// when the record didn't expose one.
final class DolbyVisionLevelTests: XCTestCase {

    func testPrefersProbedLevelOverHeuristic() {
        // A real P8 title may be level 9 even at 4K; the probed value must win so
        // the CODECS attr matches the bitstream rather than the UHD guess (6).
        XCTAssertEqual(
            FullTimelineVODSession.dolbyVisionLevel(probedLevel: 9, width: 3840, height: 2160),
            9
        )
        // ...and at 1080p the probed level still wins over the HD guess (4).
        XCTAssertEqual(
            FullTimelineVODSession.dolbyVisionLevel(probedLevel: 7, width: 1920, height: 1080),
            7
        )
    }

    func testFallsBackToUHDHeuristicWhenUnknown() {
        XCTAssertEqual(
            FullTimelineVODSession.dolbyVisionLevel(probedLevel: 0, width: 3840, height: 2160),
            6
        )
    }

    func testFallsBackToHDHeuristicWhenUnknown() {
        XCTAssertEqual(
            FullTimelineVODSession.dolbyVisionLevel(probedLevel: 0, width: 1920, height: 1080),
            4
        )
    }

    func testProbedLevelFlowsIntoCodecsToken() {
        // End-to-end: a probed P8 level 9 produces the exact dvh1.08.09 token the
        // master playlist advertises.
        let stream = RemuxSegmentPlanner.StreamInfo(
            width: 3840, height: 2160,
            dolbyVisionProfile: 8,
            dolbyVisionLevel: FullTimelineVODSession.dolbyVisionLevel(probedLevel: 9, width: 3840, height: 2160),
            audioIsEAC3: true, bandwidth: 0
        )
        let planner = RemuxSegmentPlanner(segmentDurations: [6], stream: stream)
        XCTAssertEqual(planner.videoCodecToken, "dvh1.08.09")
        XCTAssertTrue(planner.masterPlaylist().contains("CODECS=\"dvh1.08.09,ec-3\""))
    }
}
#endif
