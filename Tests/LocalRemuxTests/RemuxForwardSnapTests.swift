#if canImport(UIKit)
import XCTest
import CRemuxCore

/// Pure-logic tests for `plozz_remux_plan_forward_snap` — the B7 FULL-VOD boundary
/// rule that backs the `com.plozz.playback.remuxFullVod` flag.
///
/// Full-VOD publishes the whole 0->duration fixed-cadence table at open (so the
/// entire scrub bar is seekable instantly — the requirement the windowed lazy EVENT
/// playlist could not meet), then forward-snaps each segment's [start,end) to real
/// keyframes at mux time: segment k = [first_kf>=k*T, first_kf>=(k+1)*T). The
/// invariant proven here without any demux is that, for ANY keyframe layout, the
/// snapped segments are CONTIGUOUS (seg k end == seg k+1 start) and NON-OVERLAPPING
/// — the property that prevents the original A/V-desync (which came from adjacent
/// fixed-cadence segments both BACKWARD-snapping to the same keyframe → duplicated,
/// overlapping media). Every segment start is also a real keyframe, and no segment
/// is ever zero-length even when the GOP is longer than the cadence.
final class RemuxForwardSnapTests: XCTestCase {

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
                    Int(plozz_remux_plan_forward_snap(
                        kf.baseAddress, Int32(kf.count), duration, target,
                        s.baseAddress, d.baseAddress, Int32(maxOut)))
                }
            }
        }
        return Plan(starts: Array(starts.prefix(n)), durations: Array(durs.prefix(n)), count: n)
    }

    /// Every published boundary must coincide with a real keyframe (within eps), or
    /// be the timeline tail `duration`.
    private func assertBoundariesAreKeyframes(_ p: Plan, keyframes: [Double],
                                              duration: Double,
                                              file: StaticString = #filePath, line: UInt = #line) {
        func isKeyframeOrTail(_ t: Double) -> Bool {
            if abs(t - duration) < 1e-6 { return true }
            return keyframes.contains { abs($0 - t) < 1e-6 }
        }
        for i in 0..<p.count {
            XCTAssertTrue(isKeyframeOrTail(p.starts[i]),
                          "seg\(i) start \(p.starts[i]) is not a real keyframe", file: file, line: line)
            let end = p.starts[i] + p.durations[i]
            XCTAssertTrue(isKeyframeOrTail(end),
                          "seg\(i) end \(end) is not a real keyframe/tail", file: file, line: line)
        }
    }

    private func assertContiguousNonOverlapping(_ p: Plan,
                                                file: StaticString = #filePath, line: UInt = #line) {
        for i in 0..<p.count {
            XCTAssertGreaterThan(p.durations[i], 0, "seg\(i) non-positive", file: file, line: line)
        }
        for i in 1..<max(1, p.count) where p.count > 1 {
            let prevEnd = p.starts[i - 1] + p.durations[i - 1]
            XCTAssertEqual(p.starts[i], prevEnd, accuracy: 1e-6,
                           "seg\(i) start != seg\(i-1) end (overlap/gap)", file: file, line: line)
        }
    }

    // MARK: - Core forward-snap behaviour

    func testForwardSnapStartsAtFirstKeyframeAtOrAfterWindow() {
        // Sparse ~12.7s GOPs, cadence 6 → each 6s window snaps FORWARD to the next
        // real keyframe. seg0 starts at kf 0; seg1's window is [6,12) → first kf>=6
        // is 12.76, so seg0 runs [0,12.76) and seg1 starts at 12.76 — contiguous, no
        // backward-snap duplicate (the desync root).
        let kf = [0.0, 12.76, 25.5, 38.2, 51.0]
        let p = plan(keyframes: kf, duration: 60, target: 6)
        assertContiguousNonOverlapping(p)
        assertBoundariesAreKeyframes(p, keyframes: kf, duration: 60)
        XCTAssertEqual(p.starts[0], 0, accuracy: 1e-6)
        XCTAssertEqual(p.starts[1], 12.76, accuracy: 1e-6)
    }

    func testNoOverlapWhenGopMatchesCadence() {
        // Keyframes exactly on the cadence grid → forward-snap is the identity and the
        // table is the trivial 6s grid, still contiguous + non-overlapping.
        let kf = [0.0, 6, 12, 18, 24, 30]
        let p = plan(keyframes: kf, duration: 36, target: 6)
        assertContiguousNonOverlapping(p)
        assertBoundariesAreKeyframes(p, keyframes: kf, duration: 36)
        XCTAssertEqual(p.durations.reduce(0, +), 36, accuracy: 1e-6)
    }

    func testTimelineSumsToFullDuration() {
        // The published timeline must cover the WHOLE file (0->duration) so the entire
        // scrub bar is seekable — the headline full-VOD property.
        let kf = [0.0, 11.4, 24.2, 37.0, 49.5, 61.1]
        let duration = 70.0
        let p = plan(keyframes: kf, duration: duration, target: 6)
        assertContiguousNonOverlapping(p)
        XCTAssertEqual(p.starts.first!, 0, accuracy: 1e-6)
        XCTAssertEqual(p.starts.last! + p.durations.last!, duration, accuracy: 1e-6)
        XCTAssertEqual(p.durations.reduce(0, +), duration, accuracy: 1e-6)
    }

    // MARK: - Degenerate windows (GOP longer than cadence)

    func testGopLongerThanCadenceNeverYieldsZeroLengthSegment() {
        // 20s GOPs with a 6s cadence: several 6s windows contain NO keyframe. Each must
        // still resolve to a positive-length segment (advance to the next keyframe),
        // never a zero-length entry that would 404/empty at mux time.
        let kf = [0.0, 20.0, 40.0, 60.0]
        let p = plan(keyframes: kf, duration: 80, target: 6)
        assertContiguousNonOverlapping(p)
        assertBoundariesAreKeyframes(p, keyframes: kf, duration: 80)
        // Distinct starts are exactly the real keyframes (no spurious boundaries).
        let uniqueStarts = Set(p.starts.map { ($0 * 1000).rounded() })
        XCTAssertEqual(uniqueStarts, Set([0.0, 20.0, 40.0, 60.0].map { ($0 * 1000).rounded() }))
    }

    func testLastWindowRunsToDurationTail() {
        // The final window always ends at `duration`, even when the last keyframe is
        // well before EOF, so the timeline tail is covered.
        let kf = [0.0, 12.0, 24.0]
        let p = plan(keyframes: kf, duration: 40, target: 6)
        assertContiguousNonOverlapping(p)
        XCTAssertEqual(p.starts.last! + p.durations.last!, 40, accuracy: 1e-6)
    }

    // MARK: - Degenerate inputs

    func testZeroDurationYieldsNothing() {
        XCTAssertEqual(plan(keyframes: [0, 12], duration: 0, target: 6).count, 0)
    }

    func testEmptyKeyframesYieldsNothing() {
        XCTAssertEqual(plan(keyframes: [], duration: 60, target: 6).count, 0)
    }
}
#endif
