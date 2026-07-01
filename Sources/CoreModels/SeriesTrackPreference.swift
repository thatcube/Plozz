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

/// Builds the per-series store keys. A profile can hold several servers (Plex +
/// Jellyfin + …) and the user expects a remembered audio/subtitle choice to stick
/// for a show **regardless of which server** an episode happens to come from. So
/// the memory is keyed first by a **cross-server show identity** (the series'
/// external ids — TVDB/TMDB/IMDB/anime dbs), which is the same on every server,
/// and only falls back to a per-server key for shows that carry no external id.
public enum SeriesTrackPreferenceKey {
    /// Per-server fallback key. Account-scoped so two servers' identically
    /// numbered series (e.g. Plex per-server `ratingKey`s) don't collide within a
    /// profile when neither exposes a cross-server external id. The store is
    /// already per-profile namespaced, so this only separates series in one
    /// profile.
    public static func make(sourceAccountID: String?, seriesID: String) -> String {
        "\(sourceAccountID ?? "_"):\(seriesID)"
    }

    /// Stable cross-server show identity keys from the series' external ids, in
    /// match-priority order. Returns **one key per available external id** (a
    /// list, not a single value): two servers may each expose a different subset
    /// of ids (server A has TVDB, server B has TMDB), so writing/reading under
    /// *all* of them lets a match succeed on *any* shared id — mirroring how
    /// `MediaItemIdentity` collapses the same title across servers. Empty when the
    /// item carries no series-level external id (callers then use ``make``).
    public static func crossServerKeys(providerIDs: [String: String]) -> [String] {
        let namespaces: [(ProviderIDNamespace, String)] = [
            (.seriesTvdb, "tvdb"),
            (.seriesTmdb, "tmdb"),
            (.seriesImdb, "imdb"),
            (.seriesAniList, "anilist"),
            (.seriesMal, "mal"),
            (.seriesAniDB, "anidb")
        ]
        return namespaces.compactMap { namespace, label in
            guard let value = providerIDs.providerID(namespace) else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return trimmed.isEmpty ? nil : "show:\(label):\(trimmed)"
        }
    }
}
