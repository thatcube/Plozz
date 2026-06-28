#if canImport(UIKit)
import XCTest
import CRemuxCore

/// Pure-logic tests for the B7 CUE FAST-PATH VERBATIM tiler — the C consume behind
/// `plozz_remux_set_cue_table`. The Swift producer (B5 `CuesVODPlan.boundaryPTS` /
/// Track A) hands the muxer real Cues keyframe boundaries it has ALREADY grouped to
/// the target cadence and oracle-gated (every interior boundary a real keyframe,
/// strictly increasing, the final element the programme end). The C side must tile
/// them VERBATIM — segment i = [b[i], b[i+1]], count-1 segments — without re-grouping
/// (no coarsening / double-group), without forcing a 0 start (so a non-zero resume
/// anchor is preserved), and without appending a tail (the end is already supplied).
/// These drive `plozz_remux_test_build_segments_verbatim` directly so the boundary
/// math is locked without a live demux.
final class RemuxCueFastPathTests: XCTestCase {

    private struct Tiled {
        var starts: [Double]
        var durations: [Double]
        var count: Int
    }

    private func tile(_ boundaries: [Double], maxOut: Int = 4096) -> Tiled {
        var starts = [Double](repeating: -999, count: maxOut)
        var durs = [Double](repeating: -999, count: maxOut)
        let n = boundaries.withUnsafeBufferPointer { b in
            starts.withUnsafeMutableBufferPointer { s in
                durs.withUnsafeMutableBufferPointer { d in
                    Int(plozz_remux_test_build_segments_verbatim(
                        b.baseAddress, Int32(b.count),
                        s.baseAddress, d.baseAddress, Int32(maxOut)))
                }
            }
        }
        return Tiled(starts: Array(starts.prefix(n)),
                     durations: Array(durs.prefix(n)), count: n)
    }

    /// Verbatim: N boundaries -> N-1 segments, each segment exactly [b[i], b[i+1]].
    /// No grouping, no interpolation — the producer's boundaries are authoritative.
    func testTilesBoundariesVerbatim() {
        let b = [0.0, 4.0, 8.1, 12.3, 17.9, 21.0]    // grouped real-kf boundaries
        let t = tile(b)
        XCTAssertEqual(t.count, b.count - 1)
        for i in 0..<t.count {
            XCTAssertEqual(t.starts[i], b[i], accuracy: 1e-9, "seg\(i) start")
            XCTAssertEqual(t.durations[i], b[i + 1] - b[i], accuracy: 1e-9, "seg\(i) dur")
        }
    }

    /// Contiguous + non-overlapping: every segment starts where the previous ended,
    /// and the ladder of starts + final end reconstructs the input boundaries exactly.
    /// This is what guarantees playlist EXTINF == muxed span (no desync).
    func testContiguousAndReconstructsBoundaries() {
        let b = [0.0, 6.0, 12.0, 18.0, 24.0, 30.0]
        let t = tile(b)
        for i in 1..<t.count {
            let prevEnd = t.starts[i - 1] + t.durations[i - 1]
            XCTAssertEqual(t.starts[i], prevEnd, accuracy: 1e-9, "seg\(i) not contiguous")
        }
        var ladder = t.starts
        ladder.append(t.starts[t.count - 1] + t.durations[t.count - 1])
        XCTAssertEqual(ladder.count, b.count)
        for i in 0..<b.count {
            XCTAssertEqual(ladder[i], b[i], accuracy: 1e-9, "ladder[\(i)] != boundary")
        }
    }

    /// A non-zero start anchor (resume into the middle of a title) is PRESERVED, not
    /// forced to 0 — the bug that re-grouping via build_segments_from_keyframes would
    /// introduce (it forces seg_start=0 when kf[0] > 0, fabricating a [0, b0] segment).
    func testNonZeroResumeAnchorPreserved() {
        let b = [45.0, 49.0, 53.5, 60.0]    // resume at 45s
        let t = tile(b)
        XCTAssertEqual(t.count, 3)
        XCTAssertEqual(t.starts[0], 45.0, accuracy: 1e-9,
                       "resume anchor must be preserved, not zeroed")
        XCTAssertEqual(t.durations[0], 4.0, accuracy: 1e-9)
    }

    /// Long-GOP boundaries (already grouped to large spans) tile verbatim with NO cap
    /// or re-split here — span policy lives in the muxer, not the table builder.
    func testLongSpansTileVerbatim() {
        let b = [0.0, 77.0, 232.0, 300.0]
        let t = tile(b)
        XCTAssertEqual(t.count, 3)
        XCTAssertEqual(t.durations[0], 77.0, accuracy: 1e-9)
        XCTAssertEqual(t.durations[1], 155.0, accuracy: 1e-9)
        XCTAssertEqual(t.durations[2], 68.0, accuracy: 1e-9)
    }

    /// Contract violation (non-strictly-increasing boundaries) returns 0 so the consume
    /// falls back to the fixed-cadence path rather than emit a non-contiguous table.
    func testNonIncreasingRejected() {
        XCTAssertEqual(tile([0.0, 6.0, 6.0, 12.0]).count, 0, "equal boundary must reject")
        XCTAssertEqual(tile([0.0, 12.0, 6.0, 18.0]).count, 0, "decreasing must reject")
    }

    /// Degenerate tables (< 2 boundaries) produce no segments — the setter rejects
    /// these and engage falls through to fixed cadence (default-OFF safety).
    func testDegenerateProducesNothing() {
        XCTAssertEqual(tile([0.0]).count, 0)
        XCTAssertEqual(tile([]).count, 0)
    }
}
#endif
