#if canImport(AVFoundation)
import CoreModels
import XCTest

@testable import FeaturePlayback

/// Pins the Up Next card's per-mode presentation policy — the binge auto-advance
/// timing and the grace-window passive-present that must never hijack a seek.
final class UpNextPresentationDecisionTests: XCTestCase {

    private func decide(
        skipMode: SkipIntrosMode,
        wasSeekEntered: Bool = false,
        presentingCard: Bool = false,
        focusIsSurface: Bool = true,
        isScrubbing: Bool = false,
        autoDelayDeadlineReached: Bool = false
    ) -> UpNextPresentationDecision.Action {
        UpNextPresentationDecision.action(
            skipMode: skipMode,
            wasSeekEntered: wasSeekEntered,
            presentingCard: presentingCard,
            focusIsSurface: focusIsSurface,
            isScrubbing: isScrubbing,
            autoDelayDeadlineReached: autoDelayDeadlineReached)
    }

    // MARK: Grace-window seek → passive present, never auto

    func testSeekEnteredPresentsPassively() {
        XCTAssertEqual(decide(skipMode: .autoInstant, wasSeekEntered: true), .presentPassive)
    }

    func testSeekEnteredNeverStealsWhenAlreadyPresenting() {
        XCTAssertEqual(decide(skipMode: .on, wasSeekEntered: true, presentingCard: true), .none)
    }

    func testSeekEnteredDefersOffSurfaceAndWhileScrubbing() {
        XCTAssertEqual(decide(skipMode: .on, wasSeekEntered: true, focusIsSurface: false), .none)
        XCTAssertEqual(decide(skipMode: .on, wasSeekEntered: true, isScrubbing: true), .none)
    }

    // MARK: Manual modes

    func testOffAndOnPresentManualCard() {
        XCTAssertEqual(decide(skipMode: .off), .presentManual)
        XCTAssertEqual(decide(skipMode: .on), .presentManual)
    }

    func testManualDefersWhenAlreadyPresentingOrScrubbingOrOffSurface() {
        XCTAssertEqual(decide(skipMode: .on, presentingCard: true), .none)
        XCTAssertEqual(decide(skipMode: .on, isScrubbing: true), .none)
        XCTAssertEqual(decide(skipMode: .on, focusIsSurface: false), .none)
    }

    // MARK: Auto-instant (binge)

    func testAutoInstantAdvancesImmediately() {
        XCTAssertEqual(decide(skipMode: .autoInstant), .advance)
    }

    func testAutoInstantDefersWhileScrubbing() {
        XCTAssertEqual(decide(skipMode: .autoInstant, isScrubbing: true), .none)
    }

    // MARK: Auto-delay countdown

    func testAutoDelayArmsThenAdvancesAtDeadline() {
        // Not yet presenting → arm the countdown + present.
        XCTAssertEqual(decide(skipMode: .autoDelay), .beginAutoDelay)
        // Presenting, deadline reached → advance.
        XCTAssertEqual(
            decide(skipMode: .autoDelay, presentingCard: true, autoDelayDeadlineReached: true),
            .advance)
        // Presenting, deadline not reached → hold.
        XCTAssertEqual(
            decide(skipMode: .autoDelay, presentingCard: true, autoDelayDeadlineReached: false),
            .none)
    }

    func testAutoDelayDeadlineDoesNotFireWhileScrubbing() {
        XCTAssertEqual(
            decide(skipMode: .autoDelay, presentingCard: true, isScrubbing: true, autoDelayDeadlineReached: true),
            .none)
    }

    func testAutoDelayArmDefersOffSurface() {
        XCTAssertEqual(decide(skipMode: .autoDelay, focusIsSurface: false), .none)
    }
}
#endif
