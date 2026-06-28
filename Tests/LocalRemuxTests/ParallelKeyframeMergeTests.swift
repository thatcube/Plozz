#if canImport(UIKit)
import XCTest
import Foundation
@testable import LocalRemux

/// Pure-logic tests for `ParallelKeyframeDiscovery.mergeKeyframes` — the merge step of
/// the bounded-parallel keyframe scan (`com.plozz.playback.remuxParallelScan`). Each of
/// K concurrent slices discovers the real keyframe times within its disjoint time range;
/// this function stitches the K arrays back into one sorted, strictly-increasing list
/// (with a t=0 origin) suitable for `plozz_remux_apply_keyframes`. The invariants under
/// test: a single t=0 origin, global ascending order regardless of slice order, the
/// duplicate boundary keyframe that adjacent slices both find at their shared seam is
/// collapsed, out-of-range samples are dropped, and the result is always strictly
/// increasing (so grouping never produces a zero/negative-length segment).
final class ParallelKeyframeMergeTests: XCTestCase {

    private func assertStrictlyIncreasing(_ a: [Double], file: StaticString = #filePath, line: UInt = #line) {
        for i in 1..<a.count {
            XCTAssertGreaterThan(a[i], a[i - 1], "not strictly increasing at \(i): \(a)", file: file, line: line)
        }
    }

    /// Three in-order slices merge into one sorted list with a single 0 origin.
    func testMergesOrderedSlicesWithSingleOrigin() {
        let slices = [[6.0, 12.0, 18.0], [24.0, 30.0, 36.0], [42.0, 48.0]]
        let merged = ParallelKeyframeDiscovery.mergeKeyframes(slices, duration: 60)
        XCTAssertEqual(merged.first, 0.0)
        XCTAssertEqual(merged, [0, 6, 12, 18, 24, 30, 36, 42, 48])
        assertStrictlyIncreasing(merged)
    }

    /// Slice arrays arriving out of order (concurrentPerform completion order is
    /// nondeterministic) still produce a globally sorted result.
    func testSliceOrderIrrelevant() {
        let inOrder = [[6.0, 12.0], [18.0, 24.0], [30.0, 36.0]]
        let shuffled = [[30.0, 36.0], [6.0, 12.0], [18.0, 24.0]]
        XCTAssertEqual(ParallelKeyframeDiscovery.mergeKeyframes(inOrder, duration: 60),
                       ParallelKeyframeDiscovery.mergeKeyframes(shuffled, duration: 60))
    }

    /// Adjacent slices both discover the boundary keyframe at their shared seam; the
    /// near-duplicate is collapsed within epsilon so grouping sees one boundary.
    func testCollapsesSeamDuplicate() {
        // Slice 0 ends at 30.0 (its end-crossing keyframe); slice 1 starts and rediscovers
        // ~the same boundary at 30.02. They must merge to a single entry.
        let slices = [[12.0, 24.0, 30.0], [30.02, 42.0, 54.0]]
        let merged = ParallelKeyframeDiscovery.mergeKeyframes(slices, duration: 60)
        assertStrictlyIncreasing(merged)
        let near30 = merged.filter { abs($0 - 30.0) < 0.1 }
        XCTAssertEqual(near30.count, 1, "seam duplicate not collapsed: \(merged)")
    }

    /// Samples beyond the file duration (a tail slice over-shooting) are dropped.
    func testDropsOutOfRangeSamples() {
        let slices = [[12.0, 24.0], [36.0, 61.0, 80.0]]
        let merged = ParallelKeyframeDiscovery.mergeKeyframes(slices, duration: 60)
        XCTAssertFalse(merged.contains { $0 > 60.001 }, "out-of-range kept: \(merged)")
        XCTAssertEqual(merged, [0, 12, 24, 36])
    }

    /// Negative / zero stray samples never produce a duplicate origin or a backward step.
    func testHandlesZeroAndNegativeSamples() {
        let slices = [[-1.0, 0.0, 6.0], [12.0]]
        let merged = ParallelKeyframeDiscovery.mergeKeyframes(slices, duration: 60)
        XCTAssertEqual(merged.first, 0.0)
        XCTAssertEqual(merged.filter { $0 == 0.0 }.count, 1)
        assertStrictlyIncreasing(merged)
    }

    /// A completely empty discovery (all slices failed) yields just the origin, which the
    /// caller treats as "nothing discovered" (< 2 entries → fall back to sequential scan).
    func testAllEmptySlicesYieldOnlyOrigin() {
        let merged = ParallelKeyframeDiscovery.mergeKeyframes([[], [], []], duration: 60)
        XCTAssertEqual(merged, [0.0])
    }

    /// A sparse slice (only a couple boundaries) still merges cleanly — sparseness yields
    /// coarser (longer) in-sync segments downstream, never a desync, so merge must keep the
    /// real boundaries it has without inventing any.
    func testSparseSlicePreservesRealBoundaries() {
        let slices = [[40.0], [], [200.0], [400.0]]
        let merged = ParallelKeyframeDiscovery.mergeKeyframes(slices, duration: 600)
        XCTAssertEqual(merged, [0, 40, 200, 400])
        assertStrictlyIncreasing(merged)
    }

    /// duration <= 0 (unknown) disables the upper-bound filter but still sorts/dedups.
    func testUnknownDurationKeepsAllSortedUnique() {
        let slices = [[100.0, 50.0], [50.01, 150.0]]
        let merged = ParallelKeyframeDiscovery.mergeKeyframes(slices, duration: 0)
        XCTAssertEqual(merged.first, 0.0)
        assertStrictlyIncreasing(merged)
        XCTAssertEqual(merged, [0, 50, 100, 150])
    }
}
#endif
