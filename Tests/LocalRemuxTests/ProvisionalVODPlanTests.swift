#if canImport(UIKit)
import XCTest
@testable import LocalRemux

/// Pure-logic tests for `ProvisionalVODPlan` — the full-duration provisional
/// segment table that lets the open playlist be a VOD list with `EXT-X-ENDLIST`
/// (so AVPlayer permits seek-anywhere immediately) instead of the disqualified
/// growing-EVENT shape that clamps far-seek to the discovered frontier.
///
/// The estimation contract these tests pin: the advertised timeline sums EXACTLY
/// to the real duration, the keyframe-exact prefix is preserved verbatim, the
/// tail is fixed-cadence from the measured GOP, and the table is never empty or
/// negative — all the properties AVPlayer's seek-bar mapping depends on.
final class ProvisionalVODPlanTests: XCTestCase {

    private let eps = 1e-6

    // MARK: - Sum == total duration (the seek-bar / end-of-stream invariant)

    func testTotalDurationMatchesExactly_withRealPrefix() {
        let plan = ProvisionalVODPlan(totalDuration: 600,
                                      realPrefix: [6, 6, 7, 5],
                                      targetSeconds: 6)
        XCTAssertEqual(plan.totalDuration, 600, accuracy: eps)
    }

    func testTotalDurationMatchesExactly_noPrefix() {
        let plan = ProvisionalVODPlan(totalDuration: 137.5,
                                      realPrefix: [],
                                      targetSeconds: 6)
        XCTAssertEqual(plan.totalDuration, 137.5, accuracy: eps)
    }

    func testTotalDurationMatchesExactly_nonMultipleOfCadence() {
        // 8928 s (the 2.5h feature) over a 6 s cadence is not an integer count.
        let plan = ProvisionalVODPlan(totalDuration: 8928,
                                      realPrefix: [6, 6, 6],
                                      targetSeconds: 6)
        XCTAssertEqual(plan.totalDuration, 8928, accuracy: 1e-4)
    }

    // MARK: - Prefix preserved verbatim (those segments are keyframe-exact)

    func testRealPrefixPreservedVerbatim() {
        let prefix: [Double] = [5.9, 6.1, 7.3, 4.8]
        let plan = ProvisionalVODPlan(totalDuration: 600,
                                      realPrefix: prefix,
                                      targetSeconds: 6)
        XCTAssertEqual(plan.realPrefixCount, prefix.count)
        XCTAssertEqual(Array(plan.segmentDurations.prefix(prefix.count)), prefix)
    }

    // MARK: - Cadence estimation

    func testCadenceIsMeanOfPrefix_whenAboveTarget() {
        // mean = (8 + 10 + 12) / 3 = 10, above the 6 s target.
        let plan = ProvisionalVODPlan(totalDuration: 1000,
                                      realPrefix: [8, 10, 12],
                                      targetSeconds: 6)
        XCTAssertEqual(plan.cadence, 10, accuracy: eps)
    }

    func testCadenceFlooredAtTarget_whenPrefixShorter() {
        // A few short opening GOPs (mean 2 s) must NOT explode the tail into
        // thousands of 2 s segments — cadence is floored at the 6 s target.
        let plan = ProvisionalVODPlan(totalDuration: 6000,
                                      realPrefix: [2, 2, 2],
                                      targetSeconds: 6)
        XCTAssertEqual(plan.cadence, 6, accuracy: eps)
        // ~ (6000 - 6) / 6 tail segments, NOT (6000 - 6) / 2.
        XCTAssertLessThan(plan.segmentDurations.count, 1010)
    }

    func testCadenceUsesTarget_whenPrefixEmpty() {
        let plan = ProvisionalVODPlan(totalDuration: 60,
                                      realPrefix: [],
                                      targetSeconds: 6)
        XCTAssertEqual(plan.cadence, 6, accuracy: eps)
        XCTAssertEqual(plan.segmentDurations.count, 10)
        XCTAssertTrue(plan.segmentDurations.allSatisfy { abs($0 - 6) < eps })
    }

    // MARK: - Tail shape

    func testSubCadenceRemainderBecomesOneShortSegment() {
        // 6 s prefix + 4 s remaining (< one 6 s cadence) → one 4 s tail segment.
        let plan = ProvisionalVODPlan(totalDuration: 10,
                                      realPrefix: [6],
                                      targetSeconds: 6)
        XCTAssertEqual(plan.segmentDurations.count, 2)
        XCTAssertEqual(plan.segmentDurations[1], 4, accuracy: eps)
    }

