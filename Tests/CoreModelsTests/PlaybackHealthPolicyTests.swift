import XCTest
@testable import CoreModels

/// Locks the pure playback-health policy that drives the on-device watchdog →
/// graceful server fallback. DIRECT PLAY stays default; a server stream is the
/// last resort, fired only when the on-device path measurably stalls or can't
/// keep up.
final class PlaybackHealthPolicyTests: XCTestCase {

    private let policy = PlaybackHealthPolicy.default

    // MARK: - Start-up stall

    func testNoProgressBeforeDeadlineIsHealthy() {
        let v = policy.verdict(
            secondsSinceArmed: 4, hasMadeProgress: false, isPaused: false,
            secondsSinceFirstProgress: nil, lateFramesSinceFirstProgress: nil)
        XCTAssertEqual(v, .healthy)
    }

    func testNoProgressAtDeadlineIsStartupStalled() {
        let v = policy.verdict(
            secondsSinceArmed: 8, hasMadeProgress: false, isPaused: false,
            secondsSinceFirstProgress: nil, lateFramesSinceFirstProgress: nil)
        XCTAssertEqual(v, .startupStalled)
    }

    func testNoProgressPastDeadlineIsStartupStalled() {
        let v = policy.verdict(
            secondsSinceArmed: 30, hasMadeProgress: false, isPaused: false,
            secondsSinceFirstProgress: nil, lateFramesSinceFirstProgress: nil)
        XCTAssertEqual(v, .startupStalled)
    }

    func testPausedDuringStartupNeverStalls() {
        // A user pause must never be mistaken for a hang.
        let v = policy.verdict(
            secondsSinceArmed: 60, hasMadeProgress: false, isPaused: true,
            secondsSinceFirstProgress: nil, lateFramesSinceFirstProgress: nil)
        XCTAssertEqual(v, .healthy)
    }

    // MARK: - Render health ("can't keep up")

    func testProgressingWithFewLateFramesIsHealthy() {
        let v = policy.verdict(
            secondsSinceArmed: 6, hasMadeProgress: true, isPaused: false,
            secondsSinceFirstProgress: 4, lateFramesSinceFirstProgress: 5)
        XCTAssertEqual(v, .healthy)
    }

    func testProgressingWithSustainedLateFramesCannotKeepUp() {
        let v = policy.verdict(
            secondsSinceArmed: 9, hasMadeProgress: true, isPaused: false,
            secondsSinceFirstProgress: 6, lateFramesSinceFirstProgress: 60)
        XCTAssertEqual(v, .cannotKeepUp)
    }

    func testLateFramesAtThresholdBoundaryCannotKeepUp() {
        let v = policy.verdict(
            secondsSinceArmed: 9, hasMadeProgress: true, isPaused: false,
            secondsSinceFirstProgress: 6, lateFramesSinceFirstProgress: 60)
        XCTAssertEqual(v, .cannotKeepUp)
    }

    func testLateFramesAfterWindowAreIgnored() {
        // A late-frame burst long after start-up (e.g. a big seek) must not be
        // mistaken for a hardware stall.
        let v = policy.verdict(
            secondsSinceArmed: 40, hasMadeProgress: true, isPaused: false,
            secondsSinceFirstProgress: 25, lateFramesSinceFirstProgress: 500)
        XCTAssertEqual(v, .healthy)
    }

    func testProgressingWithoutFrameStatsIsHealthy() {
        // The native (AVPlayer) engine doesn't report frame health → nil → never
        // judged "can't keep up" (it's the efficient path we never fall back from).
        let v = policy.verdict(
            secondsSinceArmed: 9, hasMadeProgress: true, isPaused: false,
            secondsSinceFirstProgress: 6, lateFramesSinceFirstProgress: nil)
        XCTAssertEqual(v, .healthy)
    }

    func testPausedWhileProgressingIsHealthy() {
        let v = policy.verdict(
            secondsSinceArmed: 9, hasMadeProgress: true, isPaused: true,
            secondsSinceFirstProgress: 6, lateFramesSinceFirstProgress: 999)
        XCTAssertEqual(v, .healthy)
    }

    // MARK: - Tunability

    func testCustomThresholdsAreHonoured() {
        let strict = PlaybackHealthPolicy(
            startupStallTimeout: 3, renderHealthWindow: 5, lateFrameStallThreshold: 10)
        XCTAssertEqual(
            strict.verdict(secondsSinceArmed: 3, hasMadeProgress: false, isPaused: false,
                           secondsSinceFirstProgress: nil, lateFramesSinceFirstProgress: nil),
            .startupStalled)
        XCTAssertEqual(
            strict.verdict(secondsSinceArmed: 4, hasMadeProgress: true, isPaused: false,
                           secondsSinceFirstProgress: 2, lateFramesSinceFirstProgress: 10),
            .cannotKeepUp)
    }

    func testDefaultTuningIsSnappy() {
        // Guards against a regression back to the old sluggish 30s deadline.
        XCTAssertEqual(PlaybackHealthPolicy.default.startupStallTimeout, 8)
        XCTAssertLessThanOrEqual(PlaybackHealthPolicy.default.startupStallTimeout, 10)
    }
}
