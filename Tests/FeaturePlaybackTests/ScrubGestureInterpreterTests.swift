#if canImport(AVFoundation)
import XCTest

@testable import FeaturePlayback

/// Pins the scrub gesture state machine that historically broke silently on a
/// TV: an axis lock that let a vertical drift move the head, a pause-to-seek gate
/// that leaked a seek, a flick misread as a landing (seek + rebuffer churn), or a
/// multi-swipe traversal that reset its momentum on each swipe. All pure, so the
/// whole gesture is driven here without UIKit.
final class ScrubGestureInterpreterTests: XCTestCase {

    private func makeInterpreter() -> ScrubGestureInterpreter {
        ScrubGestureInterpreter(axisDeadZone: 18, speedSmoothing: 0.25, flickCommitThreshold: 1000)
    }

    // MARK: Axis lock + dead-zone

    func testBelowDeadZoneIsIgnoredAndLeavesAxisUndecided() {
        var g = makeInterpreter()
        g.begin()
        let outcome = g.changed(translationX: 10, translationY: 4, velocityX: 0,
                                isScrubbing: false, seekWithoutPausing: true, isPaused: true)
        XCTAssertEqual(outcome, .ignore)
        XCTAssertEqual(g.axis, .undecided)
    }

    func testHorizontalPastDeadZoneBeginsScrubWithZeroFirstDelta() {
        var g = makeInterpreter()
        g.begin()
        // Paused (seek engages) → a fresh scrub begins; first sample delta is 0 so
        // locking the axis never itself moves the head.
        let outcome = g.changed(translationX: 20, translationY: 3, velocityX: 800,
                                isScrubbing: false, seekWithoutPausing: true, isPaused: true)
        guard case let .advance(delta, smoothed, beginScrub, continueTraversal) = outcome else {
            return XCTFail("expected advance, got \(outcome)")
        }
        XCTAssertEqual(delta, 0, accuracy: 0.0001)
        XCTAssertTrue(beginScrub)
        XCTAssertFalse(continueTraversal)
        // Fresh scrub resets smoothing to 0 first, then EMA: 800 * 0.25 = 200.
        XCTAssertEqual(smoothed, 200, accuracy: 0.0001)
        XCTAssertEqual(g.axis, .horizontal)
    }

    func testVerticalDownEntersControlBarAndLocksVertical() {
        var g = makeInterpreter()
        g.begin()
        let outcome = g.changed(translationX: 3, translationY: 25, velocityX: 0,
                                isScrubbing: false, seekWithoutPausing: true, isPaused: true)
        XCTAssertEqual(outcome, .enterControlBar)
        XCTAssertEqual(g.axis, .verticalIgnored)
        // Subsequent samples in the same gesture do nothing (locked vertical).
        let next = g.changed(translationX: 60, translationY: 40, velocityX: 500,
                             isScrubbing: false, seekWithoutPausing: true, isPaused: true)
        XCTAssertEqual(next, .ignore)
    }

    func testVerticalUpIsIgnoredNotControlBar() {
        var g = makeInterpreter()
        g.begin()
        let outcome = g.changed(translationX: 3, translationY: -25, velocityX: 0,
                                isScrubbing: false, seekWithoutPausing: true, isPaused: true)
        XCTAssertEqual(outcome, .ignore)
        XCTAssertEqual(g.axis, .verticalIgnored)
    }

    func testAxisLockKeepsScrubbingDespiteVerticalDrift() {
        var g = makeInterpreter()
        g.begin()
        _ = g.changed(translationX: 20, translationY: 0, velocityX: 400,
                      isScrubbing: false, seekWithoutPausing: true, isPaused: true)
        // A later sample drifts more vertically than horizontally, but the axis is
        // already locked horizontal → it must still advance, never bleed vertical.
        let outcome = g.changed(translationX: 25, translationY: 90, velocityX: 400,
                                isScrubbing: true, seekWithoutPausing: true, isPaused: true)
        guard case let .advance(delta, _, beginScrub, _) = outcome else {
            return XCTFail("expected advance, got \(outcome)")
        }
        XCTAssertEqual(delta, 5, accuracy: 0.0001)
        XCTAssertFalse(beginScrub)
    }

    // MARK: Pause-to-seek gate

    func testPauseToSeekGateFlashesAndSuppressesWhilePlaying() {
        var g = makeInterpreter()
        g.begin()
        // seekWithoutPausing off AND playing → horizontal swipe must NOT scrub.
        let outcome = g.changed(translationX: 30, translationY: 2, velocityX: 900,
                                isScrubbing: false, seekWithoutPausing: false, isPaused: false)
        XCTAssertEqual(outcome, .flashAndSuppress)
        XCTAssertEqual(g.axis, .verticalIgnored)
        // Rest of the gesture is suppressed.
        let next = g.changed(translationX: 120, translationY: 2, velocityX: 900,
                             isScrubbing: false, seekWithoutPausing: false, isPaused: false)
        XCTAssertEqual(next, .ignore)
    }

