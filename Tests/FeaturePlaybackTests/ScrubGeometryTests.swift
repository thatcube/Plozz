import XCTest
@testable import FeaturePlayback

/// Tests the pure velocity-accelerated scrub transfer function. These prove the
/// properties that fix the "fast swipe gets stuck / won't drag far enough" feel:
/// at low speed the gain is ~1:1 precise, but as pan speed rises the gain ramps
/// up steeply (so a fast flick crosses far more of the runtime), the result is
/// directional in the pan, and the position stays clamped to the runtime.
final class ScrubGeometryTests: XCTestCase {
    private let tuning = ScrubGeometry.Tuning(
        baseSecondsPerPoint: 0.18,
        accelOnsetSpeed: 500,
        accelSaturationSpeed: 3500,
        maxAccelMultiplier: 6)
    private let duration = 3600.0

    func testNoAccelerationBelowOnsetSpeed() {
        // A slow, deliberate drag (below the onset speed) stays 1:1 precise.
        let mult = ScrubGeometry.accelerationMultiplier(
            speedPointsPerSecond: 200, tuning: tuning)
        XCTAssertEqual(mult, 1, accuracy: 0.0001)

        let delta = ScrubGeometry.scrubDeltaSeconds(
            translationDeltaPoints: 100, speedPointsPerSecond: 200, tuning: tuning)
        XCTAssertEqual(delta, 100 * 0.18, accuracy: 0.0001)
    }

    func testGainReachesCeilingAtSaturation() {
        // At (and above) the saturation speed the gain is exactly the ceiling.
        let mult = ScrubGeometry.accelerationMultiplier(
            speedPointsPerSecond: 3500, tuning: tuning)
        XCTAssertEqual(mult, tuning.maxAccelMultiplier, accuracy: 0.0001)
    }

    func testGainIsHalfwayAtMidpointSpeed() {
        // Smoothstep is symmetric: at the midpoint speed the gain is exactly
        // halfway between 1 and the ceiling (1 + (max-1) * 0.5).
        let midSpeed = (tuning.accelOnsetSpeed + tuning.accelSaturationSpeed) / 2
        let mult = ScrubGeometry.accelerationMultiplier(
            speedPointsPerSecond: midSpeed, tuning: tuning)
        XCTAssertEqual(mult, 1 + (tuning.maxAccelMultiplier - 1) * 0.5, accuracy: 0.0001)
    }

    func testAccelerationMonotonicInSpeed() {
        var previous = 0.0
        for speed in stride(from: 0.0, through: 12000, by: 250) {
            let mult = ScrubGeometry.accelerationMultiplier(
                speedPointsPerSecond: speed, tuning: tuning)
            XCTAssertGreaterThanOrEqual(mult, previous)
            previous = mult
        }
    }

    func testAccelerationCapped() {
        let mult = ScrubGeometry.accelerationMultiplier(
            speedPointsPerSecond: 1_000_000, tuning: tuning)
        XCTAssertEqual(mult, tuning.maxAccelMultiplier, accuracy: 0.0001)
    }

    func testFastFlickReachesMuchFurtherThanSlowDrag() {
        // The crux of the user's complaint: the *same* physical travel must move
        // the head far further when flicked quickly than when dragged slowly.
        let slow = ScrubGeometry.scrubDeltaSeconds(
            translationDeltaPoints: 300, speedPointsPerSecond: 200, tuning: tuning)
        let fast = ScrubGeometry.scrubDeltaSeconds(
            translationDeltaPoints: 300, speedPointsPerSecond: 5000, tuning: tuning)
        XCTAssertGreaterThan(fast, slow * 5)
    }

    func testAdvanceIsDirectional() {
        // Negative travel scrubs backward; positive forward.
        let back = ScrubGeometry.advance(
            scrubSeconds: 1000, translationDeltaPoints: -50,
            speedPointsPerSecond: 100, tuning: tuning, duration: duration)
        XCTAssertLessThan(back, 1000)

        let forward = ScrubGeometry.advance(
            scrubSeconds: 1000, translationDeltaPoints: 50,
            speedPointsPerSecond: 100, tuning: tuning, duration: duration)
        XCTAssertGreaterThan(forward, 1000)
    }

    func testAdvanceClampsToZeroAndDuration() {
        let low = ScrubGeometry.advance(
            scrubSeconds: 10, translationDeltaPoints: -100000,
            speedPointsPerSecond: 8000, tuning: tuning, duration: duration)
        XCTAssertEqual(low, 0, accuracy: 0.0001)

        let high = ScrubGeometry.advance(
            scrubSeconds: duration - 5, translationDeltaPoints: 100000,
            speedPointsPerSecond: 8000, tuning: tuning, duration: duration)
        XCTAssertEqual(high, duration, accuracy: 0.0001)
    }

    func testAccumulatedDragMatchesSingleEquivalentDrag() {
        // Splitting a constant-speed drag into many small samples accumulates to
        // the same place as one big sample — no per-sample drift.
        let speed = 300.0
        var accumulated = 1000.0
        for _ in 0..<60 {
            accumulated = ScrubGeometry.advance(
                scrubSeconds: accumulated, translationDeltaPoints: 5,
                speedPointsPerSecond: speed, tuning: tuning, duration: duration)
        }
        let single = ScrubGeometry.advance(
            scrubSeconds: 1000, translationDeltaPoints: 300,
            speedPointsPerSecond: speed, tuning: tuning, duration: duration)
        XCTAssertEqual(accumulated, single, accuracy: 0.0001)
    }
}
