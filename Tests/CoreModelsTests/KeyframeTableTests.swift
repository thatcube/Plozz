import XCTest
@testable import CoreModels

/// Unit coverage for the shared keyframe currency and the Cues provider that
/// emits it. These guard the invariants the segment planner relies on (sorted,
/// strictly increasing, ~0-based, last keyframe <= duration).
final class KeyframeTableTests: XCTestCase {

    // MARK: - KeyframeTable.normalized

    func testNormalizedSortsAndStrictlyIncreasesDroppingDuplicates() {
        let table = KeyframeTable.normalized(times: [12, 0, 6, 6, 12, 18.5], duration: 20)
        XCTAssertEqual(table.times, [0, 6, 12, 18.5])
        XCTAssertEqual(table.duration, 20)
    }

    func testNormalizedDropsNegativeAndNonFiniteTimes() {
        let table = KeyframeTable.normalized(
            times: [-1, 0, .nan, 4, .infinity, 8],
            duration: 12
        )
        XCTAssertEqual(table.times, [0, 4, 8])
        XCTAssertEqual(table.duration, 12)
    }

    func testNormalizedRaisesDurationToLastKeyframeWhenSkewed() {
        // A rounding skew leaves the final keyframe just past the declared
        // duration; the invariant (last <= duration) must still hold.
        let table = KeyframeTable.normalized(times: [0, 5, 10.0001], duration: 10)
        XCTAssertEqual(table.duration, 10.0001, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(table.times.last ?? 0, table.duration)
    }

    func testNormalizedEmptyTimesYieldsEmptyTableWithDuration() {
        let table = KeyframeTable.normalized(times: [], duration: 42)
        XCTAssertTrue(table.isEmpty)
        XCTAssertEqual(table.count, 0)
        XCTAssertEqual(table.duration, 42)
        XCTAssertNil(table.byteOffsets)
        XCTAssertFalse(table.hasByteOffsets)
    }

    // MARK: - byteOffsets pairing

    func testNormalizedKeepsByteOffsetsParallelThroughSortAndDedupe() {
        // Times out of order with a duplicate; offsets must follow their time.
        let table = KeyframeTable.normalized(
            times: [12, 0, 6, 6, 18.5],
            byteOffsets: [800, 100, 400, 400, 1250],
            duration: 20
        )
        XCTAssertEqual(table.times, [0, 6, 12, 18.5])
        XCTAssertEqual(table.byteOffsets, [100, 400, 800, 1250])
        XCTAssertTrue(table.hasByteOffsets)
    }

    func testNormalizedDropsByteOffsetsPairedWithInvalidTimes() {
        let table = KeyframeTable.normalized(
            times: [-1, 0, .nan, 4, 8],
            byteOffsets: [10, 100, 200, 400, 800],
            duration: 12
        )
        XCTAssertEqual(table.times, [0, 4, 8])
        XCTAssertEqual(table.byteOffsets, [100, 400, 800])
    }

    func testNormalizedTreatsMismatchedByteOffsetsAsAbsent() {
        // A length mismatch must NOT misalign offsets — drop them entirely.
        let table = KeyframeTable.normalized(
            times: [0, 4, 8],
            byteOffsets: [100, 400], // wrong count
            duration: 12
        )
        XCTAssertEqual(table.times, [0, 4, 8])
        XCTAssertNil(table.byteOffsets)
    }

    func testNormalizedNilByteOffsetsStaysNil() {
        let table = KeyframeTable.normalized(times: [0, 4, 8], duration: 12)
        XCTAssertNil(table.byteOffsets)
        XCTAssertFalse(table.hasByteOffsets)
    }

    func testNormalizedInvariantsHoldOnArbitraryInput() {
        let table = KeyframeTable.normalized(
            times: [3.5, 3.5, 1.0, 0.0, 9.9, 2.2, 2.2],
            duration: 8
        )
        // sorted + strictly increasing
        XCTAssertEqual(table.times, table.times.sorted())
        for i in 1..<table.times.count {
            XCTAssertGreaterThan(table.times[i], table.times[i - 1])
        }
        // 0-based and last <= duration
        XCTAssertGreaterThanOrEqual(table.times.first ?? 0, 0)
        XCTAssertLessThanOrEqual(table.times.last ?? 0, table.duration)
    }

    // MARK: - CuesKeyframeProvider

    func testProviderMapsCueTicksToSecondsViaTimestampScale() {
        // 1 ms scale; cues at 0, 6000, 12000, 18500 ticks → 0, 6, 12, 18.5 s.
        let summary = MatroskaSummary(
            segmentDataOffset: 0,
            timestampScaleNs: 1_000_000,
            durationTicks: 7_200_000,
            cues: [
                MatroskaCuePoint(timeTicks: 0, clusterPosition: 5_000),
                MatroskaCuePoint(timeTicks: 6_000, clusterPosition: 4_000_000),
                MatroskaCuePoint(timeTicks: 12_000, clusterPosition: 8_000_000),
                MatroskaCuePoint(timeTicks: 18_500, clusterPosition: 12_500_000)
            ]
        )
        let table = CuesKeyframeProvider(summary: summary).keyframeTable()
        XCTAssertEqual(table.times, [0, 6, 12, 18.5])
        XCTAssertEqual(table.duration, 7200, accuracy: 1e-9)
        // Live-Cues source carries absolute Cluster byte offsets (segmentDataOffset
        // is 0 here, so offsets equal the cue cluster positions).
        XCTAssertEqual(table.byteOffsets, [5_000, 4_000_000, 8_000_000, 12_500_000])
    }

    func testProviderHonorsNonDefaultTimestampScale() {
        // 1 µs scale: 1_000_000 ticks == 1 s.
        let summary = MatroskaSummary(
            segmentDataOffset: 0,
            timestampScaleNs: 1_000,
            durationTicks: 10_000_000, // 10 s
            cues: [
                MatroskaCuePoint(timeTicks: 0, clusterPosition: 100),
                MatroskaCuePoint(timeTicks: 2_000_000, clusterPosition: 200), // 2 s
                MatroskaCuePoint(timeTicks: 4_000_000, clusterPosition: 300)  // 4 s
            ]
        )
        let table = CuesKeyframeProvider(summary: summary).keyframeTable()
        XCTAssertEqual(table.times, [0, 2, 4])
        XCTAssertEqual(table.duration, 10, accuracy: 1e-9)
    }

    func testProviderDurationHintWinsOverMatroskaDuration() {
        let summary = MatroskaSummary(
            segmentDataOffset: 0,
            timestampScaleNs: 1_000_000,
            durationTicks: 5_000_000, // 5000 s in Matroska Info
            cues: [MatroskaCuePoint(timeTicks: 0, clusterPosition: 1)]
        )
        let table = CuesKeyframeProvider(summary: summary, durationHint: 1234.5).keyframeTable()
        XCTAssertEqual(table.duration, 1234.5, accuracy: 1e-9)
    }

    func testProviderFallsBackToLastKeyframeWhenNoDurationKnown() {
        let summary = MatroskaSummary(
            segmentDataOffset: 0,
            timestampScaleNs: 1_000_000,
            durationTicks: nil,
            cues: [
                MatroskaCuePoint(timeTicks: 0, clusterPosition: 1),
                MatroskaCuePoint(timeTicks: 9_000, clusterPosition: 2) // 9 s
            ]
        )
        let table = CuesKeyframeProvider(summary: summary).keyframeTable()
        XCTAssertEqual(table.duration, 9, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(table.times.last ?? 0, table.duration)
    }
}
