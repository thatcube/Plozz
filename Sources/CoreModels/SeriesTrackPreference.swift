import Foundation

/// A remembered subtitle decision for a series: either a concrete language to
/// re-match on each episode, or an explicit **Off** (the viewer turned subtitles
/// off and wants that to stick for the show). `nil` at the call sites means "no
/// memory yet", distinct from a remembered `.off`.
public enum RememberedSubtitleSelection: Codable, Equatable, Sendable {
    case off
    case language(String)
}

/// The per-series remembered audio/subtitle choices for one profile. Stored by
/// **language** (not track id, which differs per episode/file) so it re-resolves
/// to a concrete track on each episode.
public struct SeriesTrackPreference: Codable, Equatable, Sendable {
    /// Remembered audio language (ISO-639), or `nil` if the viewer never set one.
    public var audioLanguage: String?
    /// Remembered subtitle decision, or `nil` if never set.
    public var subtitle: RememberedSubtitleSelection?

    public init(audioLanguage: String? = nil, subtitle: RememberedSubtitleSelection? = nil) {
        self.audioLanguage = audioLanguage
        self.subtitle = subtitle
    }

    /// `true` when nothing is remembered, so the store can drop the entry instead
    /// of persisting empties.
    public var isEmpty: Bool { audioLanguage == nil && subtitle == nil }
}

/// Builds the per-series store key, namespacing by the owning source account so
/// the same series id served by two different servers never collides. The store
/// itself is already per-profile namespaced, so this key only needs to separate
/// series within one profile.
public enum SeriesTrackPreferenceKey {
    public static func make(sourceAccountID: String?, seriesID: String) -> String {
        "\(sourceAccountID ?? "_"):\(seriesID)"
    }
}
