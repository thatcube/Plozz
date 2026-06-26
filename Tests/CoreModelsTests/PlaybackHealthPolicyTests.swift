import XCTest
@testable import CoreModels

final class PlaybackHealthPolicyTests: XCTestCase {

    // MARK: - LateFrameRateTracker

    func testRateNilWithFewerThanTwoSamples() {
        var tracker = LateFrameRateTracker(window: 5)
        XCTAssertNil(tracker.ratePerSecond)
        tracker.record(cumulativeLateFrames: 10, at: 0)
        XCTAssertNil(tracker.ratePerSecond, "A single sample can't define a rate")
    }

    func testRateComputesFramesPerSecondOverSpan() {
        var tracker = LateFrameRateTracker(window: 10)
        tracker.record(cumulativeLateFrames: 100, at: 0)
        tracker.record(cumulativeLateFrames: 160, at: 5) // +60 over 5s
        XCTAssertEqual(tracker.ratePerSecond ?? 0, 12, accuracy: 0.001)
    }

    func testRateNilWhenSpanTooShort() {
        var tracker = LateFrameRateTracker(window: 5)
        tracker.record(cumulativeLateFrames: 0, at: 0)
        tracker.record(cumulativeLateFrames: 5, at: 0.2) // <0.5s span
        XCTAssertNil(tracker.ratePerSecond)
    }

    func testWindowEvictsOldSamplesSoRateReflectsRecentActivity() {
        var tracker = LateFrameRateTracker(window: 5)
        // Heavy dropping early, then it settles to zero late frames.
        tracker.record(cumulativeLateFrames: 0, at: 0)
        tracker.record(cumulativeLateFrames: 100, at: 2)   // burst
        // Counter stops rising; advance well past the window.
        tracker.record(cumulativeLateFrames: 100, at: 8)
        tracker.record(cumulativeLateFrames: 100, at: 10)
        // The early burst is outside the 5s window; recent rate is ~0.
        XCTAssertEqual(tracker.ratePerSecond ?? -1, 0, accuracy: 0.001)
    }

    func testCounterResetRestartsWindow() {
        var tracker = LateFrameRateTracker(window: 5)
        tracker.record(cumulativeLateFrames: 500, at: 0)
        tracker.record(cumulativeLateFrames: 5, at: 1) // engine swap: counter dropped
        tracker.record(cumulativeLateFrames: 11, at: 2) // +6 over 1s from the reset point
        XCTAssertEqual(tracker.ratePerSecond ?? 0, 6, accuracy: 0.001)
    }

    func testResetClearsSamples() {
        var tracker = LateFrameRateTracker(window: 5)
        tracker.record(cumulativeLateFrames: 0, at: 0)
        tracker.record(cumulativeLateFrames: 30, at: 3)
        tracker.reset()
        XCTAssertNil(tracker.ratePerSecond)
    }

    // MARK: - Threshold

    func testThresholdIsFactorTimesSourceFPS() {
        let policy = PlaybackHealthPolicy(lateRateFactorOfFPS: 0.5)
        XCTAssertEqual(policy.lateFrameRateThreshold(sourceFrameRate: 60), 30, accuracy: 0.001)
        XCTAssertEqual(policy.lateFrameRateThreshold(sourceFrameRate: 23.976), 11.988, accuracy: 0.001)
    }

    func testThresholdFallsBackToAssumedFPSWhenUnknown() {
        let policy = PlaybackHealthPolicy(lateRateFactorOfFPS: 0.5, assumedFrameRate: 24)
        XCTAssertEqual(policy.lateFrameRateThreshold(sourceFrameRate: nil), 12, accuracy: 0.001)
        XCTAssertEqual(policy.lateFrameRateThreshold(sourceFrameRate: 0), 12, accuracy: 0.001)
    }

    func testExcessiveRateBoundary() {
        let policy = PlaybackHealthPolicy(lateRateFactorOfFPS: 0.5)
        XCTAssertTrue(policy.isExcessiveLateFrameRate(12, sourceFrameRate: 24))
        XCTAssertTrue(policy.isExcessiveLateFrameRate(20, sourceFrameRate: 24))
        XCTAssertFalse(policy.isExcessiveLateFrameRate(11.9, sourceFrameRate: 24))
    }

    // MARK: - Startup stall

