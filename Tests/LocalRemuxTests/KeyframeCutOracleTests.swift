#if canImport(UIKit)
import XCTest
@testable import LocalRemux

/// Pure-logic tests for `KeyframeCutOracle` — the cross-track correctness harness
/// that validates a keyframe TABLE is PTS-correct and an emitted SEGMENT-CUT plan
/// lands every boundary on a real keyframe with a continuous, gapless timeline.
/// No device, no I/O, no libavformat — just the contract math.
final class KeyframeCutOracleTests: XCTestCase {

    private let tol = KeyframeCutOracle.defaultTolerance

    /// Minimal `ByteRangeSource` so the sampler can be constructed for the pure
    /// `cueAtOrBefore` table lookup (which never touches the source).
    private final class EmptySource: ByteRangeSource {
        var totalSize: Int64 { 0 }
        func readRange(at offset: Int64, count: Int) -> Data { Data() }
    }

    // MARK: - (a) Table well-formedness

    func testValidateTable_wellFormedTableHasNoViolations() {
        let times = [0.0, 4.0, 8.0, 12.0, 16.0]
        XCTAssertTrue(KeyframeCutOracle.validateTable(times: times, duration: 18.0).isEmpty)
    }

    func testValidateTable_emptyTableFlagged() {
        let v = KeyframeCutOracle.validateTable(times: [], duration: 10)
        XCTAssertTrue(v.contains { $0.kind == .emptyTable })
    }

    func testValidateTable_nonMonotonicFlagged() {
        let v = KeyframeCutOracle.validateTable(times: [0, 4, 3.5, 8], duration: 10)
        XCTAssertTrue(v.contains { $0.kind == .nonMonotonicTable && $0.index == 2 })
    }

    func testValidateTable_duplicateTimesAreNonMonotonic() {
        let v = KeyframeCutOracle.validateTable(times: [0, 4, 4, 8], duration: 10)
        XCTAssertTrue(v.contains { $0.kind == .nonMonotonicTable && $0.index == 2 })
    }

    func testValidateTable_negativeTimeFlagged() {
        let v = KeyframeCutOracle.validateTable(times: [-1, 0, 4], duration: 10)
        XCTAssertTrue(v.contains { $0.kind == .negativeTime && $0.index == 0 })
    }

    func testValidateTable_timeExceedingDurationFlagged() {
        let v = KeyframeCutOracle.validateTable(times: [0, 4, 11], duration: 10)
        XCTAssertTrue(v.contains { $0.kind == .timeExceedsDuration && $0.index == 2 })
    }

    func testValidateTable_nonFiniteValueFlagged() {
        let v = KeyframeCutOracle.validateTable(times: [0, .nan, 4], duration: 10)
        XCTAssertTrue(v.contains { $0.kind == .nonFiniteValue && $0.index == 1 })
    }

    func testValidateTable_nonPositiveDurationFlagged() {
        let v = KeyframeCutOracle.validateTable(times: [0, 4], duration: 0)
        XCTAssertTrue(v.contains { $0.kind == .nonPositiveDuration })
    }

    func testValidateTable_keyframeAtExactDurationWithinTolerance() {
        // A title whose last keyframe sits exactly on the duration must pass.
        let v = KeyframeCutOracle.validateTable(times: [0, 4, 8], duration: 8.0)
        XCTAssertTrue(v.isEmpty)
    }

    // MARK: - (b) Cut-plan correctness

    func testValidateCutTimes_exactKeyframeBoundariesPass() {
        let kf = [0.0, 4.0, 8.0, 12.0, 16.0]
        let boundaries = [0.0, 4.0, 8.0, 12.0, 16.0, 18.0] // ends at duration, not a kf
        XCTAssertTrue(KeyframeCutOracle.validateCutTimes(boundaries,
                                                         keyframeTimes: kf,
                                                         duration: 18.0).isEmpty)
    }

    func testValidateCutTimes_midGOPBoundaryFlagged() {
        // The historical overlap bug: a fixed-cadence boundary (6) that is NOT a
        // real keyframe (keyframes at 0/4/8/12) → mid-GOP cut.
        let kf = [0.0, 4.0, 8.0, 12.0]
        let boundaries = [0.0, 6.0, 12.0, 14.0]
        let v = KeyframeCutOracle.validateCutTimes(boundaries, keyframeTimes: kf, duration: 14.0)
        XCTAssertTrue(v.contains { $0.kind == .cutOffKeyframe && abs($0.value - 6.0) < tol })
    }

