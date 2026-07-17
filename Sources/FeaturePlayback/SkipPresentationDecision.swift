import CoreModels
import Foundation

/// The pure "what should the Skip button do right now" policy extracted from
/// `PlayerInputViewController.evaluateSkipPresentation`. Given the live skip
/// context (mode, whether the segment was entered by a deliberate seek, current
/// presentation/focus/scrub state, and whether an auto-delay deadline has been
/// reached), it returns the single action the controller should take.
///
/// Keeping the branching out of the UIKit controller makes the tricky rules —
/// a grace-window seek offers a *manual-only* button (never auto-skip/steal
/// focus), Skip OFF suppresses even a grace seek, and scrubbing/off-surface
/// always defers — directly unit-testable without a view hierarchy.
enum SkipPresentationDecision {
    enum Action: Equatable {
        /// Tear down the Skip button if it's currently presented; otherwise nothing.
        case tearDownIfPresenting
        /// Present the focusable manual Skip button. `stealFocus` is false for a
        /// grace-window seek landing so a deliberate seek is never hijacked.
        case presentManual(stealFocus: Bool)
        /// Skip the segment immediately (auto-instant), no button.
        case autoInstant
        /// Arm the auto-delay countdown and present the button.
        case beginAutoDelay
        /// The auto-delay deadline has been reached — perform the skip now.
        case fireAutoDelay
        /// Do nothing this evaluation.
        case none
    }

    /// Decides the Skip-button action. Callers evaluate this only once the shared
    /// slot belongs to Skip (Up Next inactive, credits not owned by Up Next) and a
    /// skippable segment is active at the current position.
    static func action(
        skipMode: SkipIntrosMode,
        wasSeekEntered: Bool,
        presentingButton: Bool,
        focusIsSurface: Bool,
        isScrubbing: Bool,
        autoDelayDeadlineReached: Bool
    ) -> Action {
        // A seek that landed in the segment's opening grace window offers a manual
        // button only — never auto-skip, never a countdown, never a focus-steal.
        // Skip OFF still suppresses it (markers can be fetched just for Up Next).
        if wasSeekEntered, skipMode != .off {
            guard !presentingButton, focusIsSurface, !isScrubbing else { return .none }
            return .presentManual(stealFocus: false)
        }

        switch skipMode {
        case .off:
            return presentingButton ? .tearDownIfPresenting : .none

        case .on:
            guard !presentingButton, focusIsSurface, !isScrubbing else { return .none }
            return .presentManual(stealFocus: true)

        case .autoInstant:
            return isScrubbing ? .none : .autoInstant

        case .autoDelay:
            if presentingButton {
                // Fire once playback reaches the deadline (deferred while scrubbing;
                // paused skips wait for resume since the countdown tracks position).
                return (autoDelayDeadlineReached && !isScrubbing) ? .fireAutoDelay : .none
            }
            guard focusIsSurface, !isScrubbing else { return .none }
            return .beginAutoDelay
        }
    }
}
