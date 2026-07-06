import Foundation

/// How many seconds *earlier* than the saved resume point playback should start
/// when you return to a partially-watched title ("resume rewind" / "smart
/// resume"). A gentle nudge to re-establish context after stepping away — not a
/// full skip (the remote's skip-back button covers bigger jumps).
///
/// Distinct from `SkipInterval` (the remote left/right skip): this only applies
/// once, at the moment a resume begins, and includes an explicit **0** (off)
/// value for the exact-resume behaviour most video apps ship. Modelled as data
/// so the default can move with feedback and presets can be tuned without a
/// rewrite.
///
/// The preset ladder is deliberately non-uniform so it's easy to dial in: **1s
/// steps from 0–10s**, then **5s steps to 30s**, then **15s steps to 60s**. The
/// settings stepper walks these values in order (its ± buttons move one preset at
/// a time), giving fine control where people care most and coarse jumps up top.
public enum ResumeRewindInterval: Int, Codable, CaseIterable, Hashable, Sendable {
    /// No rewind — resume exactly at the saved point (classic Plex/Netflix feel).
    case off = 0
    // 1-second resolution through the low end, where people dial in the most.
    case one = 1
    case two = 2
    case three = 3
    case four = 4
    case five = 5
    case six = 6
    case seven = 7
    case eight = 8
    case nine = 9
    case ten = 10
    // 5-second steps to 30s.
    case fifteen = 15
    case twenty = 20
    case twentyFive = 25
    case thirty = 30
    // 15-second steps to a 1-minute cap.
    case fortyFive = 45
    case sixty = 60

    /// Rewind amount in seconds (`0` for `.off`).
    public var seconds: TimeInterval { TimeInterval(rawValue) }

    /// Human-readable label for the settings stepper (e.g. "5 sec"). `.off` reads
    /// "0 sec" so the preset ladder is unambiguously **0 to 60 seconds** rather
    /// than an opaque "Off" that looks like a separate switch.
    public var title: String { "\(rawValue) sec" }

    /// A cohesive one-line summary of the *effect* of the current value, shown as
    /// live helper text beneath the stepper so the setting explains itself as you
    /// dial it. `.off` states it's off; every other value says how much earlier
    /// playback resumes (with correct singular/plural at 1 second).
    public var effectDescription: String {
        switch rawValue {
        case 0:  return "Rewind on resume is off."
        case 1:  return "Media will resume 1 second earlier."
        default: return "Media will resume \(rawValue) seconds earlier."
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
