import Foundation

/// Per-profile background theme music preferences for movie and series details.
public struct ThemeMusicSettings: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    public var volume: ThemeMusicVolume

    public init(
        isEnabled: Bool = false,
        volume: ThemeMusicVolume = .low
    ) {
        self.isEnabled = isEnabled
        self.volume = volume
    }

    public static let `default` = ThemeMusicSettings()

    public var shouldPlay: Bool {
        isEnabled && volume != .off
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled, volume
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ThemeMusicSettings.default
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? defaults.isEnabled
        if let token = try container.decodeIfPresent(String.self, forKey: .volume) {
            volume = ThemeMusicVolume(rawValue: token) ?? defaults.volume
        } else {
            volume = defaults.volume
        }
    }
}

public enum ThemeMusicVolume: String, Codable, CaseIterable, Sendable {
    case off
    case low
    case medium
    case high

    public var gain: Float {
        switch self {
        case .off: 0
        case .low: 0.15
        case .medium: 0.35
        case .high: 0.6
        }
    }

    public var displayName: LocalizedStringResource {
        switch self {
        case .off:
            return LocalizedStringResource(
                "themeMusic.off",
                defaultValue: "Off",
                comment: "Theme-music volume option in Settings."
            )
        case .low:
            return LocalizedStringResource(
                "themeMusic.low",
                defaultValue: "Low",
                comment: "Theme-music volume option in Settings."
            )
        case .medium:
            return LocalizedStringResource(
                "themeMusic.medium",
                defaultValue: "Medium",
                comment: "Theme-music volume option in Settings."
            )
        case .high:
            return LocalizedStringResource(
                "themeMusic.high",
                defaultValue: "High",
                comment: "Theme-music volume option in Settings."
            )
        }
    }

    public var detail: LocalizedStringResource {
        switch self {
        case .off:
            return LocalizedStringResource(
                "themeMusic.detail.off",
                defaultValue: "Keep theme music enabled without playing audio.",
                comment: "One-line explanation shown under the theme-music volume picker."
            )
        case .low:
            return LocalizedStringResource(
                "themeMusic.detail.low",
                defaultValue: "A quiet background bed behind the detail page.",
                comment: "One-line explanation shown under the theme-music volume picker."
            )
        case .medium:
            return LocalizedStringResource(
                "themeMusic.detail.medium",
                defaultValue: "More present, while staying below normal playback volume.",
                comment: "One-line explanation shown under the theme-music volume picker."
            )
        case .high:
            return LocalizedStringResource(
                "themeMusic.detail.high",
                defaultValue: "The loudest theme level, still capped below full volume.",
                comment: "One-line explanation shown under the theme-music volume picker."
            )
        }
    }
}