    func testExactMultipleHasNoZeroTail() {
        // 30 s over a 6 s cadence = exactly 5 segments, no trailing 0-length seg.
        let plan = ProvisionalVODPlan(totalDuration: 30,
                                      realPrefix: [],
                                      targetSeconds: 6)
        XCTAssertEqual(plan.segmentDurations.count, 5)
        XCTAssertTrue(plan.segmentDurations.allSatisfy { $0 > eps })
    }

    // MARK: - Robustness / never-empty, never-negative

    func testAllSegmentsPositive() {
        let plan = ProvisionalVODPlan(totalDuration: 8928,
                                      realPrefix: [6, 6, 6, 7.2, 5.1],
                                      targetSeconds: 6)
        XCTAssertTrue(plan.segmentDurations.allSatisfy { $0 > eps })
    }

    func testPrefixLongerThanTotal_doesNotEmitNegativeTail() {
        // Bad input: prefix already exceeds the claimed total. Must clamp — no
        // negative or zero segment, just the prefix.
        let plan = ProvisionalVODPlan(totalDuration: 5,
                                      realPrefix: [6, 6],
                                      targetSeconds: 6)
        XCTAssertEqual(plan.segmentDurations, [6, 6])
        XCTAssertTrue(plan.segmentDurations.allSatisfy { $0 > eps })
    }

    func testDegenerateInput_neverEmpty() {
        let plan = ProvisionalVODPlan(totalDuration: 0,
                                      realPrefix: [],
                                      targetSeconds: 6)
        XCTAssertFalse(plan.segmentDurations.isEmpty)
        XCTAssertTrue(plan.segmentDurations.allSatisfy { $0 > eps })
    }

    func testNonFinitePrefixEntriesIgnored() {
        let plan = ProvisionalVODPlan(totalDuration: 60,
                                      realPrefix: [6, .nan, -3, .infinity, 6],
                                      targetSeconds: 6)
        // Only the two valid 6 s entries count as the real prefix.
        XCTAssertEqual(plan.realPrefixCount, 2)
        XCTAssertEqual(plan.totalDuration, 60, accuracy: eps)
        XCTAssertTrue(plan.segmentDurations.allSatisfy { $0.isFinite && $0 > eps })
    }

    // MARK: - segmentStartTime (input to per-segment keyframe resolution)

    func testSegmentStartTimeIsRunningSum() {
        let plan = ProvisionalVODPlan(totalDuration: 100,
                                      realPrefix: [6, 8, 5],
                                      targetSeconds: 6)
        XCTAssertEqual(plan.segmentStartTime(0), 0, accuracy: eps)
        XCTAssertEqual(plan.segmentStartTime(1), 6, accuracy: eps)
        XCTAssertEqual(plan.segmentStartTime(2), 14, accuracy: eps)
        XCTAssertEqual(plan.segmentStartTime(3), 19, accuracy: eps)
    }

    func testSegmentStartTimeClampsOutOfRange() {
        let plan = ProvisionalVODPlan(totalDuration: 30,
                                      realPrefix: [],
                                      targetSeconds: 6)
        // Past the end clamps to the total (never indexes past the array).
        XCTAssertEqual(plan.segmentStartTime(999), 30, accuracy: eps)
        XCTAssertEqual(plan.segmentStartTime(-5), 0, accuracy: eps)
    }

    // MARK: - TARGETDURATION ceiling (HLS requires a constant >= every segment)

    func testTargetDurationCeilingExceedsLongestSegment() {
        let plan = ProvisionalVODPlan(totalDuration: 100,
                                      realPrefix: [6, 11.4, 5],
                                      targetSeconds: 6)
        let longest = plan.segmentDurations.max() ?? 0
        XCTAssertGreaterThanOrEqual(Double(plan.targetDurationCeiling), longest)
    }

    // MARK: - Composition with the existing VOD playlist generator

    func testFeedsRemuxSegmentPlannerAsFullDurationVOD() {
        // The provisional table drops straight into the proven VOD generator,
        // producing a full-timeline playlist WITH ENDLIST (seek-anywhere).
        let plan = ProvisionalVODPlan(totalDuration: 60,
                                      realPrefix: [6, 6],
                                      targetSeconds: 6)
        let planner = RemuxSegmentPlanner(
            segmentDurations: plan.segmentDurations,
            stream: .init(width: 3840, height: 2160, dolbyVisionProfile: 5,
                          dolbyVisionLevel: 6, audioIsEAC3: true, bandwidth: 0))
        let m3u8 = planner.mediaPlaylist()
        XCTAssertTrue(m3u8.contains("#EXT-X-PLAYLIST-TYPE:VOD"))
        XCTAssertTrue(m3u8.contains("#EXT-X-ENDLIST"))
        // 10 segments advertised up front for the whole 60 s timeline.
        XCTAssertEqual(m3u8.components(separatedBy: "#EXTINF:").count - 1, 10)
    }
}
#endif
