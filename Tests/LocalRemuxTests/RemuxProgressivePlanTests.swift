#if canImport(UIKit)
import XCTest
import CRemuxCore

/// Pure-logic tests for `plozz_remux_plan_segments_progressive` — the B7
/// lazy/windowed planner that backs the `com.plozz.playback.remuxLazyIndex` flag.
///
/// The lazy index discovers real keyframe boundaries PROGRESSIVELY (only the first
/// window at open, the rest in the background) and serves a growing EVENT→VOD
/// playlist. The make-or-break invariant — proven here without any demux — is that
/// while discovery is INCOMPLETE only fully-bracketed (closed) segments are
/// published, so a published `EXTINF` can NEVER change as more keyframes arrive
/// (the original A/V-desync bug was a declared duration that didn't match the muxed
/// span). When COMPLETE the final tail to `duration` is included, yielding the same
/// contiguous, gap-free timeline as the non-progressive planner.
final class RemuxProgressivePlanTests: XCTestCase {

    private struct Plan {
        var starts: [Double]
        var durations: [Double]
        var count: Int
    }

    private func plan(keyframes: [Double], duration: Double, target: Double,
                      complete: Bool, maxOut: Int = 4096) -> Plan {
        var starts = [Double](repeating: -999, count: maxOut)
        var durs = [Double](repeating: -999, count: maxOut)
        let n = keyframes.withUnsafeBufferPointer { kf in
            starts.withUnsafeMutableBufferPointer { s in
                durs.withUnsafeMutableBufferPointer { d in
                    Int(plozz_remux_plan_segments_progressive(
                        kf.baseAddress, Int32(kf.count), duration, target,
                        complete ? 1 : 0, s.baseAddress, d.baseAddress, Int32(maxOut)))
                }
            }
        }
        return Plan(starts: Array(starts.prefix(n)), durations: Array(durs.prefix(n)), count: n)
    }

    private func assertContiguous(_ p: Plan, file: StaticString = #filePath, line: UInt = #line) {
        for i in 1..<max(1, p.count) where p.count > 1 {
            let prevEnd = p.starts[i - 1] + p.durations[i - 1]
            XCTAssertEqual(p.starts[i], prevEnd, accuracy: 1e-6,
                           "seg\(i) start != seg\(i-1) end", file: file, line: line)
        }
        for i in 0..<p.count {
            XCTAssertGreaterThan(p.durations[i], 0, "seg\(i) non-positive", file: file, line: line)
        }
    }

    // MARK: - Incomplete: withhold the still-growing trailing group

    func testIncompleteWithholdsOpenTrailingGroup() {
        // kf discovered so far = [0, 4]: 4s < target 6 → no closed group yet, so the
        // incomplete plan must publish ZERO segments (publishing [0,4] now would
        // force a duration change once kf=9 arrives and the group closes at [0,9]).
        let p = plan(keyframes: [0, 4], duration: 0, target: 6, complete: false)
        XCTAssertEqual(p.count, 0)
    }

    func testIncompletePublishesOnlyClosedGroups() {
        // kf = [0, 12.76, 25.5, 31] target 6. Closed groups: [0,12.76], [12.76,25.5].
        // The trailing remainder 25.5→31 is still open (no later keyframe yet) and is
        // WITHHELD while incomplete. No to-EOF tail is invented either.
        let p = plan(keyframes: [0, 12.76, 25.5, 31], duration: 90, target: 6, complete: false)
        XCTAssertEqual(p.count, 2)
        assertContiguous(p)
        XCTAssertEqual(p.durations[0], 12.76, accuracy: 1e-6)
        XCTAssertEqual(p.durations[1], 25.5 - 12.76, accuracy: 1e-6)
        // Crucially the timeline does NOT run to `duration` while incomplete.
        XCTAssertEqual(p.starts.last! + p.durations.last!, 25.5, accuracy: 1e-6)
    }

    // MARK: - Published EXTINFs never change as discovery grows (no desync)

    func testPublishedDurationsAreStableAsKeyframesArrive() {
        // The same prefix must yield byte-identical early segments at every growth
        // step — the property that lets the EVENT playlist grow without ever
        // rewriting a duration AVPlayer already trusts.
        let step1 = plan(keyframes: [0, 11.4, 24.2], duration: 120, target: 6, complete: false)
        let step2 = plan(keyframes: [0, 11.4, 24.2, 37.0, 49.5], duration: 120, target: 6, complete: false)
        XCTAssertGreaterThanOrEqual(step1.count, 1)
        for i in 0..<step1.count {
            XCTAssertEqual(step1.starts[i], step2.starts[i], accuracy: 1e-6, "start drift at seg\(i)")
            XCTAssertEqual(step1.durations[i], step2.durations[i], accuracy: 1e-6, "dur drift at seg\(i)")
        }
    }

    // MARK: - Complete: include the tail to EOF

    func testCompleteAddsTailToDuration() {
        // Same keyframes, now complete: the trailing remainder + tail to `duration`
        // is included, giving a contiguous timeline that sums to the whole file.
        let kf = [0.0, 12.76, 25.5, 31.0]
        let p = plan(keyframes: kf, duration: 40, target: 6, complete: true)
        assertContiguous(p)
        XCTAssertEqual(p.durations.reduce(0, +), 40, accuracy: 1e-6)
        XCTAssertEqual(p.starts.last! + p.durations.last!, 40, accuracy: 1e-6)
    }

    func testCompleteMatchesNonProgressivePlanner() {
        // With complete == true the progressive planner must produce exactly the
        // same table as the established plozz_remux_plan_segments (include_tail path).
        let kf = [0.0, 6, 13, 19, 27, 33]
        let duration = 40.0, target = 6.0
        let prog = plan(keyframes: kf, duration: duration, target: target, complete: true)

        var s2 = [Double](repeating: -999, count: 4096)
        var d2 = [Double](repeating: -999, count: 4096)
        let n2 = kf.withUnsafeBufferPointer { k in
            s2.withUnsafeMutableBufferPointer { s in
                d2.withUnsafeMutableBufferPointer { d in
                    Int(plozz_remux_plan_segments(k.baseAddress, Int32(k.count),
                        duration, target, s.baseAddress, d.baseAddress, 4096))
                }
            }
        }
        XCTAssertEqual(prog.count, n2)
        for i in 0..<n2 {
            XCTAssertEqual(prog.starts[i], s2[i], accuracy: 1e-6)
            XCTAssertEqual(prog.durations[i], d2[i], accuracy: 1e-6)
        }
    }

    // MARK: - Degenerate inputs

    func testSingleKeyframeYieldsNothing() {
        XCTAssertEqual(plan(keyframes: [0], duration: 12, target: 6, complete: false).count, 0)
        XCTAssertEqual(plan(keyframes: [0], duration: 12, target: 6, complete: true).count, 0)
    }
}
#endif
