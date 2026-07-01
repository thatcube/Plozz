import Foundation

/// The subtitle **behavior** model: *when* and *what* to subtitle, independent of
/// how subtitles look (`SubtitleStyle`) and of per-content-type overrides
/// (`SubtitlePolicy`). This is the behaviour half extracted from the retired
/// `CaptionSettings`, and it is the base input the `SubtitlePolicy` engine
/// inherits from.
///
/// Lives in `CoreModels` (Foundation-only) so Settings can edit it and the policy
/// engine can consume it without importing any UI or AVFoundation.
public struct SubtitleBehavior: Codable, Equatable, Sendable {
    /// Whether automatically-selected subtitles show everything or only forced
    /// passages. Only affects the default on-load selection, not manual choice.
    public var subtitleMode: SubtitleMode
    /// Preferred subtitle language as a BCP-47 / ISO code (e.g. `en`, `eng`).
    /// `nil` means "follow the device language".
    public var preferredSubtitleLanguage: String?
    /// When true, if an item has no suitable subtitle in the preferred language
    /// Plozz searches subtitle providers and asks the server to download the best
    /// match (so every client benefits). Off by default.
    public var autoDownloadSubtitles: Bool

    public init(
        subtitleMode: SubtitleMode = .all,
        preferredSubtitleLanguage: String? = nil,
        autoDownloadSubtitles: Bool = false
    ) {
        self.subtitleMode = subtitleMode
        self.preferredSubtitleLanguage = preferredSubtitleLanguage
        self.autoDownloadSubtitles = autoDownloadSubtitles
    }

    /// The effective preferred subtitle language: the user's explicit choice, or
    /// the device's language when unset. Returns `nil` only if neither is known.
    public var resolvedPreferredLanguage: String? {
        if let preferredSubtitleLanguage, !preferredSubtitleLanguage.isEmpty {
            return preferredSubtitleLanguage
        }
        return LanguageMatch.deviceLanguageCode
    }

    public static let `default` = SubtitleBehavior()
}

// MARK: - Migration from the retired CaptionSettings

public extension SubtitleBehavior {
    /// Seed behaviour from a decoded legacy `CaptionSettings` blob, preserving the
    /// profile's previously-saved subtitle mode / language / auto-download choice.
    init(from legacy: LegacyCaptionSettings) {
        self.init(
            subtitleMode: legacy.subtitleMode,
            preferredSubtitleLanguage: legacy.preferredSubtitleLanguage,
            autoDownloadSubtitles: legacy.autoDownloadSubtitles
        )
    }

    /// Transitional bridge from the still-live `CaptionSettings` so call sites that
    /// haven't migrated to the two-model split keep working. Removed once
    /// `CaptionSettings` is deleted.
    init(from caption: CaptionSettings) {
        self.init(
            subtitleMode: caption.subtitleMode,
            preferredSubtitleLanguage: caption.preferredSubtitleLanguage,
            autoDownloadSubtitles: caption.autoDownloadSubtitles
        )
    }
}

// MARK: - Tolerant decoding (forward-compatible)

extension SubtitleBehavior {
    private enum CodingKeys: String, CodingKey {
        case subtitleMode, preferredSubtitleLanguage, autoDownloadSubtitles
    }

    /// Custom decoder so behaviour persisted by an older build (missing keys added
    /// later) still decodes, each unknown key falling back to its default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SubtitleBehavior.default
        self.init(
            subtitleMode: try c.decodeIfPresent(SubtitleMode.self, forKey: .subtitleMode) ?? d.subtitleMode,
            preferredSubtitleLanguage: try c.decodeIfPresent(String.self, forKey: .preferredSubtitleLanguage),
            autoDownloadSubtitles: try c.decodeIfPresent(Bool.self, forKey: .autoDownloadSubtitles) ?? d.autoDownloadSubtitles
        )
    }
}
