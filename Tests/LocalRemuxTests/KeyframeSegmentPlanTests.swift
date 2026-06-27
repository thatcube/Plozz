#if canImport(UIKit)
import XCTest
import CRemuxCore

/// Pure-logic tests for `plozz_remux_plan_segments_from_keyframes` — the segment
/// planner behind the `com.plozz.playback.remuxKeyframeSegments` fix. When a
/// source has no usable keyframe index the muxer used to fall back to a fixed 6 s
/// cadence whose boundaries don't land on keyframes; long-GOP streams then emit
/// OVERLAPPING segments whose true duration ≠ the declared EXTINF, which desyncs
/// AVPlayer. The fix rescans real keyframes and groups them here so that every
/// segment is keyframe-bounded with its declared duration equal to the real
/// keyframe-to-keyframe delta. These tests drive the grouping math directly.
final class KeyframeSegmentPlanTests: XCTestCase {

    /// Runs the planner over `kf` and returns the produced segments.
    private func plan(_ kf: [Double], target: Double, duration: Double,
                      maxOut: Int? = nil) -> [(start: Double, dur: Double)] {
        let cap = maxOut ?? (kf.count + 1)
        var out = [plozz_remux_segment](repeating: plozz_remux_segment(), count: max(cap, 1))
        let n = kf.withUnsafeBufferPointer { kfp -> Int in
            Int(plozz_remux_plan_segments_from_keyframes(
                kfp.baseAddress, Int32(kf.count), target, duration, &out, Int32(out.count)))
        }
        return (0..<n).map { (out[$0].start_seconds, out[$0].duration_seconds) }
    }

    /// Asserts segments tile [0, expectedEnd] with no gaps or overlaps and that
    /// each declared duration equals the next start minus this start.
    private func assertContiguous(_ segs: [(start: Double, dur: Double)],
                                  expectedEnd: Double, file: StaticString = #filePath,
                                  line: UInt = #line) {
        XCTAssertFalse(segs.isEmpty, "expected at least one segment", file: file, line: line)
        XCTAssertEqual(segs.first!.start, 0.0, accuracy: 1e-6,
                       "timeline must start at 0", file: file, line: line)
        for i in 0..<segs.count {
            XCTAssertGreaterThan(segs[i].dur, 0.0, "segment \(i) has non-positive duration",
                                 file: file, line: line)
            if i + 1 < segs.count {
                XCTAssertEqual(segs[i].start + segs[i].dur, segs[i + 1].start, accuracy: 1e-6,
                               "segment \(i) overlaps/gaps segment \(i + 1)", file: file, line: line)
            }
        }
        XCTAssertEqual(segs.last!.start + segs.last!.dur, expectedEnd, accuracy: 1e-6,
                       "last segment must reach the end", file: file, line: line)
    }

    /// Long GOPs (12 s) exceed the 6 s target: each keyframe gap becomes its own
    /// segment with the TRUE 12 s duration — the exact case fixed-cadence broke.
    func testLongGopOneSegmentPerKeyframe() {
        let segs = plan([0, 12, 24, 36, 48], target: 6, duration: 60)
        XCTAssertEqual(segs.count, 5)
        for s in segs { XCTAssertEqual(s.dur, 12, accuracy: 1e-6) }
        assertContiguous(segs, expectedEnd: 60)
    }

    /// Short GOPs (2 s) are grouped up to the ~6 s target.
    func testShortGopsGroupedToTarget() {
        let segs = plan([0, 2, 4, 6, 8, 10, 12], target: 6, duration: 12)
        XCTAssertEqual(segs.count, 2)
        XCTAssertEqual(segs[0].dur, 6, accuracy: 1e-6)
        XCTAssertEqual(segs[1].dur, 6, accuracy: 1e-6)
        assertContiguous(segs, expectedEnd: 12)
    }

    /// A first keyframe slightly after 0 still anchors the timeline at 0 so the
    /// declared playlist start matches AVPlayer's 0-based expectation.
    func testFirstKeyframeNotAtZeroAnchorsAtZero() {
        let segs = plan([1.0, 13.0, 25.0], target: 6, duration: 30)
        XCTAssertEqual(segs.first!.start, 0.0, accuracy: 1e-6)
        assertContiguous(segs, expectedEnd: 30)
    }

    /// The tail segment runs to the real duration, not the last keyframe.
    func testTailRunsToDuration() {
        let segs = plan([0, 12, 24], target: 6, duration: 30)
        XCTAssertEqual(segs.count, 3)
        XCTAssertEqual(segs.last!.dur, 6, accuracy: 1e-6) // 24 -> 30
        assertContiguous(segs, expectedEnd: 30)
    }

    /// With an unknown duration (<= 0) the tail falls back to the last keyframe.
    func testUnknownDurationUsesLastKeyframe() {
        let segs = plan([0, 12, 24], target: 6, duration: 0)
        XCTAssertEqual(segs.count, 2)
        assertContiguous(segs, expectedEnd: 24)
    }

    /// Fewer than two keyframes can't define a segment.
    func testTooFewKeyframes() {
        XCTAssertTrue(plan([5.0], target: 6, duration: 30).isEmpty)
        XCTAssertTrue(plan([], target: 6, duration: 30).isEmpty)
    }

    /// `max_out` caps how many segments are written (the open-time bound).
    func testMaxOutCap() {
        let segs = plan([0, 12, 24, 36, 48], target: 6, duration: 60, maxOut: 2)
        XCTAssertEqual(segs.count, 2)
    }

    /// Irregular GOP spacing still yields contiguous, real-duration segments.
    func testVariableGopSpacingNoOverlap() {
        let segs = plan([0, 5, 7, 20, 21, 35], target: 6, duration: 40)
        // 0->? : 5-0=5 <6 skip; 7-0=7>=6 emit [0,7]; 20-7=13>=6 emit [7,13];
        // 21-20=1<6; 35-20=15>=6 emit [20,15]; tail 35->40 emit [35,5].
        XCTAssertEqual(segs.map { $0.dur }, [7, 13, 15, 5])
        assertContiguous(segs, expectedEnd: 40)
    }
}
#endif