    func testValidateCutTimes_nonPositiveSegmentFlagged() {
        let kf = [0.0, 4.0, 8.0]
        let boundaries = [0.0, 4.0, 4.0, 8.0] // zero-length segment 1→2
        let v = KeyframeCutOracle.validateCutTimes(boundaries, keyframeTimes: kf, duration: 8.0)
        XCTAssertTrue(v.contains { $0.kind == .nonPositiveSegment })
    }

    func testValidateCutTimes_firstBoundaryNotAnchorFlagged() {
        let kf = [2.0, 6.0, 10.0] // anchor is 2.0 (startPTS), not 0
        let boundaries = [0.0, 6.0, 10.0, 12.0]
        let v = KeyframeCutOracle.validateCutTimes(boundaries, keyframeTimes: kf, duration: 12.0)
        XCTAssertTrue(v.contains { $0.kind == .firstCutNotAtAnchor })
    }

    func testValidateCutTimes_anchoredStartPTSPasses() {
        // A title whose first keyframe is a non-zero startPTS: the plan must anchor
        // there, and the same offset propagates through every boundary.
        let kf = [2.0, 6.0, 10.0]
        let boundaries = [2.0, 6.0, 10.0, 12.0]
        XCTAssertTrue(KeyframeCutOracle.validateCutTimes(boundaries,
                                                         keyframeTimes: kf,
                                                         duration: 12.0).isEmpty)
    }

    func testValidateCutTimes_timelineGapFlagged() {
        let kf = [0.0, 4.0, 8.0]
        let boundaries = [0.0, 4.0, 8.0] // stops at 8, duration is 18 → gap
        let v = KeyframeCutOracle.validateCutTimes(boundaries, keyframeTimes: kf, duration: 18.0)
        XCTAssertTrue(v.contains { $0.kind == .timelineGap })
    }

    func testValidateCutTimes_toleranceAbsorbsTimecodeScaleRounding() {
        // Boundaries that differ from the keyframe by sub-millisecond rounding (the
        // container timecode-scale round-trip) must still be accepted.
        let kf = [0.0, 4.0, 8.0, 12.0]
        let boundaries = [0.0, 4.0 + 5e-4, 8.0 - 5e-4, 12.0, 14.0]
        XCTAssertTrue(KeyframeCutOracle.validateCutTimes(boundaries,
                                                         keyframeTimes: kf,
                                                         duration: 14.0).isEmpty)
    }

    // MARK: - validateSegmentPlan (the RemuxSegmentPlanner [Double] shape)

    func testValidateSegmentPlan_exactCuesDurationsPass() {
        // segmentDurations as cuesVODPlan() would emit for keyframes 0/4/9/13/18.
        let kf = [0.0, 4.0, 9.0, 13.0, 18.0]
        let durations = [4.0, 5.0, 4.0, 5.0, 2.0] // last 2s tail to duration 20
        let v = KeyframeCutOracle.validateSegmentPlan(segmentDurations: durations,
                                                      startPTS: 0.0,
                                                      keyframeTimes: kf,
                                                      duration: 20.0)
        XCTAssertTrue(v.isEmpty, "\(v)")
    }

    func testValidateSegmentPlan_anchoredAtNonZeroStartPTS() {
        let kf = [2.0, 6.0, 11.0]
        let durations = [4.0, 5.0, 3.0] // 2 → 6 → 11 → 14
        let v = KeyframeCutOracle.validateSegmentPlan(segmentDurations: durations,
                                                      startPTS: 2.0,
                                                      keyframeTimes: kf,
                                                      duration: 14.0)
        XCTAssertTrue(v.isEmpty, "\(v)")
    }

    func testValidateSegmentPlan_fixedCadenceOnLongGOPFlagsMidGOPCuts() {
        // A blind 4s-cadence plan over a long-GOP source (real keyframes only every
        // ~10s) must be REJECTED by the oracle — this is precisely the no-Cues
        // hazard that blind cadence creates and Track A/B6 avoid.
        let kf = [0.0, 10.0, 20.0]
        let durations = [4.0, 4.0, 4.0, 4.0, 4.0, 4.0] // 4,8,12,16,20 cuts
        let v = KeyframeCutOracle.validateSegmentPlan(segmentDurations: durations,
                                                      startPTS: 0.0,
                                                      keyframeTimes: kf,
                                                      duration: 24.0)
        XCTAssertTrue(v.contains { $0.kind == .cutOffKeyframe })
    }

