import Foundation

/// Preset skip-forward / skip-backward intervals for the player's left/right
/// remote presses. Each case maps to a matching SF Symbol (`goforward.N` /
/// `gobackward.N`) so the in-player glyph always reflects the active setting.
///
/// Presets mirror the values widely used across streaming apps (Plex, Infuse,
/// YouTube, Swiftfin, Jellyfin Web) — covering quick-step (5 s), standard
/// (10 s), moderate (15 / 30 s) and long-skip (60 s) use cases.
public enum SkipInterval: Int, Codable, CaseIterable, Hashable, Sendable {
    case five = 5
    case ten = 10
    case fifteen = 15
    case thirty = 30
    case sixty = 60

    /// Interval in seconds.
    public var seconds: TimeInterval { TimeInterval(rawValue) }

    /// Human-readable label for the settings picker (e.g. "10 seconds").
    public var title: String {
        switch self {
        case .five:    return "5 sec"
        case .ten:     return "10 sec"
        case .fifteen: return "15 sec"
        case .thirty:  return "30 sec"
        case .sixty:   return "60 sec"
        }
    }

    /// SF Symbol name for the forward-skip glyph (e.g. `goforward.10`).
    public var forwardSymbol: String { "goforward.\(rawValue)" }

    /// SF Symbol name for the backward-skip glyph (e.g. `gobackward.10`).
    public var backwardSymbol: String { "gobackward.\(rawValue)" }
}