    func testStartupStallFiresAfterTimeoutWithNoProgress() {
        let policy = PlaybackHealthPolicy(startupStallTimeout: 8)
        XCTAssertTrue(policy.isStartupStalled(secondsSinceArmed: 8, hasMadeProgress: false, isPaused: false))
        XCTAssertFalse(policy.isStartupStalled(secondsSinceArmed: 7.9, hasMadeProgress: false, isPaused: false))
    }

    func testStartupStallSuppressedByProgressOrPause() {
        let policy = PlaybackHealthPolicy(startupStallTimeout: 8)
        XCTAssertFalse(policy.isStartupStalled(secondsSinceArmed: 20, hasMadeProgress: true, isPaused: false))
        XCTAssertFalse(policy.isStartupStalled(secondsSinceArmed: 20, hasMadeProgress: false, isPaused: true))
    }

    // MARK: - Can't keep up (render health)

    func testFailsToKeepUpWhenRateSustainedPastWarmupAndDwell() {
        let policy = PlaybackHealthPolicy(startupWarmup: 5, dwell: 5, lateRateFactorOfFPS: 0.5)
        XCTAssertTrue(policy.isFailingToKeepUp(
            secondsSinceFirstProgress: 12,
            isPaused: false,
            isProgressing: true,
            lateFrameRate: 20,           // > 0.5*24
            sourceFrameRate: 24,
            secondsSustainedAboveThreshold: 5
        ))
    }

    func testDoesNotFailDuringStartupWarmup() {
        let policy = PlaybackHealthPolicy(startupWarmup: 5, dwell: 5)
        XCTAssertFalse(policy.isFailingToKeepUp(
            secondsSinceFirstProgress: 3,    // still warming up
            isPaused: false,
            isProgressing: true,
            lateFrameRate: 100,
            sourceFrameRate: 24,
            secondsSustainedAboveThreshold: 10
        ))
    }

    func testDoesNotFailBeforeDwellElapses() {
        let policy = PlaybackHealthPolicy(startupWarmup: 5, dwell: 5)
        XCTAssertFalse(policy.isFailingToKeepUp(
            secondsSinceFirstProgress: 12,
            isPaused: false,
            isProgressing: true,
            lateFrameRate: 100,
            sourceFrameRate: 24,
            secondsSustainedAboveThreshold: 4.9    // not sustained long enough
        ))
    }

    func testDoesNotFailWhenPausedOrNotProgressing() {
        let policy = PlaybackHealthPolicy(startupWarmup: 5, dwell: 5)
        XCTAssertFalse(policy.isFailingToKeepUp(
            secondsSinceFirstProgress: 30, isPaused: true, isProgressing: true,
            lateFrameRate: 100, sourceFrameRate: 24, secondsSustainedAboveThreshold: 30))
        XCTAssertFalse(policy.isFailingToKeepUp(
            secondsSinceFirstProgress: 30, isPaused: false, isProgressing: false,
            lateFrameRate: 100, sourceFrameRate: 24, secondsSustainedAboveThreshold: 30))
    }

    func testDoesNotFailWithoutARateSample() {
        let policy = PlaybackHealthPolicy()
        XCTAssertFalse(policy.isFailingToKeepUp(
            secondsSinceFirstProgress: 30, isPaused: false, isProgressing: true,
            lateFrameRate: nil, sourceFrameRate: 24, secondsSustainedAboveThreshold: 30),
            "Native engine reports no late frames → never judged 'can't keep up'")
    }

    func testDefaultIsSnappyButConservative() {
        let policy = PlaybackHealthPolicy.default
        XCTAssertEqual(policy.startupStallTimeout, 8)
        XCTAssertEqual(policy.startupWarmup, 5)
        XCTAssertEqual(policy.dwell, 5)
        XCTAssertEqual(policy.lateRateFactorOfFPS, 0.5, accuracy: 0.0001)
    }

    func testPolicyIsTunable() {
        var policy = PlaybackHealthPolicy.default
        policy.lateRateFactorOfFPS = 0.25
        policy.dwell = 3
        XCTAssertEqual(policy.lateFrameRateThreshold(sourceFrameRate: 24), 6, accuracy: 0.001)
        XCTAssertTrue(policy.isFailingToKeepUp(
            secondsSinceFirstProgress: 10, isPaused: false, isProgressing: true,
            lateFrameRate: 7, sourceFrameRate: 24, secondsSustainedAboveThreshold: 3))
    }
}