    func testValidateSegmentPlan_emptyDurationsFlagged() {
        let v = KeyframeCutOracle.validateSegmentPlan(segmentDurations: [],
                                                      startPTS: 0,
                                                      keyframeTimes: [0],
                                                      duration: 10)
        XCTAssertTrue(v.contains { $0.kind == .nonPositiveSegment })
    }

    // MARK: - Structural plan well-formedness (validatePlanWellFormed)

    func testValidatePlanWellFormed_exactDurationSumPasses() {
        // Sums exactly to total (the seek-bar / ENDLIST invariant).
        let v = KeyframeCutOracle.validatePlanWellFormed(segmentDurations: [6, 6, 7, 5],
                                                         totalDuration: 24)
        XCTAssertTrue(v.isEmpty, "\(v)")
    }

    func testValidatePlanWellFormed_sumMismatchFlagged() {
        let v = KeyframeCutOracle.validatePlanWellFormed(segmentDurations: [6, 6, 6],
                                                         totalDuration: 24) // sums to 18
        XCTAssertTrue(v.contains { $0.kind == .planSumMismatch })
    }

    func testValidatePlanWellFormed_nonPositiveSegmentFlagged() {
        let v = KeyframeCutOracle.validatePlanWellFormed(segmentDurations: [6, 0, 6],
                                                         totalDuration: 12)
        XCTAssertTrue(v.contains { $0.kind == .nonPositiveSegment && $0.index == 1 })
    }

    func testValidatePlanWellFormed_emptyFlagged() {
        let v = KeyframeCutOracle.validatePlanWellFormed(segmentDurations: [],
                                                         totalDuration: 12)
        XCTAssertTrue(v.contains { $0.kind == .emptyTable })
    }

    func testValidatePlanWellFormed_nonFiniteFlagged() {
        let v = KeyframeCutOracle.validatePlanWellFormed(segmentDurations: [6, .nan, 6],
                                                         totalDuration: 18)
        XCTAssertTrue(v.contains { $0.kind == .nonFiniteValue && $0.index == 1 })
    }

    func testValidatePlanWellFormed_targetDurationCeilingTooLowFlagged() {
        // Longest segment 11.4 but TARGETDURATION declared 6 → invalid HLS.
        let v = KeyframeCutOracle.validatePlanWellFormed(segmentDurations: [6, 11.4, 5],
                                                         totalDuration: 22.4,
                                                         targetDurationCeiling: 6)
        XCTAssertTrue(v.contains { $0.kind == .targetDurationTooLow })
    }

    func testValidatePlanWellFormed_acceptsMeasuredCadencePlan_thatKeyframeTierRejects() {
        // THE two-tier point: B7's measured-cadence plan has an ESTIMATED tail that
        // is NOT keyframe-aligned. The structural tier accepts it (well-formed:
        // positive, sums to duration); the keyframe-exact tier MUST reject it
        // (tail cuts aren't real keyframes). Proves validatePlanWellFormed is the
        // right gate for B7's plan and validateCutTimes is not.
        let durations = [6.0, 6, 6, 6, 6, 6, 6, 6, 6, 6] // 60s at fixed 6s cadence
        let total = 60.0
        // Structural tier: well-formed.
        XCTAssertTrue(KeyframeCutOracle.validatePlanWellFormed(segmentDurations: durations,
                                                               totalDuration: total).isEmpty)
        // Keyframe-exact tier with real keyframes only every ~10s → mid-GOP cuts.
        let realKeyframes = [0.0, 10, 20, 30, 40, 50]
        let exact = KeyframeCutOracle.validateSegmentPlan(segmentDurations: durations,
                                                          startPTS: 0,
                                                          keyframeTimes: realKeyframes,
                                                          duration: total)
        XCTAssertTrue(exact.contains { $0.kind == .cutOffKeyframe },
                      "keyframe-exact tier must reject a measured-cadence tail")
    }

