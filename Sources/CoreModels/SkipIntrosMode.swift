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
    public var title: LocalizedStringResource {
        switch self {
        case .off:
            return LocalizedStringResource(
                "skipIntros.off",
                defaultValue: "Off",
                comment: "Skip-intro behaviour option in Settings > Playback."
            )
        case .on:
            return LocalizedStringResource(
                "skipIntros.on",
                defaultValue: "On",
                comment: "Skip-intro behaviour option in Settings > Playback."
            )
        case .autoDelay:
            return LocalizedStringResource(
                "skipIntros.autoDelay",
                defaultValue: "Auto (delay)",
                comment: "Skip-intro behaviour option in Settings > Playback."
            )
        case .autoInstant:
            return LocalizedStringResource(
                "skipIntros.autoInstant",
                defaultValue: "Auto (instant)",
                comment: "Skip-intro behaviour option in Settings > Playback."
            )
        }
    }

    /// One-line explanation shown beneath each option in settings.
    public var detail: LocalizedStringResource {
        switch self {
        case .off:
            return LocalizedStringResource(
                "skipIntros.detail.off",
                defaultValue: "Never skip intros or credits.",
                comment: "One-line explanation shown under the skip-intro picker."
            )
        case .on:
            return LocalizedStringResource(
                "skipIntros.detail.on",
                defaultValue: "Show a Skip button during intros and credits.",
                comment: "One-line explanation shown under the skip-intro picker."
            )
        case .autoDelay:
            return LocalizedStringResource(
                "skipIntros.detail.autoDelay",
                defaultValue: "Show a Skip button, then skip automatically after a few seconds.",
                comment: "One-line explanation shown under the skip-intro picker."
            )
        case .autoInstant:
            return LocalizedStringResource(
                "skipIntros.detail.autoInstant",
                defaultValue: "Skip intros and credits automatically, the instant they start.",
                comment: "One-line explanation shown under the skip-intro picker."
            )
        }
    }

    /// Whether skip markers should be fetched at all (any mode except Off).
    public var fetchesMarkers: Bool { self != .off }

    /// Whether the player skips without a button press (delay or instant).
    public var isAutomatic: Bool { self == .autoDelay || self == .autoInstant }
}
