import XCTest
import CoreModels
@testable import FeaturePlayback

/// Tests the pure Skip-button presentation policy extracted from the player
/// container. Pins the tricky rules: a grace-window seek offers a manual-only
/// button without stealing focus, Skip OFF suppresses even a grace seek, and
/// scrubbing / off-surface focus always defer.
final class SkipPresentationDecisionTests: XCTestCase {
    private typealias D = SkipPresentationDecision

    // MARK: Grace-window seek landing

    func testGraceSeekOffersManualButtonWithoutStealingFocus() {
        let action = D.action(
            skipMode: .autoInstant, wasSeekEntered: true,
            presentingButton: false, focusIsSurface: true,
            isScrubbing: false, autoDelayDeadlineReached: false)
        XCTAssertEqual(action, .presentManual(stealFocus: false))
    }

    func testGraceSeekSuppressedWhenSkipOff() {
        // Skip OFF must not resurrect a button the viewer turned off — falls to
        // the .off branch (tear down if presenting, else nothing).
        XCTAssertEqual(
            D.action(skipMode: .off, wasSeekEntered: true, presentingButton: true,
                     focusIsSurface: true, isScrubbing: false, autoDelayDeadlineReached: false),
            .tearDownIfPresenting)
        XCTAssertEqual(
            D.action(skipMode: .off, wasSeekEntered: true, presentingButton: false,
                     focusIsSurface: true, isScrubbing: false, autoDelayDeadlineReached: false),
            .none)
    }

    func testGraceSeekDefersWhileScrubbingOrOffSurface() {
        XCTAssertEqual(
            D.action(skipMode: .on, wasSeekEntered: true, presentingButton: false,
                     focusIsSurface: true, isScrubbing: true, autoDelayDeadlineReached: false),
            .none)
        XCTAssertEqual(
            D.action(skipMode: .on, wasSeekEntered: true, presentingButton: false,
                     focusIsSurface: false, isScrubbing: false, autoDelayDeadlineReached: false),
            .none)
    }

    // MARK: Natural entry per mode

    func testOffTearsDownButton() {
        XCTAssertEqual(
            D.action(skipMode: .off, wasSeekEntered: false, presentingButton: true,
                     focusIsSurface: true, isScrubbing: false, autoDelayDeadlineReached: false),
            .tearDownIfPresenting)
    }

    func testOnPresentsManualStealingFocus() {
        XCTAssertEqual(
            D.action(skipMode: .on, wasSeekEntered: false, presentingButton: false,
                     focusIsSurface: true, isScrubbing: false, autoDelayDeadlineReached: false),
            .presentManual(stealFocus: true))
        // Already presenting -> no-op.
        XCTAssertEqual(
            D.action(skipMode: .on, wasSeekEntered: false, presentingButton: true,
                     focusIsSurface: true, isScrubbing: false, autoDelayDeadlineReached: false),
            .none)
    }

    func testAutoInstantSkipsUnlessScrubbing() {
        XCTAssertEqual(
            D.action(skipMode: .autoInstant, wasSeekEntered: false, presentingButton: false,
                     focusIsSurface: true, isScrubbing: false, autoDelayDeadlineReached: false),
            .autoInstant)
        XCTAssertEqual(
            D.action(skipMode: .autoInstant, wasSeekEntered: false, presentingButton: false,
                     focusIsSurface: true, isScrubbing: true, autoDelayDeadlineReached: false),
            .none)
    }

    func testAutoDelayArmsThenFiresAtDeadline() {
        // Not presenting yet, on surface -> arm the countdown.
        XCTAssertEqual(
            D.action(skipMode: .autoDelay, wasSeekEntered: false, presentingButton: false,
                     focusIsSurface: true, isScrubbing: false, autoDelayDeadlineReached: false),
            .beginAutoDelay)
        // Presenting, deadline reached -> fire.
        XCTAssertEqual(
            D.action(skipMode: .autoDelay, wasSeekEntered: false, presentingButton: true,
                     focusIsSurface: true, isScrubbing: false, autoDelayDeadlineReached: true),
            .fireAutoDelay)
        // Presenting, deadline reached, but scrubbing -> defer.
        XCTAssertEqual(
            D.action(skipMode: .autoDelay, wasSeekEntered: false, presentingButton: true,
                     focusIsSurface: true, isScrubbing: true, autoDelayDeadlineReached: true),
            .none)
        // Presenting, deadline not reached -> wait.
        XCTAssertEqual(
            D.action(skipMode: .autoDelay, wasSeekEntered: false, presentingButton: true,
                     focusIsSurface: true, isScrubbing: false, autoDelayDeadlineReached: false),
            .none)
    }

    func testAutoDelayDefersArmingOffSurface() {
        XCTAssertEqual(
            D.action(skipMode: .autoDelay, wasSeekEntered: false, presentingButton: false,
                     focusIsSurface: false, isScrubbing: false, autoDelayDeadlineReached: false),
            .none)
    }
}
