import Foundation

/// User-customisable caption/subtitle appearance (pure data model).
///
/// The spec calls out "full customization of captions". This lives in
/// `CoreModels` so the Settings screen can edit it without importing
/// AVFoundation; `FeaturePlayback` adds an extension that converts it into
/// `AVTextStyleRule`s applied to the player.
public struct CaptionSettings: Codable, Equatable, Sendable {
    public enum EdgeStyle: String, Codable, CaseIterable, Sendable {
        case none, dropShadow, raised, depressed, uniform

        public var displayName: String {
            switch self {
            case .none: return "None"
            case .dropShadow: return "Drop Shadow"
            case .raised: return "Raised"
            case .depressed: return "Depressed"
            case .uniform: return "Outline"
            }
        }
    }

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

    /// An RGBA colour stored in a `Codable`, platform-neutral way (`0...1`).
    public struct RGBAColor: Codable, Equatable, Sendable, Hashable {
        public var red, green, blue, alpha: Double
        public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
            self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
        }
        public static let white = RGBAColor(red: 1, green: 1, blue: 1)
        public static let black = RGBAColor(red: 0, green: 0, blue: 0)
        public static let yellow = RGBAColor(red: 1, green: 0.85, blue: 0)
        public static let clear = RGBAColor(red: 0, green: 0, blue: 0, alpha: 0)

        public static let presets: [(name: String, color: RGBAColor)] = [
            ("White", .white),
            ("Yellow", .yellow),
            ("Black", .black)
        ]
    }

    /// Multiplier applied to caption font size (1.0 == default).
    public var fontScale: Double
    public var textColor: RGBAColor
    public var backgroundColor: RGBAColor
    public var edgeStyle: EdgeStyle
    /// When true, Plozz defers entirely to the system/Settings caption style.
    public var followsSystemStyle: Bool

    /// When true, if an item has no suitable subtitle in the preferred language
    /// Plozz searches subtitle providers and asks the Jellyfin server to
    /// download the best match (so every client benefits). Off by default.
    public var autoDownloadSubtitles: Bool
    /// Whether automatically-selected subtitles show everything or only forced
    /// passages. Only affects the default on-load selection, not manual choice.
    public var subtitleMode: SubtitleMode
    /// Preferred subtitle language as a BCP-47 / ISO code (e.g. `en`, `eng`).
    /// `nil` means "follow the device language".
    public var preferredSubtitleLanguage: String?

    public init(
        fontScale: Double = 1.0,
        textColor: RGBAColor = .white,
        backgroundColor: RGBAColor = RGBAColor(red: 0, green: 0, blue: 0, alpha: 0.5),
        edgeStyle: EdgeStyle = .dropShadow,
        followsSystemStyle: Bool = true,
        autoDownloadSubtitles: Bool = false,
        subtitleMode: SubtitleMode = .all,
        preferredSubtitleLanguage: String? = nil
    ) {
        self.fontScale = fontScale
        self.textColor = textColor
        self.backgroundColor = backgroundColor
        self.edgeStyle = edgeStyle
        self.followsSystemStyle = followsSystemStyle
        self.autoDownloadSubtitles = autoDownloadSubtitles
        self.subtitleMode = subtitleMode
        self.preferredSubtitleLanguage = preferredSubtitleLanguage
    }

    /// The effective preferred subtitle language: the user's explicit choice, or
    /// the device's language when unset. Returns `nil` only if neither is known.
    public var resolvedPreferredLanguage: String? {
        if let preferredSubtitleLanguage, !preferredSubtitleLanguage.isEmpty {
            return preferredSubtitleLanguage
        }
        return LanguageMatch.deviceLanguageCode
    }

    public static let `default` = CaptionSettings()
}

// MARK: - Backward-compatible decoding

extension CaptionSettings {
    private enum CodingKeys: String, CodingKey {
        case fontScale, textColor, backgroundColor, edgeStyle, followsSystemStyle
        case autoDownloadSubtitles, subtitleMode, preferredSubtitleLanguage
    }

    /// Custom decoder so settings persisted before the subtitle fields existed
    /// still decode (the new keys simply fall back to their defaults).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = CaptionSettings.default
        self.init(
            fontScale: try container.decodeIfPresent(Double.self, forKey: .fontScale) ?? fallback.fontScale,
            textColor: try container.decodeIfPresent(RGBAColor.self, forKey: .textColor) ?? fallback.textColor,
            backgroundColor: try container.decodeIfPresent(RGBAColor.self, forKey: .backgroundColor) ?? fallback.backgroundColor,
            edgeStyle: try container.decodeIfPresent(EdgeStyle.self, forKey: .edgeStyle) ?? fallback.edgeStyle,
            followsSystemStyle: try container.decodeIfPresent(Bool.self, forKey: .followsSystemStyle) ?? fallback.followsSystemStyle,
            autoDownloadSubtitles: try container.decodeIfPresent(Bool.self, forKey: .autoDownloadSubtitles) ?? fallback.autoDownloadSubtitles,
            subtitleMode: try container.decodeIfPresent(SubtitleMode.self, forKey: .subtitleMode) ?? fallback.subtitleMode,
            preferredSubtitleLanguage: try container.decodeIfPresent(String.self, forKey: .preferredSubtitleLanguage)
        )
    }
}
