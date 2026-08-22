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
        autoDelayDeadlineReached: Bool = false,
        autoPlayEnabled: Bool = true
    ) -> UpNextPresentationDecision.Action {
        UpNextPresentationDecision.action(
            skipMode: skipMode,
            wasSeekEntered: wasSeekEntered,
            presentingCard: presentingCard,
            focusIsSurface: focusIsSurface,
            isScrubbing: isScrubbing,
            autoDelayDeadlineReached: autoDelayDeadlineReached,
            autoPlayEnabled: autoPlayEnabled)
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
    // MARK: Autoplay off (#22) — never advance on its own, still offer the card

    /// The whole point of the setting: no mode may advance without being asked.
    func testAutoPlayOffNeverAdvancesInAnyMode() {
        for mode in SkipIntrosMode.allCases {
            XCTAssertNotEqual(
                decide(skipMode: mode, autoPlayEnabled: false), .advance,
                "mode: \(mode)")
            XCTAssertNotEqual(
                decide(skipMode: mode, autoPlayEnabled: false), .beginAutoDelay,
                "mode: \(mode)")
        }
    }

    /// The auto modes degrade to the manual card rather than vanishing — the
    /// viewer keeps the one-press shortcut, they just aren't moved along.
    func testAutoPlayOffTurnsAutoModesIntoTheManualCard() {
        XCTAssertEqual(decide(skipMode: .autoInstant, autoPlayEnabled: false), .presentManual)
        XCTAssertEqual(decide(skipMode: .autoDelay, autoPlayEnabled: false), .presentManual)
    }

    /// Even with the card already up and its countdown elapsed, an autoplay-off
    /// profile holds — the deadline is an automatic advance like any other.
    func testAutoPlayOffIgnoresAnElapsedAutoDelayDeadline() {
        XCTAssertEqual(
            decide(
                skipMode: .autoDelay,
                presentingCard: true,
                autoDelayDeadlineReached: true,
                autoPlayEnabled: false),
            .none)
    }

    /// Autoplay doesn't change the grace-window rule: a deliberate seek into
    /// credits still presents passively and still steals nothing.
    func testAutoPlayOffKeepsTheSeekGraceBehaviour() {
        XCTAssertEqual(
            decide(skipMode: .autoInstant, wasSeekEntered: true, autoPlayEnabled: false),
            .presentPassive)
    }

    /// And with autoplay on, every existing behaviour is untouched.
    func testAutoPlayOnLeavesTheAutoModesAlone() {
        XCTAssertEqual(decide(skipMode: .autoInstant, autoPlayEnabled: true), .advance)
        XCTAssertEqual(decide(skipMode: .autoDelay, autoPlayEnabled: true), .beginAutoDelay)
    }
}
#endif