    func testValidatePlanWellFormed_harvestsProvisionalVODPlanInvariants() {
        // Harvest: the actual ProvisionalVODPlan output must satisfy the oracle's
        // structural contract (exact-duration sum, positive, valid TARGETDURATION).
        let plan = ProvisionalVODPlan(totalDuration: 8928,
                                      realPrefix: [6, 6, 6, 7.2, 5.1],
                                      targetSeconds: 6)
        let v = KeyframeCutOracle.validatePlanWellFormed(
            segmentDurations: plan.segmentDurations,
            totalDuration: 8928, // the REQUESTED programme duration, not the computed sum
            targetDurationCeiling: plan.targetDurationCeiling)
        XCTAssertTrue(v.isEmpty, "ProvisionalVODPlan must be structurally well-formed: \(v)")
    }

    // MARK: - Differential cross-check

    func testTablesAgree_identicalTablesAgree() {
        XCTAssertTrue(KeyframeCutOracle.tablesAgree([0, 4, 8, 12], [0, 4, 8, 12]))
    }

    func testTablesAgree_subToleranceDifferencesAgree() {
        XCTAssertTrue(KeyframeCutOracle.tablesAgree([0, 4, 8], [0, 4 + 5e-4, 8 - 5e-4]))
    }

    func testTablesAgree_differentCountDisagrees() {
        XCTAssertFalse(KeyframeCutOracle.tablesAgree([0, 4, 8], [0, 4, 8, 12]))
    }

    func testTablesAgree_aboveToleranceDisagrees() {
        XCTAssertFalse(KeyframeCutOracle.tablesAgree([0, 4, 8], [0, 4.5, 8]))
    }

    func testBoundariesAgree_withinAndBeyondTolerance() {
        XCTAssertTrue(KeyframeCutOracle.boundariesAgree(12.0, 12.0 + 5e-4))
        XCTAssertFalse(KeyframeCutOracle.boundariesAgree(12.0, 12.4))
        XCTAssertFalse(KeyframeCutOracle.boundariesAgree(12.0, .nan))
    }

    // MARK: - isOnKeyframe helper

    func testIsOnKeyframe_membershipAndAbsence() {
        let kf = [0.0, 4.0, 8.0, 12.0, 16.0]
        XCTAssertTrue(KeyframeCutOracle.isOnKeyframe(8.0, in: kf))
        XCTAssertTrue(KeyframeCutOracle.isOnKeyframe(8.0 + 5e-4, in: kf))
        XCTAssertFalse(KeyframeCutOracle.isOnKeyframe(6.0, in: kf))
        XCTAssertFalse(KeyframeCutOracle.isOnKeyframe(8.0, in: []))
    }

    // MARK: - Oracle agrees with the real cueAtOrBefore resolver

    func testOracle_acceptsCueAtOrBeforeResolvedBoundary() {
        // A far-seek resolved by cueAtOrBefore MUST land on a real keyframe — feed
        // its result back through isOnKeyframe to prove the resolver honours the
        // oracle's contract.
        let sampler = MatroskaKeyframeSampler(source: EmptySource())
        let points = [
            MatroskaKeyframeSampler.CuePoint(seconds: 0.0, clusterOffset: 0),
            MatroskaKeyframeSampler.CuePoint(seconds: 4.0, clusterOffset: 100),
            MatroskaKeyframeSampler.CuePoint(seconds: 9.0, clusterOffset: 200),
            MatroskaKeyframeSampler.CuePoint(seconds: 13.0, clusterOffset: 300),
        ]
        let kfTimes = points.map { $0.seconds }
        // Seek targets mid-GOP; the resolver must snap back to a real keyframe.
        for target in [1.5, 5.0, 8.999, 12.0, 99.0] {
            guard let resolved = sampler.cueAtOrBefore(target, in: points) else {
                XCTFail("resolver returned nil for \(target)"); continue
            }
            XCTAssertTrue(KeyframeCutOracle.isOnKeyframe(resolved.seconds, in: kfTimes),
                          "cueAtOrBefore(\(target)) → \(resolved.seconds) is not a real keyframe")
            XCTAssertLessThanOrEqual(resolved.seconds, target + tol,
                                     "cueAtOrBefore must not overshoot the target")
        }
    }
}
#endif
