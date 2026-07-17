import CoreModels
import Foundation

/// The pure "what should the Up Next card do right now" policy extracted from
/// `PlayerInputViewController.presentUpNextIfNeeded`. Mirrors
/// ``SkipPresentationDecision`` for the shared lower-right slot, but advances to
/// the *next episode* rather than seeking past a segment.
///
/// Given the live context (mode, whether credits were entered by a deliberate
/// seek, current presentation/focus/scrub state, and whether an auto-delay
/// deadline has been reached), it returns the single action the controller
/// should take. Keeping the per-mode branching out of the UIKit controller makes
/// the tricky rules — a grace-window seek presents the card *passively* (no
/// auto-advance, no focus-steal), auto-instant binge-advances with no card, and
/// scrubbing/off-surface always defers — directly unit-testable.
enum UpNextPresentationDecision {
    enum Action: Equatable {
        /// Do nothing this evaluation.
        case none
        /// Present the card without stealing focus (a grace-window seek landed in
        /// credits) so the deliberate seek is never hijacked.
        case presentPassive
        /// Present the focusable card for a manual "Play Next".
        case presentManual
        /// Arm the auto-delay countdown and present the card.
        case beginAutoDelay
        /// Advance to the next episode now (auto-instant, or an auto-delay deadline
        /// reached, or the passive card promoted).
        case advance
    }

    /// Decides the Up Next action. Callers evaluate this only once Up Next owns
    /// the shared slot for the current position.
    static func action(
        skipMode: SkipIntrosMode,
        wasSeekEntered: Bool,
        presentingCard: Bool,
        focusIsSurface: Bool,
        isScrubbing: Bool,
        autoDelayDeadlineReached: Bool
    ) -> Action {
        // A grace-window seek into credits presents the card passively: visible,
        // but the scrub surface keeps focus and nothing auto-advances.
        if wasSeekEntered {
            guard !presentingCard, focusIsSurface, !isScrubbing else { return .none }
            return .presentPassive
        }

        switch skipMode {
        case .off, .on:
            guard !presentingCard, focusIsSurface, !isScrubbing else { return .none }
            return .presentManual

        case .autoInstant:
            // Binge: advance immediately, no card.
            return isScrubbing ? .none : .advance

        case .autoDelay:
            if presentingCard {
                if autoDelayDeadlineReached, !isScrubbing { return .advance }
                return .none
            }
            guard focusIsSurface, !isScrubbing else { return .none }
            return .beginAutoDelay
        }
    }
}
