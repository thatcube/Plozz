import Foundation

/// How many seconds *earlier* than the saved resume point playback should start
/// when you return to a partially-watched title ("resume rewind" / "smart
/// resume"). A gentle nudge to re-establish context after stepping away — not a
/// full skip (the remote's skip-back button covers bigger jumps).
///
/// Distinct from `SkipInterval` (the remote left/right skip): this only applies
/// once, at the moment a resume begins, and offers an explicit **Off** case for
/// the exact-resume behaviour most video apps ship. Modelled as data so the
/// default can move with feedback and presets can be tuned without a rewrite.
public enum ResumeRewindInterval: Int, Codable, CaseIterable, Hashable, Sendable {
    /// No rewind — resume exactly at the saved point (classic Plex/Netflix feel).
    case off = 0
    case five = 5
    case ten = 10
    case fifteen = 15
    case thirty = 30

    /// Rewind amount in seconds (`0` for `.off`).
    public var seconds: TimeInterval { TimeInterval(rawValue) }

    /// Human-readable label for the settings picker (e.g. "5 sec", "Off").
    public var title: String {
        switch self {
        case .off:     return "Off"
        case .five:    return "5 sec"
        case .ten:     return "10 sec"
        case .fifteen: return "15 sec"
        case .thirty:  return "30 sec"
        }
    }

    /// Applies the rewind to a resume position, returning where playback should
    /// actually start. Pure so it can be unit-tested without a player/engine.
    ///
    /// - A non-positive `position` (a fresh start / "start over") is returned
    ///   unchanged — never rewound below the beginning.
    /// - `.off` (or any zero-second amount) is a no-op.
    /// - Otherwise the result is `position - seconds`, clamped to `0` so a resume
    ///   point smaller than the rewind simply starts from the beginning.
    public func applied(to position: TimeInterval) -> TimeInterval {
        guard position > 0, seconds > 0 else { return position }
        return max(0, position - seconds)
    }
}
