#if canImport(UIKit)
import XCTest
import CRemuxCore

/// Pure-logic tests for `plozz_remux_plan_segments` — the segment-grouping
/// invariant behind the `com.plozz.playback.remuxKeyframeScan` fix. For sources
/// with no usable keyframe index, the open-time table falls back to a FIXED 6s
/// cadence whose declared EXTINF does NOT match what `-c copy` actually muxes
/// (real spans ~12s median, with consecutive segments OVERLAPPING), which AVPlayer
/// reads as progressive A/V desync + stutter. The fix discovers the file's REAL
/// keyframe times and groups them with this function so every boundary is a real
/// keyframe and each EXTINF equals the true keyframe-to-keyframe span. These tests
/// drive the grouping with synthetic keyframe lists (no demux) and assert the
/// pass condition: contiguous, non-overlapping segments whose durations sum to the
/// timeline and equal the real spans.
final class RemuxKeyframePlanTests: XCTestCase {

    private struct Plan {
        var starts: [Double]
        var durations: [Double]
        var count: Int
    }

    private func plan(keyframes: [Double], duration: Double, target: Double,
                      maxOut: Int = 4096) -> Plan {
        var starts = [Double](repeating: -999, count: maxOut)
        var durs = [Double](repeating: -999, count: maxOut)
        let n = keyframes.withUnsafeBufferPointer { kf in
            starts.withUnsafeMutableBufferPointer { s in
                durs.withUnsafeMutableBufferPointer { d in
                    Int(plozz_remux_plan_segments(kf.baseAddress, Int32(kf.count),
                                                  duration, target,
                                                  s.baseAddress, d.baseAddress,
                                                  Int32(maxOut)))
                }
            }
        }
        return Plan(starts: Array(starts.prefix(n)), durations: Array(durs.prefix(n)), count: n)
    }

    // MARK: - Core invariants (the pass condition)

    /// Boundaries are contiguous and non-overlapping: every segment starts exactly
    /// where the previous ended. This is the property whose violation (overlap) is
    /// the bug — seg0 v[0→11.4] / seg1 v[1.0→14.4] in the captured telemetry.
    private func assertContiguousNonOverlapping(_ p: Plan, file: StaticString = #filePath,
                                                line: UInt = #line) {
        for i in 1..<p.count {
            let prevEnd = p.starts[i - 1] + p.durations[i - 1]
            XCTAssertEqual(p.starts[i], prevEnd, accuracy: 1e-6,
                           "seg\(i) start \(p.starts[i]) != seg\(i-1) end \(prevEnd)",
                           file: file, line: line)
        }
        for i in 0..<p.count {
            XCTAssertGreaterThan(p.durations[i], 0, "seg\(i) non-positive duration",
                                 file: file, line: line)
        }
    }

    func testKeyframesEverySixSecondsAreOnePerSegment() {
        // Dense keyframes exactly at the target → each segment is one GOP, EXTINF=6.
        let kf = [0.0, 6, 12, 18, 24]
        let p = plan(keyframes: kf, duration: 30, target: 6)
        XCTAssertEqual(p.count, 5)
        assertContiguousNonOverlapping(p)
        for d in p.durations.prefix(4) { XCTAssertEqual(d, 6, accuracy: 1e-6) }
        XCTAssertEqual(p.durations.last!, 6, accuracy: 1e-6) // tail 24→30
    }

    func testSparseKeyframesGroupToRealSpansNotSixSeconds() {
        // Keyframes ~12.7s apart (the captured median). The plan must declare the
        // REAL ~12.7s spans, never a fictitious uniform 6s — that mismatch is the bug.
        let kf = [0.0, 12.76, 25.5, 38.1]
        let p = plan(keyframes: kf, duration: 50, target: 6)
        assertContiguousNonOverlapping(p)
        XCTAssertEqual(p.starts.first!, 0, accuracy: 1e-6)
        XCTAssertEqual(p.durations[0], 12.76, accuracy: 1e-6)
        XCTAssertEqual(p.durations[1], 25.5 - 12.76, accuracy: 1e-6)
        // Total spans the whole timeline.
        XCTAssertEqual(p.durations.reduce(0, +), 50, accuracy: 1e-6)
    }

    func testDurationsSumToTimeline() {
        let kf = [0.0, 4, 9, 15, 21, 27]
        let p = plan(keyframes: kf, duration: 33.5, target: 6)
        assertContiguousNonOverlapping(p)
        XCTAssertEqual(p.durations.reduce(0, +), 33.5, accuracy: 1e-6)
        XCTAssertEqual(p.starts.first!, 0, accuracy: 1e-6)
    }

    func testGroupingMergesKeyframesShorterThanTarget() {
        // Keyframes denser than the target (2s apart) must be MERGED so no segment
        // is shorter than ~target, but every boundary is still a real keyframe.
        let kf = [0.0, 2, 4, 6, 8, 10, 12]
        let p = plan(keyframes: kf, duration: 12, target: 6)
        assertContiguousNonOverlapping(p)
        // First boundary that reaches >=6 from 0 is the kf at 6.
        XCTAssertEqual(p.starts[0], 0, accuracy: 1e-6)
        XCTAssertEqual(p.durations[0], 6, accuracy: 1e-6)
        for s in p.starts { XCTAssertTrue(kf.contains { abs($0 - s) < 1e-6 } || s == 0) }
    }

    // MARK: - Tail / edge handling

    func testTailRunsToDurationBeyondLastKeyframe() {
        // A long tail with no further keyframe still produces a final segment that
        // starts on the last real keyframe and runs to the file end.
        let kf = [0.0, 6, 12]
        let p = plan(keyframes: kf, duration: 20, target: 6)
        assertContiguousNonOverlapping(p)
        XCTAssertEqual(p.starts.last! + p.durations.last!, 20, accuracy: 1e-6)
        XCTAssertEqual(p.starts.last!, 12, accuracy: 1e-6)
    }

    func testDurationUnknownUsesLastKeyframeAsEnd() {
        // duration <= last keyframe (e.g. unknown/0): the tail ends at the last kf.
        let kf = [0.0, 6, 12, 18]
        let p = plan(keyframes: kf, duration: 0, target: 6)
        assertContiguousNonOverlapping(p)
        XCTAssertEqual(p.starts.last! + p.durations.last!, 18, accuracy: 1e-6)
    }

    func testFirstSegmentStartsAtTimelineOrigin() {
        // A nonzero first keyframe is normalized to 0 so the playlist timeline is
        // 0-based (matches the muxer's 0-based shift).
        let kf = [0.5, 6.5, 12.5]
        let p = plan(keyframes: kf, duration: 18, target: 6)
        XCTAssertEqual(p.starts.first!, 0, accuracy: 1e-6)
        assertContiguousNonOverlapping(p)
    }

    // MARK: - Degenerate inputs

    func testSingleKeyframeYieldsNoSegments() {
        let p = plan(keyframes: [0.0], duration: 12, target: 6)
        XCTAssertEqual(p.count, 0)
    }

    func testEmptyKeyframesYieldsNoSegments() {
        let p = plan(keyframes: [], duration: 12, target: 6)
        XCTAssertEqual(p.count, 0)
    }
}
#endif
