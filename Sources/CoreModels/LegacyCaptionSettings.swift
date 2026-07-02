import Foundation

/// A decode-only mirror of the retired `CaptionSettings` persisted shape, used
/// purely for one-time migration of a profile's saved subtitle preferences into
/// the new split stores (`SubtitleBehavior` + `SubtitleStyle`).
///
/// It is keyed the same as the old model (`com.plozz.captionSettings`) and its
/// `Codable` layout matches the old `CaptionSettings` exactly, so data written by
/// any prior build decodes here. Nothing writes this type — after the new stores
/// seed themselves from it, it is never touched again. The neutral primitives it
/// uses (`SubtitleColor`/`SubtitleEdgeStyle`/`SubtitleMode`) share the same
/// `String` raw values and `Codable` shape as the old nested types, so decoding
/// is byte-compatible.
public struct LegacyCaptionSettings: Codable, Equatable, Sendable {
    public var fontScale: Double
    public var textColor: SubtitleColor
    public var backgroundColor: SubtitleColor
    public var edgeStyle: SubtitleEdgeStyle
    public var followsSystemStyle: Bool
    public var autoDownloadSubtitles: Bool
    public var subtitleMode: SubtitleMode
    public var preferredSubtitleLanguage: String?

    /// The `UserDefaults` base key the old `CaptionSettingsStore` persisted under.
    public static let storageKey = "com.plozz.captionSettings"

    public init(
        fontScale: Double = 1.0,
        textColor: SubtitleColor = .white,
        backgroundColor: SubtitleColor = SubtitleColor(red: 0, green: 0, blue: 0, alpha: 0.5),
        edgeStyle: SubtitleEdgeStyle = .dropShadow,
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

    private enum CodingKeys: String, CodingKey {
        case fontScale, textColor, backgroundColor, edgeStyle, followsSystemStyle
        case autoDownloadSubtitles, subtitleMode, preferredSubtitleLanguage
    }

    /// Tolerant decoder matching the old model: missing keys fall back to the
    /// same defaults the old `CaptionSettings` used, so partial persisted blobs
    /// still migrate cleanly.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = LegacyCaptionSettings()
        self.init(
            fontScale: try container.decodeIfPresent(Double.self, forKey: .fontScale) ?? fallback.fontScale,
            textColor: try container.decodeIfPresent(SubtitleColor.self, forKey: .textColor) ?? fallback.textColor,
            backgroundColor: try container.decodeIfPresent(SubtitleColor.self, forKey: .backgroundColor) ?? fallback.backgroundColor,
            edgeStyle: try container.decodeIfPresent(SubtitleEdgeStyle.self, forKey: .edgeStyle) ?? fallback.edgeStyle,
            followsSystemStyle: try container.decodeIfPresent(Bool.self, forKey: .followsSystemStyle) ?? fallback.followsSystemStyle,
            autoDownloadSubtitles: try container.decodeIfPresent(Bool.self, forKey: .autoDownloadSubtitles) ?? fallback.autoDownloadSubtitles,
            subtitleMode: try container.decodeIfPresent(SubtitleMode.self, forKey: .subtitleMode) ?? fallback.subtitleMode,
            preferredSubtitleLanguage: try container.decodeIfPresent(String.self, forKey: .preferredSubtitleLanguage)
        )
    }

    /// Loads the legacy blob for a profile namespace, or `nil` if none was ever
    /// persisted (a fresh install, or already-migrated + cleared).
    public static func load(from defaults: UserDefaults, namespace: String?) -> LegacyCaptionSettings? {
        let key = SettingsKey.scoped(storageKey, namespace: namespace)
        guard let data = defaults.data(forKey: key),
              let legacy = try? JSONDecoder().decode(LegacyCaptionSettings.self, from: data) else {
            return nil
        }
        return legacy
    }
}
