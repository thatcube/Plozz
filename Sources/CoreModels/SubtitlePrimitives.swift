import Foundation

/// Neutral subtitle primitives shared by both the subtitle **behavior** model
/// (`SubtitleBehavior`) and the subtitle **appearance** model (`SubtitleStyle`).
///
/// These were previously nested inside `CaptionSettings`. They are promoted to
/// top-level, dependency-free (`Foundation`-only) types so neither concern owns
/// them: behavior reaches for `SubtitleMode`, appearance reaches for
/// `SubtitleColor`/`SubtitleEdgeStyle`, and the policy engine feeds on
/// `SubtitleMode` — all without one depending on the other or on the (now
/// retired) `CaptionSettings`.

// MARK: - Colour

/// An RGBA colour stored in a `Codable`, platform-neutral way (`0...1`).
///
/// `swiftUIColor` (needs SwiftUI) lives in `CoreUI`; the CoreMedia `argbArray`
/// bridge used by the AVFoundation renderer lives here because it is pure data.
public struct SubtitleColor: Codable, Equatable, Sendable, Hashable {
    public var red, green, blue, alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }

    public static let white = SubtitleColor(red: 1, green: 1, blue: 1)
    public static let black = SubtitleColor(red: 0, green: 0, blue: 0)
    public static let yellow = SubtitleColor(red: 1, green: 0.85, blue: 0)
    public static let lightGray = SubtitleColor(red: 0.78, green: 0.78, blue: 0.78)
    public static let cyan = SubtitleColor(red: 0.25, green: 0.85, blue: 1)
    public static let pink = SubtitleColor(red: 1, green: 0.55, blue: 0.75)
    public static let orange = SubtitleColor(red: 1, green: 0.6, blue: 0.15)
    public static let green = SubtitleColor(red: 0.45, green: 0.85, blue: 0.45)
    public static let clear = SubtitleColor(red: 0, green: 0, blue: 0, alpha: 0)

    /// The curated palette offered by the appearance editor's colour picker.
    public static let presets: [(name: String, color: SubtitleColor)] = [
        ("White", .white),
        ("Yellow", .yellow),
        ("Light Gray", .lightGray),
        ("Cyan", .cyan),
        ("Pink", .pink),
        ("Orange", .orange),
        ("Green", .green),
        ("Black", .black)
    ]

    /// Core Media expects `[alpha, red, green, blue]` doubles in `0...1`.
    public var argbArray: [Double] { [alpha, red, green, blue] }
}

// MARK: - Edge style

/// The glyph edge treatment applied by the caption/subtitle renderer. The
/// CoreMedia (`cmEdgeStyle`) mapping lives in `FeaturePlayback` because it needs
/// AVFoundation; only the platform-neutral display metadata lives here.
public enum SubtitleEdgeStyle: String, Codable, CaseIterable, Sendable {
    case none, dropShadow, raised, depressed, uniform

    public var displayName: String {
        switch self {
        case .none: return "None"
        case .dropShadow: return "Shadow"
        case .raised: return "Raised"
        case .depressed: return "Depressed"
        case .uniform: return "Outline"
        }
    }
}

// MARK: - Subtitle mode

/// Which subtitles to surface automatically when subtitles are desired.
public enum SubtitleMode: String, Codable, CaseIterable, Sendable {
    /// Don't auto-enable any subtitle on load (the viewer can still pick one
    /// manually, and a per-series remembered choice still applies).
    case off
    /// Show full subtitles in the preferred language whenever available.
    case all
    /// Only show "forced" subtitles (e.g. for foreign-language passages),
    /// leaving regular dialogue unsubtitled.
    case forcedOnly

    public var displayName: String {
        switch self {
        case .off: return "Off"
        case .all: return "On"
        case .forcedOnly: return "Forced Only"
        }
    }

    /// One-line explanation shown beneath each option in settings.
    public var detail: String {
        switch self {
        case .off:
            return "Don't turn subtitles on automatically."
        case .all:
            return "Show full subtitles in your preferred language."
        case .forcedOnly:
            return "Only show forced subtitles for foreign-language passages."
        }
    }
}
