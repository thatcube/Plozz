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

    public var displayName: String {
        switch self {
        case .off: "Off"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        }
    }

    public var detail: String {
        switch self {
        case .off: "Keep theme music enabled without playing audio."
        case .low: "A quiet background bed behind the detail page."
        case .medium: "More present, while staying below normal playback volume."
        case .high: "The loudest theme level, still capped below full volume."
        }
    }
}
