#if canImport(UIKit) && canImport(AVFoundation)
import XCTest
@testable import LocalRemux

/// Tests for the Dolby Vision **level** used in the HLS `CODECS` token. A wrong
/// level (`dvh1.PP.LL`) can make AVPlayer refuse the variant and never render
/// DoVi, so the engine prefers the level libavformat reads from the title's
/// dvcC/dvvC configuration record and only falls back to a luma-rate (W×H×fps)
/// estimate when the record didn't expose one.
final class DolbyVisionLevelTests: XCTestCase {

    // MARK: Probed level is authoritative (and matches the emitted dvcC box)

    func testPrefersProbedLevelOverEstimate() {
        // A real P8 title may be level 9 even at 4K24; the probed value must win so
        // the CODECS attr matches the bitstream (and the copied dvcC box) rather
        // than the rate-derived estimate.
        XCTAssertEqual(
            FullTimelineVODSession.dolbyVisionLevel(probedLevel: 9, width: 3840, height: 2160, frameRate: 23.976),
            9
        )
        XCTAssertEqual(
            FullTimelineVODSession.dolbyVisionLevel(probedLevel: 7, width: 1920, height: 1080, frameRate: 24),
            7
        )
    }

    // MARK: Fallback estimate from the luma sample rate (W×H×fps)

    func test1080pLevelsByFrameRate() {
        XCTAssertEqual(FullTimelineVODSession.estimatedDolbyVisionLevel(width: 1920, height: 1080, frameRate: 23.976), 3)
        XCTAssertEqual(FullTimelineVODSession.estimatedDolbyVisionLevel(width: 1920, height: 1080, frameRate: 24), 3)
        XCTAssertEqual(FullTimelineVODSession.estimatedDolbyVisionLevel(width: 1920, height: 1080, frameRate: 30), 4)
        XCTAssertEqual(FullTimelineVODSession.estimatedDolbyVisionLevel(width: 1920, height: 1080, frameRate: 60), 5)
    }

    func test4KLevelsByFrameRate() {
        XCTAssertEqual(FullTimelineVODSession.estimatedDolbyVisionLevel(width: 3840, height: 2160, frameRate: 23.976), 6)
        XCTAssertEqual(FullTimelineVODSession.estimatedDolbyVisionLevel(width: 3840, height: 2160, frameRate: 24), 6)
        // The two the resolution-only guess got wrong:
        XCTAssertEqual(FullTimelineVODSession.estimatedDolbyVisionLevel(width: 3840, height: 2160, frameRate: 29.97), 7)
        XCTAssertEqual(FullTimelineVODSession.estimatedDolbyVisionLevel(width: 3840, height: 2160, frameRate: 30), 7)
        XCTAssertEqual(FullTimelineVODSession.estimatedDolbyVisionLevel(width: 3840, height: 2160, frameRate: 48), 8)
        XCTAssertEqual(FullTimelineVODSession.estimatedDolbyVisionLevel(width: 3840, height: 2160, frameRate: 59.94), 9)
        XCTAssertEqual(FullTimelineVODSession.estimatedDolbyVisionLevel(width: 3840, height: 2160, frameRate: 60), 9)
    }

    func testUnknownFrameRateFallsBackToResolutionTier() {
        // fps == 0 (provider gave none, probe failed) must not compute a bogus
        // low level — keep the coarse 24p resolution tier.
        XCTAssertEqual(FullTimelineVODSession.estimatedDolbyVisionLevel(width: 3840, height: 2160, frameRate: 0), 6)
        XCTAssertEqual(FullTimelineVODSession.estimatedDolbyVisionLevel(width: 1920, height: 1080, frameRate: 0), 4)
        XCTAssertEqual(FullTimelineVODSession.estimatedDolbyVisionLevel(width: 3840, height: 2160, frameRate: .nan), 6)
    }

    // MARK: End-to-end into the CODECS token

    func testProbedLevelFlowsIntoCodecsToken() {
        let stream = RemuxSegmentPlanner.StreamInfo(
            width: 3840, height: 2160,
            dolbyVisionProfile: 8,
            dolbyVisionLevel: FullTimelineVODSession.dolbyVisionLevel(
                probedLevel: 9, width: 3840, height: 2160, frameRate: 23.976),
            audioIsEAC3: true, bandwidth: 0
        )
        let planner = RemuxSegmentPlanner(segmentDurations: [6], stream: stream)
        XCTAssertEqual(planner.videoCodecToken, "dvh1.08.09")
        XCTAssertTrue(planner.masterPlaylist().contains("CODECS=\"dvh1.08.09,ec-3\""))
    }

    func testEstimated4K60FlowsIntoCodecsToken() {
        // No probed level -> estimate from 4K60 -> .09, end to end.
        let level = FullTimelineVODSession.dolbyVisionLevel(
            probedLevel: 0, width: 3840, height: 2160, frameRate: 60)
        let stream = RemuxSegmentPlanner.StreamInfo(
            width: 3840, height: 2160,
            dolbyVisionProfile: 8,
            dolbyVisionLevel: level,
            audioIsEAC3: true, bandwidth: 0
        )
        let planner = RemuxSegmentPlanner(segmentDurations: [6], stream: stream)
        XCTAssertEqual(planner.videoCodecToken, "dvh1.08.09")
    }
}
#endif
