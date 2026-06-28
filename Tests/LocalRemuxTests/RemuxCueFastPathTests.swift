#if canImport(UIKit)
import XCTest
import CRemuxCore

/// Pure-logic tests for the B7 CUE FAST-PATH pre-seed contract. When the Swift
/// provider (Track A) hands `plozz_remux_set_cue_table` the real keyframe times it
/// parsed directly from the container Cues (libav left the title index-less),
/// full-vod engage builds the segment table from those exact boundaries and
/// PRE-SEEDS the entire `resolved_kf[]` ladder so every forward-snap resolve is a
/// cached no-op (zero probe reads, real-keyframe STARTS, exact EXTINF).
///
/// The session-level setter + engage need a live demux, but the load-bearing
/// invariant is purely a function of the supplied cue times: the resolved_kf ladder
/// is `[seg0.start, seg1.start, …, segN-1.start, segN-1.end]`, every interior entry
/// is a real cue keyframe (a subset of the supplied times), the ladder is strictly
/// increasing and contiguous, and the final entry equals the declared timeline end.
/// These tests drive that ladder from the same `plozz_remux_plan_segments` grouping
/// the C consume uses, so a regression in the boundary math is caught without demux.
final class RemuxCueFastPathTests: XCTestCase {

    /// Build the resolved_kf ladder the C consume pre-seeds from a cue table.
    private func resolvedLadder(cues: [Double], duration: Double, cadence: Double,
                                maxOut: Int = 4096) -> [Double] {
        var starts = [Double](repeating: -999, count: maxOut)
        var durs = [Double](repeating: -999, count: maxOut)
        let n = cues.withUnsafeBufferPointer { kf in
            starts.withUnsafeMutableBufferPointer { s in
                durs.withUnsafeMutableBufferPointer { d in
                    Int(plozz_remux_plan_segments(kf.baseAddress, Int32(kf.count),
                                                  duration, cadence,
                                                  s.baseAddress, d.baseAddress,
                                                  Int32(maxOut)))
                }
            }
        }
        guard n > 0 else { return [] }
        var ladder = Array(starts.prefix(n))                       // seg starts
        ladder.append(starts[n - 1] + durs[n - 1])                 // final end edge
        return ladder
    }

    /// The ladder is strictly increasing and contiguous with the segment plan: this
    /// is what makes every `fullvod_resolve_start` a cached no-op.
    func testLadderIsStrictlyIncreasingAndContiguous() {
        let cues = stride(from: 0.0, through: 120.0, by: 2.5).map { $0 }  // 2.5s GOPs
        let ladder = resolvedLadder(cues: cues, duration: 120.0, cadence: 15.0)
        XCTAssertGreaterThan(ladder.count, 1)
        for i in 1..<ladder.count {
            XCTAssertGreaterThan(ladder[i], ladder[i - 1],
                                 "ladder[\(i)] not increasing: \(ladder[i]) <= \(ladder[i-1])")
        }
        XCTAssertEqual(ladder[0], 0.0, accuracy: 1e-6, "B_0 must be the file head")
        XCTAssertEqual(ladder[ladder.count - 1], 120.0, accuracy: 1e-6,
                       "final edge must reach duration")
    }

    /// Every INTERIOR ladder boundary is one of the supplied cue keyframes — the
    /// property that guarantees the muxer's backward-seek lands exactly (no probe).
    /// The first edge (0.0) and the tail end are timeline anchors, not cue subset.
    func testInteriorBoundariesAreRealCueKeyframes() {
        let cues = [0.0, 3.1, 6.7, 9.9, 13.2, 17.8, 21.0, 24.4, 30.0]
        let ladder = resolvedLadder(cues: cues, duration: 30.0, cadence: 6.0)
        XCTAssertGreaterThan(ladder.count, 2)
        // interior edges: ladder[1 ..< count-1] must each be a supplied cue time.
        for i in 1..<(ladder.count - 1) {
            let isCue = cues.contains { abs($0 - ladder[i]) < 1e-6 }
            XCTAssertTrue(isCue, "interior boundary \(ladder[i]) is not a real cue keyframe")
        }
    }

    /// Grouping honors the cadence floor: with a 15s cadence over 2.5s cues, each
    /// resolved span is >= cadence (until the tail), so we publish far fewer, fuller
    /// segments rather than one-per-cue.
    func testCadenceFloorGroupsCues() {
        let cues = stride(from: 0.0, through: 90.0, by: 2.5).map { $0 }
        let ladder = resolvedLadder(cues: cues, duration: 90.0, cadence: 15.0)
        // interior spans (exclude the possibly-short tail).
        for i in 1..<(ladder.count - 1) {
            let span = ladder[i] - ladder[i - 1]
            XCTAssertGreaterThanOrEqual(span, 15.0 - 0.01,
                                        "span \(span) below cadence floor")
        }
    }

    /// A degenerate table (< 2 cues) yields no ladder — the C setter rejects it and
    /// engage falls through to the fixed-cadence path (default-OFF safety).
    func testSingleCueProducesNoLadder() {
        XCTAssertTrue(resolvedLadder(cues: [0.0], duration: 30.0, cadence: 6.0).isEmpty)
        XCTAssertTrue(resolvedLadder(cues: [], duration: 30.0, cadence: 6.0).isEmpty)
    }
}
#endif
