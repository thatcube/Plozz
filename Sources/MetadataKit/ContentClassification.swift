import Foundation
import CoreModels

/// The kind of content a media item represents, used to *route* metadata/artwork
/// lookups to the provider that does that content type best (e.g. anime → AniList,
/// western TV → TMDb/TVmaze). This is the heart of the scalable provider design:
/// each content type is served by the free, keyless API that covers it best.
public enum ContentType: String, Sendable, Hashable {
    /// Japanese animation (anime series or films). Served keyless by AniList/Kitsu.
    case anime
    /// A live-action / western film.
    case movie
    /// A live-action / western television series.
    case tvShow
    /// A music artist / album / track (handled via the music query path).
    case music
    /// Couldn't be classified; treated like a generic movie/TV title.
    case unknown
}

/// Pure, dependency-free classification of a ``MediaItem`` into a ``ContentType``.
///
/// Kept out of the UI and provider layers so the decision is one testable place.
/// Anime detection is deliberately generous (the maintainer's primary user watches
/// mostly anime): any anime-database id (AniList / AniDB / MAL / Kitsu / Shoko) or
/// an "Anime" genre/tag flips an otherwise-TV/movie item to ``ContentType/anime``.
public enum ContentClassifier {
    /// Provider-id keys (case-insensitive, substring match) that mark an item as
    /// anime. Shoko/Jellyfin stamp these onto `ProviderIds`.
    private static let animeIDKeys = ["anilist", "anidb", "myanimelist", "shoko", "kitsu"]

    /// Genre/tag labels (case-insensitive) that mark an item as anime even when no
    /// anime-database id is present (e.g. a plain TMDb-matched anime).
    private static let animeLabels = ["anime"]

    public static func classify(_ item: MediaItem) -> ContentType {
        if isAnime(item) { return .anime }
        switch item.kind {
        case .movie, .video:
            return .movie
        case .series, .season, .episode:
            return .tvShow
        case .folder, .collection, .unknown:
            return .unknown
        }
    }

    /// The subtitle-policy content category for `item` (design §5.0). Bridges the
    /// routing-oriented ``ContentType`` onto the persistence-friendly
    /// ``SubtitleContentCategory`` the per-content-type subtitle policy is keyed
    /// on, so the player can resolve "forced-only on movies, full subs on anime"
    /// without the playback layer re-running classification logic. `music` and
    /// `unknown` map to ``SubtitleContentCategory/other`` (the profile base).
    public static func subtitleCategory(for item: MediaItem) -> SubtitleContentCategory {
        classify(item).subtitleCategory
    }

    /// The per-content-type **audio** policy category for `item` — the same
    /// content taxonomy the subtitle policy uses (anime vs movie vs TV), surfaced
    /// under an audio-named accessor so the audio path reads cleanly. Lets the
    /// player resolve "original audio for anime, device language for everything
    /// else" without re-running classification logic.
    public static func audioCategory(for item: MediaItem) -> ContentCategory {
        classify(item).subtitleCategory
    }

    /// `true` when the provider-id key names an anime database (AniList / AniDB /
    /// MyAnimeList / Shoko / Kitsu), tolerant of the casing/punctuation each
    /// backend uses. Lets callers copy just a series' anime ids onto its episodes.
    public static func isAnimeProviderIDKey(_ key: String) -> Bool {
        let normalized = key.lowercased()
        if animeIDKeys.contains(where: { normalized.contains($0) }) { return true }
        // Common short aliases the substring list above doesn't cover.
        return ["mal", "anilistid", "anidbid"].contains(normalized)
    }

    /// `true` when the item carries any anime-database id or an "Anime" genre/tag.
    public static func isAnime(_ item: MediaItem) -> Bool {
        // Prefer the normalized namespace lookups (tolerant of provider key
        // casing/punctuation across Jellyfin and Plex) for the common anime dbs.
        if item.providerID(.aniList) != nil
            || item.providerID(.myAnimeList) != nil
            || item.providerID(.aniDB) != nil {
            return true
        }
        // Kitsu/Shoko have no `ProviderIDNamespace` case; match them (and any
        // other anime-db id) by normalized-key substring as a fallback.
        let normalizedKeys = item.providerIDs.normalizedProviderIDs.keys
        for key in normalizedKeys {
            if animeIDKeys.contains(where: { key.contains($0) }) { return true }
        }
        let labels = (item.genres + item.tags).map { $0.lowercased() }
        return labels.contains { label in animeLabels.contains { label.contains($0) } }
    }

    /// Best-effort ORIGINAL audio language (ISO-639-1, lowercased) for the
    /// "prefer original language" audio policy.
    ///
    /// Prefers **real metadata**: when the item carries an ``MediaItem/originalLanguage``
    /// (filled from a provider's `original_language`/`originalLanguage`/`language`
    /// field — see the Step-5 enrichment pipeline), that authoritative value wins,
    /// normalized to ISO-639-1. Only when no metadata value exists does it fall back
    /// to the heuristic that anime is overwhelmingly Japanese-original (`.anime` →
    /// `"ja"`) — and that fallback is deliberately last so a non-Japanese "anime"
    /// (Chinese donghua, Korean, …) whose true original language the providers
    /// supplied is served correctly rather than always Japanese. Everything else with
    /// no metadata returns `nil`, letting the caller defer to the container's default
    /// track (the best available proxy for "original" when nothing is known).
    public static func originalAudioLanguage(for item: MediaItem) -> String? {
        if let normalized = LanguageMatch.normalized(item.originalLanguage) {
            return normalized
        }
        return classify(item) == .anime ? "ja" : nil
    }
}

public extension ContentType {
    /// Maps a routing `ContentType` onto the CoreModels-local subtitle-policy
    /// axis, so the per-content-type subtitle policy can key off the same
    /// classification without CoreModels depending on MetadataKit. Music and
    /// unclassified content fall to `.other`, which always uses the profile base.
    var subtitleCategory: SubtitleContentCategory {
        switch self {
        case .anime: return .anime
        case .movie: return .movie
        case .tvShow: return .tvShow
        case .music, .unknown: return .other
        }
    }
}

/// The anime-database identifiers extracted from a ``MediaItem``'s provider ids,
/// tolerating the differing key casing each backend uses. Used to query AniList by
/// a stable id (far more reliable than a fuzzy romaji/english title search).
public struct AnimeIDs: Sendable, Equatable, Hashable {
    public var anilist: Int?
    public var mal: Int?
    public var anidb: Int?
    public var kitsu: String?

    public init(anilist: Int? = nil, mal: Int? = nil, anidb: Int? = nil, kitsu: String? = nil) {
        self.anilist = anilist
        self.mal = mal
        self.anidb = anidb
        self.kitsu = kitsu
    }

    public var isEmpty: Bool { anilist == nil && mal == nil && anidb == nil && kitsu == nil }

    public init(from item: MediaItem) {
        var ids = AnimeIDs()
        // Resolve the major anime databases through the normalized namespace so
        // differing provider key casing (`AniList`, `anilistid`, `MAL`, …) and
        // Plex/Jellyfin both map to the same id.
        if let value = item.providerID(.aniList) { ids.anilist = Int(value) }
        if let value = item.providerID(.myAnimeList) { ids.mal = Int(value) }
        if let value = item.providerID(.aniDB) { ids.anidb = Int(value) }
        // Kitsu has no `ProviderIDNamespace` case; pull it by normalized key.
        for (key, value) in item.providerIDs.normalizedProviderIDs where key.contains("kitsu") {
            ids.kitsu = value
            break
        }
        self = ids
    }
}
