import Foundation

/// User-customisable caption/subtitle appearance (pure data model).
///
/// The spec calls out "full customization of captions". This lives in
/// `CoreModels` so the Settings screen can edit it without importing
/// AVFoundation; `FeaturePlayback` adds an extension that converts it into
/// `AVTextStyleRule`s applied to the player.
public struct CaptionSettings: Codable, Equatable, Sendable {
    // Transitional typealiases: the primitives moved out to top-level
    // (`SubtitleColor`/`SubtitleEdgeStyle`/`SubtitleMode`) so behavior and style
    // can share them without `CaptionSettings`. These aliases keep existing
    // `CaptionSettings.{RGBAColor,EdgeStyle,SubtitleMode}` references compiling
    // during the migration; both they and this whole type are deleted once every
    // call site is repointed.
    public typealias EdgeStyle = SubtitleEdgeStyle
    public typealias SubtitleMode = CoreModels.SubtitleMode
    public typealias RGBAColor = SubtitleColor

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
