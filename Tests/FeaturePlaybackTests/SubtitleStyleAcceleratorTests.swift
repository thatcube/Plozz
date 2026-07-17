import XCTest
@testable import FeaturePlayback

/// Tests the subtitle-style hold-to-accelerate ramp extracted from
/// `PlayerControls`. Pins the 1→2→4→8 curve and the three reset conditions
/// (idle timeout, direction flip, row change) so a held remote press covers a
/// large range while a deliberate tap stays fine.
final class SubtitleStyleAcceleratorTests: XCTestCase {
    func testRampCurveClimbsWithSustainedHold() {
        XCTAssertEqual(SubtitleStyleAccelerator.rampMagnitude(0), 1)
        XCTAssertEqual(SubtitleStyleAccelerator.rampMagnitude(2), 1)
        XCTAssertEqual(SubtitleStyleAccelerator.rampMagnitude(3), 2)
        XCTAssertEqual(SubtitleStyleAccelerator.rampMagnitude(7), 2)
        XCTAssertEqual(SubtitleStyleAccelerator.rampMagnitude(8), 4)
        XCTAssertEqual(SubtitleStyleAccelerator.rampMagnitude(15), 4)
        XCTAssertEqual(SubtitleStyleAccelerator.rampMagnitude(16), 8)
        XCTAssertEqual(SubtitleStyleAccelerator.rampMagnitude(100), 8)
    }

    func testSustainedSameDirectionHoldRampsUp() {
        var accel = SubtitleStyleAccelerator()
        let t0 = Date()
        var result: [Int] = []
        for i in 0..<10 {
            // Tight 0.1s spacing (< holdWindow) keeps the streak alive.
            result.append(accel.magnitude(slot: 3, sign: 1, now: t0.addingTimeInterval(0.1 * Double(i))))
        }
        XCTAssertEqual(result, [1, 1, 1, 2, 2, 2, 2, 2, 4, 4])
    }

    func testIdlePauseResetsToFineStep() {
        var accel = SubtitleStyleAccelerator()
        let t0 = Date()
        _ = accel.magnitude(slot: 3, sign: 1, now: t0)
        _ = accel.magnitude(slot: 3, sign: 1, now: t0.addingTimeInterval(0.1))
        _ = accel.magnitude(slot: 3, sign: 1, now: t0.addingTimeInterval(0.2)) // streak=2 -> still 1
        // Gap beyond holdWindow (0.32s) -> streak resets to fine 1.
        let after = accel.magnitude(slot: 3, sign: 1, now: t0.addingTimeInterval(1.0))
        XCTAssertEqual(after, 1)
    }

    func testDirectionFlipResetsStreak() {
        var accel = SubtitleStyleAccelerator()
        let t0 = Date()
        for i in 0..<5 { _ = accel.magnitude(slot: 3, sign: 1, now: t0.addingTimeInterval(0.1 * Double(i))) }
        // Flip to the other direction on the same row -> fine step again.
        let flipped = accel.magnitude(slot: 3, sign: -1, now: t0.addingTimeInterval(0.55))
        XCTAssertEqual(flipped, 1)
    }

    func testRowChangeResetsStreak() {
        var accel = SubtitleStyleAccelerator()
        let t0 = Date()
        for i in 0..<5 { _ = accel.magnitude(slot: 3, sign: 1, now: t0.addingTimeInterval(0.1 * Double(i))) }
        // Move focus to a different row -> fine step again.
        let other = accel.magnitude(slot: 4, sign: 1, now: t0.addingTimeInterval(0.55))
        XCTAssertEqual(other, 1)
    }
}
