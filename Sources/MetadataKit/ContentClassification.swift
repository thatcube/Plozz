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
