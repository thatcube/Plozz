import XCTest
@testable import CoreModels

final class HLSSegmentPlannerTests: XCTestCase {
    /// Cues every 2s for a 22s title, positions every 100 bytes.
    private func evenCues() -> [MatroskaCuePoint] {
        (0...10).map { MatroskaCuePoint(timeTicks: UInt64($0 * 2 * 1000), clusterPosition: $0 * 100) }
    }

    func testSnapsBoundariesToNextCueAtOrAfterTarget() {
        let timeline = HLSSegmentPlanner.plan(
            cues: evenCues(),
            segmentDataOffset: 0,
            timestampScaleNs: 1_000_000,
            totalDuration: 22,
            fileSize: 1_100,
            targetDuration: 6
        )

        XCTAssertEqual(timeline.segments.map(\.duration), [6, 6, 6, 4])
        XCTAssertEqual(timeline.segments.map(\.startTime), [0, 6, 12, 18])
        XCTAssertEqual(timeline.segments.map(\.byteStart), [0, 300, 600, 900])
        XCTAssertEqual(timeline.segments.map(\.byteEnd), [300, 600, 900, 1_100])
        XCTAssertEqual(timeline.targetDuration, 6)
        XCTAssertEqual(timeline.totalDuration, 22)
        XCTAssertEqual(timeline.segments.map(\.index), [0, 1, 2, 3])
    }

    func testFinalSegmentRunsToFileEndAndDuration() {
        let timeline = HLSSegmentPlanner.plan(
            cues: [MatroskaCuePoint(timeTicks: 0, clusterPosition: 0)],
            segmentDataOffset: 1_000,
            timestampScaleNs: 1_000_000,
            totalDuration: 100,
            fileSize: 5_000,
            targetDuration: 6
        )
        XCTAssertEqual(timeline.count, 1)
        let only = timeline.segments[0]
        XCTAssertEqual(only.startTime, 0)
        XCTAssertEqual(only.duration, 100)
        XCTAssertEqual(only.byteStart, 1_000) // segmentDataOffset + clusterPosition
        XCTAssertEqual(only.byteEnd, 5_000)
    }

    func testNoCuesYieldsEmptyTimeline() {
        let timeline = HLSSegmentPlanner.plan(
            cues: [],
            segmentDataOffset: 0,
            timestampScaleNs: 1_000_000,
            totalDuration: 100,
            fileSize: 5_000
        )
        XCTAssertTrue(timeline.isEmpty)
        XCTAssertNil(timeline.segmentIndex(forTime: 10))
    }

    func testDuplicateAndNonMonotonicCuesAreCollapsed() {
        let cues = [
            MatroskaCuePoint(timeTicks: 0, clusterPosition: 0),
            MatroskaCuePoint(timeTicks: 7_000, clusterPosition: 700),
            MatroskaCuePoint(timeTicks: 7_000, clusterPosition: 700), // exact duplicate
            MatroskaCuePoint(timeTicks: 8_000, clusterPosition: 500), // out-of-order byte offset
            MatroskaCuePoint(timeTicks: 14_000, clusterPosition: 1_400)
        ]
        let timeline = HLSSegmentPlanner.plan(
            cues: cues,
            segmentDataOffset: 0,
            timestampScaleNs: 1_000_000,
            totalDuration: 20,
            fileSize: 2_000,
            targetDuration: 6
        )
        // Boundaries: 0 → 700 (7s) → 1400 (14s) → end.
        XCTAssertEqual(timeline.segments.map(\.byteStart), [0, 700, 1_400])
        XCTAssertEqual(timeline.segments.map(\.byteEnd), [700, 1_400, 2_000])
    }

    func testSegmentIndexForTime() {
        let timeline = HLSSegmentPlanner.plan(
            cues: evenCues(),
            segmentDataOffset: 0,
            timestampScaleNs: 1_000_000,
            totalDuration: 22,
            fileSize: 1_100,
            targetDuration: 6
        )
        XCTAssertEqual(timeline.segmentIndex(forTime: 0), 0)
        XCTAssertEqual(timeline.segmentIndex(forTime: 5.9), 0)
        XCTAssertEqual(timeline.segmentIndex(forTime: 6), 1)
        XCTAssertEqual(timeline.segmentIndex(forTime: 13), 2)
        XCTAssertEqual(timeline.segmentIndex(forTime: 19), 3)
        XCTAssertEqual(timeline.segmentIndex(forTime: 9_999), 3, "far seek clamps to last segment")
    }

    func testTimestampScaleAffectsSegmentTimes() {
        // Identical tick values, two different TimestampScales. At 1 ms/tick the
        // cues are 2 s apart so the first ~6 s segment ends on the 6 s cue; at
        // 2 ms/tick the same cues are 4 s apart so the boundary snaps to 8 s.
        let ticks = (0...10).map { MatroskaCuePoint(timeTicks: UInt64($0 * 2 * 1000), clusterPosition: $0 * 100) }

        let millisecond = HLSSegmentPlanner.plan(
            cues: ticks,
            segmentDataOffset: 0,
            timestampScaleNs: 1_000_000, // 1 ms per tick → cues at 0,2,4,… s
            totalDuration: 22,
            fileSize: 1_100,
            targetDuration: 6
        )
        XCTAssertEqual(millisecond.segments.first?.duration ?? 0, 6, accuracy: 1e-6)

        let twoMillisecond = HLSSegmentPlanner.plan(
            cues: ticks,
            segmentDataOffset: 0,
            timestampScaleNs: 2_000_000, // 2 ms per tick → cues at 0,4,8,… s
            totalDuration: 44,
            fileSize: 1_100,
            targetDuration: 6
        )
        XCTAssertEqual(twoMillisecond.segments.first?.duration ?? 0, 8, accuracy: 1e-6)
    }
}