    func testPauseToSeekGateDoesNotFireWhenAlreadyPaused() {
        var g = makeInterpreter()
        g.begin()
        // Paused → scrub engages even with seekWithoutPausing off.
        let outcome = g.changed(translationX: 30, translationY: 2, velocityX: 400,
                                isScrubbing: false, seekWithoutPausing: false, isPaused: true)
        guard case .advance(_, _, let beginScrub, _) = outcome else {
            return XCTFail("expected advance, got \(outcome)")
        }
        XCTAssertTrue(beginScrub)
    }

    // MARK: Velocity smoothing (EMA)

    func testSmoothedSpeedCarriesMomentumAcrossSamples() {
        var g = makeInterpreter()
        g.begin()
        // Begin: reset to 0 then EMA → 1000*0.25 = 250.
        _ = g.changed(translationX: 20, translationY: 0, velocityX: 1000,
                      isScrubbing: false, seekWithoutPausing: true, isPaused: true)
        // Next: 250 + (2000-250)*0.25 = 687.5.
        let outcome = g.changed(translationX: 40, translationY: 0, velocityX: 2000,
                                isScrubbing: true, seekWithoutPausing: true, isPaused: true)
        guard case let .advance(_, smoothed, _, _) = outcome else {
            return XCTFail("expected advance, got \(outcome)")
        }
        XCTAssertEqual(smoothed, 687.5, accuracy: 0.0001)
    }

    // MARK: Multi-swipe traversal continuation

    func testContinueTraversalWhenAlreadyScrubbing() {
        var g = makeInterpreter()
        g.begin()
        // A fresh gesture whose first horizontal sample lands while a prior flick
        // left isScrubbing true → continue the session (no begin), and momentum
        // is preserved (smoothing not reset to 0).
        // Prime some momentum on a first gesture.
        _ = g.changed(translationX: 20, translationY: 0, velocityX: 4000,
                      isScrubbing: false, seekWithoutPausing: true, isPaused: true)
        g.begin()
        let outcome = g.changed(translationX: 30, translationY: 0, velocityX: 0,
                                isScrubbing: true, seekWithoutPausing: true, isPaused: true)
        guard case let .advance(delta, smoothed, beginScrub, continueTraversal) = outcome else {
            return XCTFail("expected advance, got \(outcome)")
        }
        XCTAssertEqual(delta, 0, accuracy: 0.0001)
        XCTAssertTrue(continueTraversal)
        XCTAssertFalse(beginScrub)
        // Momentum from the first gesture (1000) decays but was NOT reset to 0:
        // 1000 + (0-1000)*0.25 = 750.
        XCTAssertEqual(smoothed, 750, accuracy: 0.0001)
    }

    // MARK: Flick vs. deliberate landing on lift

    func testFastFlickLiftBridgesCommit() {
        var g = makeInterpreter()
        g.begin()
        _ = g.changed(translationX: 20, translationY: 0, velocityX: 400,
                      isScrubbing: true, seekWithoutPausing: true, isPaused: true)
        let end = g.ended(gestureEnded: true, velocityX: 1500, isScrubbing: true)
        XCTAssertEqual(end, .bridgeCommit)
        XCTAssertEqual(g.axis, .undecided)
    }

    func testSlowLandingCommitsImmediately() {
        var g = makeInterpreter()
        g.begin()
        _ = g.changed(translationX: 20, translationY: 0, velocityX: 400,
                      isScrubbing: true, seekWithoutPausing: true, isPaused: true)
        let end = g.ended(gestureEnded: true, velocityX: 200, isScrubbing: true)
        XCTAssertEqual(end, .commit)
    }

    func testCancelledGestureCommitsRatherThanBridges() {
        var g = makeInterpreter()
        g.begin()
        _ = g.changed(translationX: 20, translationY: 0, velocityX: 400,
                      isScrubbing: true, seekWithoutPausing: true, isPaused: true)
        // .cancelled/.failed (gestureEnded == false) must never bridge, even at a
        // flick-speed lift — a cancel should settle, not leave a session dangling.
        let end = g.ended(gestureEnded: false, velocityX: 5000, isScrubbing: true)
        XCTAssertEqual(end, .commit)
    }

    func testEndWithoutHorizontalScrubIsNoOp() {
        var g = makeInterpreter()
        g.begin()
        // Never locked horizontal → nothing to commit.
        let end = g.ended(gestureEnded: true, velocityX: 5000, isScrubbing: false)
        XCTAssertEqual(end, .none)
    }
}
#endif
