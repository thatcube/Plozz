import Foundation

/// How the player handles server-detected intro/credits markers, mirroring the
/// four-way control in Infuse (Off / On / Auto (delay) / Auto (instant)).
///
///  * `.off` — never skip; markers aren't even fetched.
///  * `.on` — show a focusable **Skip** button while inside a marker (manual).
///  * `.autoDelay` — show the Skip button, then skip automatically after a short
///    grace period if the viewer doesn't act (the button is the chance to skip
///    immediately, or swipe-up to cancel the auto-skip).
///  * `.autoInstant` — skip the moment playback enters a marker, with only a
///    brief on-screen "Skipping…" notice.
public enum SkipIntrosMode: String, Codable, CaseIterable, Sendable {
    case off
    case on
    case autoDelay
    case autoInstant

    /// Seconds of playback the Skip button stays before `.autoDelay` jumps. Tied
    /// to playback position (not wall-clock) so it pauses with the video and the
    /// button's countdown ring depletes in lock-step.
    public static let autoSkipDelay: TimeInterval = 5

    /// Short label for the settings picker / summaries.
    public var title: String {
        switch self {
        case .off: return "Off"
        case .on: return "On"
        case .autoDelay: return "Auto (delay)"
        case .autoInstant: return "Auto (instant)"
        }
    }

    /// One-line explanation shown beneath each option in settings.
    public var detail: String {
        switch self {
        case .off:
            return "Never skip intros or credits."
        case .on:
            return "Show a Skip button during intros and credits."
        case .autoDelay:
            return "Show a Skip button, then skip automatically after a few seconds."
        case .autoInstant:
            return "Skip intros and credits automatically, the instant they start."
        }
    }

    /// Whether skip markers should be fetched at all (any mode except Off).
    public var fetchesMarkers: Bool { self != .off }

    /// Whether the player skips without a button press (delay or instant).
    public var isAutomatic: Bool { self == .autoDelay || self == .autoInstant }
}
