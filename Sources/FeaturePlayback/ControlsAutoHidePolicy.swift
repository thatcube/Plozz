import Foundation

/// Pure auto-hide decisions for the player transport (the control bar), extracted
/// from `PlayerInputViewController.scheduleAutoHide`. Only the async orchestration
/// (polling the engine for confirmed forward motion, the sleeps, the actual
/// `controlsVisible` mutation) stays in the controller; the two *decisions* live
/// here so the semantics — which took many on-device iterations to settle — are
/// pinned by direct unit tests instead of only being reachable through a live
/// engine and view hierarchy.
enum ControlsAutoHidePolicy {
    /// Grace after the load finishes (playhead confirmed advancing) before the
    /// transport may hide.
    static let postLoadGrace: TimeInterval = 1.0
    /// Floor measured from the last input (a reveal, skip, or control-bar focus
    /// move) — the transport never hides sooner than this after the viewer acted.
    static let minSinceInput: TimeInterval = 4.0
    /// The same floor while the Info card is open. Longer because the card is
    /// something to READ — a synopsis, episode number, runtime and badges — rather
    /// than a row of buttons to act on, so the 4s that suits the transport cuts a
    /// viewer off mid-sentence.
    static let minSinceInputWithInfoCard: TimeInterval = 9.0

    /// When the transport should hide: 1s after the load finishes, but never
    /// sooner than the input floor. A long load therefore clears the transport
    /// quickly once the picture is genuinely up, while a short load or a hands-on
    /// interaction keeps the controls around for the time the viewer needs to act on
    /// what they just summoned — longer when that's the Info card, which is read
    /// rather than operated.
    static func hideDate(loadDoneAt: Date, inputAt: Date, infoCardOpen: Bool = false) -> Date {
        let floor = infoCardOpen ? minSinceInputWithInfoCard : minSinceInput
        return max(loadDoneAt.addingTimeInterval(postLoadGrace),
                   inputAt.addingTimeInterval(floor))
    }

    /// Where tvOS focus currently lives — mirrors the controller's private
    /// `FocusContext` so this stays a pure, dependency-free decision.
    enum Focus: Equatable { case surface, controlBar, skipButton, upNext }

    /// What the countdown should do when it finally fires.
    enum Outcome: Equatable {
        /// Mid-interaction — leave the transport up. Each of these states re-arms
        /// auto-hide when it ends (a scrub commit, a resume, or a menu-close
        /// activity bump), so the caller can safely end the task rather than loop.
        case stayVisible
        /// Hide in place (focus already on the scrub surface).
        case hide
        /// Idle in the control bar with no menu open — hand focus back to the
        /// scrub surface first so we never leave a focused-but-invisible bar,
        /// then hide.
        case returnFocusThenHide
        /// A focused Skip / Up Next affordance owns the screen; don't hide the
        /// transport out from under it.
        case keepForAffordance
    }

    /// Resolve the fire-time outcome. The interaction flags pin the transport
    /// while the viewer is mid-gesture, paused (the controls *are* the pause UI),
    /// or has an options menu open — regardless of where focus sits.
    static func outcome(focus: Focus,
                        isScrubbing: Bool,
                        isPaused: Bool,
                        isPanelOpen: Bool) -> Outcome {
        if isScrubbing || isPaused || isPanelOpen { return .stayVisible }
        switch focus {
        case .surface: return .hide
        case .controlBar: return .returnFocusThenHide
        case .skipButton, .upNext: return .keepForAffordance
        }
    }
}
