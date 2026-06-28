#if canImport(UIKit)
import XCTest
@testable import LocalRemux

/// Tests for `KeyframeTable` — the single shared keyframe currency every discovery
/// source (Cues reader, persisted cache, EBML sampler, server endpoint) normalizes
/// to before the planner. Pure value logic, no I/O.
final class KeyframeTableTests: XCTestCase {

    func testNormalizedSortsAndDedups() {
        let raw: [Double] = [12.0, 0.0, 6.0, 12.0, 6.0005]
        let table = KeyframeTable.normalized(times: raw, duration: 24.0)
        // 12.0 dup and 6.0005 (within epsilon of 6.0) collapse.
        XCTAssertEqual(table.times, [0.0, 6.0, 12.0])
        XCTAssertEqual(table.duration, 24.0)
    }

    func testNormalizedDropsNonFiniteAndNegative() {
        let raw: [Double] = [-1.0, 0.0, .nan, 5.0, .infinity, 10.0]
        let table = KeyframeTable.normalized(times: raw, duration: 20.0)
        XCTAssertEqual(table.times, [0.0, 5.0, 10.0])
    }

    func testNormalizedClampsToDuration() {
        // A keyframe past the declared duration (sampler overshoot / rounding) drops.
        let raw: [Double] = [0.0, 30.0, 61.0]
        let table = KeyframeTable.normalized(times: raw, duration: 60.0)
        XCTAssertEqual(table.times, [0.0, 30.0])
    }

    func testNormalizedKeepsWithinEpsilonOfDuration() {
        let raw: [Double] = [0.0, 59.9995]
        let table = KeyframeTable.normalized(times: raw, duration: 60.0)
        XCTAssertEqual(table.times.count, 2)
    }

    func testUnknownDurationDoesNotClamp() {
        let raw: [Double] = [0.0, 100.0, 200.0]
        let table = KeyframeTable.normalized(times: raw, duration: 0)
        XCTAssertEqual(table.times, [0.0, 100.0, 200.0])
    }

    func testIsUsableRequiresTwoKeyframes() {
        XCTAssertFalse(KeyframeTable(duration: 10, times: []).isUsable)
        XCTAssertFalse(KeyframeTable(duration: 10, times: [0]).isUsable)
        XCTAssertTrue(KeyframeTable(duration: 10, times: [0, 6]).isUsable)
    }

    func testNormalizedTimesAreStrictlyIncreasing() {
        let raw: [Double] = [0.0, 0.0009, 0.0018, 1.0]
        let table = KeyframeTable.normalized(times: raw, duration: 10.0, epsilon: 1e-3)
        var prev = -1.0
        for t in table.times { XCTAssertGreaterThan(t, prev); prev = t }
    }
}
#endif
