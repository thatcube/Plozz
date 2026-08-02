import Foundation

/// Canonical external-id namespaces used across metadata/artwork/rating
/// enrichment. Each namespace resolves through a set of provider-specific key
/// aliases (`Imdb`, `IMDb`, `myanimelist`, …) found in `MediaItem.providerIDs`.
public enum ProviderIDNamespace: String, Codable, Hashable, Sendable, CaseIterable {
    case imdb
    case tmdb
    case tvdb
    case tvmaze
    case aniList
    case myAnimeList
    case aniDB

    case seriesImdb
    case seriesTmdb
    case seriesTvdb
    case seriesTvmaze
    case seriesAniList
    case seriesMal
    case seriesAniDB

    case musicBrainzReleaseGroup
    case musicBrainzRelease
    case musicBrainzTrack
    case musicBrainzArtist

    /// The key to *write* an id under so ``providerID(_:)`` finds it again. Lookup
    /// is alias- and punctuation-insensitive, so this only has to normalize to one
    /// of ``aliases`` — it uses the spelling the rest of the app already writes.
    public var canonicalKey: String {
        switch self {
        case .imdb: return "Imdb"
        case .tmdb: return "Tmdb"
        case .tvdb: return "Tvdb"
        case .tvmaze: return "TvMaze"
        case .aniList: return "AniList"
        case .myAnimeList: return "Mal"
        case .aniDB: return "AniDB"
        case .seriesImdb: return "SeriesImdb"
        case .seriesTmdb: return "SeriesTmdb"
        case .seriesTvdb: return "SeriesTvdb"
        case .seriesTvmaze: return "SeriesTvMaze"
        case .seriesAniList: return "SeriesAniList"
        case .seriesMal: return "SeriesMal"
        case .seriesAniDB: return "SeriesAniDB"
        case .musicBrainzReleaseGroup: return "MusicBrainzReleaseGroup"
        case .musicBrainzRelease: return "MusicBrainzRelease"
        case .musicBrainzTrack: return "MusicBrainzTrack"
        case .musicBrainzArtist: return "MusicBrainzArtist"
        }
    }

    fileprivate var aliases: [String] {
        switch self {
        // Spellings vary by whoever wrote the id. Jellyfin writes "Tmdb"; Shoko
        // writes "TheMovieDb"; some agents append "ID" or ".com". Keys are
        // normalized to lowercase alphanumerics before comparison, so each alias
        // here is that normalized form. Missing one doesn't degrade a lookup — it
        // makes the id invisible, which is how a Shoko-managed anime library
        // appeared to carry no TMDb id at all.
        case .imdb: return ["imdb", "imdbid"]
        case .tmdb: return ["tmdb", "tmdbid", "themoviedb", "themoviedbcom", "moviedb"]
        case .tvdb: return ["tvdb", "thetvdb", "tvdbid", "thetvdbcom"]
        case .tvmaze: return ["tvmaze", "tvmazeid"]
        case .aniList: return ["anilist", "anilistid"]
        case .myAnimeList: return ["myanimelist", "myanimelistid", "mal"]
        case .aniDB: return ["anidb", "anidbid"]

        case .seriesImdb: return ["seriesimdb"]
        case .seriesTmdb: return ["seriestmdb", "seriesthemoviedb"]
        case .seriesTvdb: return ["seriestvdb", "seriesthetvdb"]
        case .seriesTvmaze: return ["seriestvmaze"]
        case .seriesAniList: return ["seriesanilist"]
        case .seriesMal: return ["seriesmal", "seriesmyanimelist"]
        case .seriesAniDB: return ["seriesanidb"]

        case .musicBrainzReleaseGroup:
            return ["musicbrainzreleasegroup", "musicbrainzreleasegroupid", "mbreleasegroupid"]
        case .musicBrainzRelease:
            return ["musicbrainzrelease", "musicbrainzreleaseid", "mbreleaseid", "musicbrainzalbum"]
        case .musicBrainzTrack:
            return ["musicbrainztrack", "musicbrainztrackid", "mbrecordingid"]
        case .musicBrainzArtist:
            return ["musicbrainzartist", "musicbrainzartistid", "mbartistid", "musicbrainzalbumartist"]
        }
    }
}

public extension Dictionary where Key == String, Value == String {
    /// Returns a normalized id value for `namespace`, resolving known key aliases
    /// case-insensitively and punctuation-insensitively.
    func providerID(_ namespace: ProviderIDNamespace) -> String? {
        let normalized = normalizedProviderIDs
        for alias in namespace.aliases {
            if let value = normalized[normalizeProviderIDKey(alias)] {
                return value
            }
        }
        return nil
    }

    /// Fills missing show-level namespaces from another item's series ids first,
    /// then its ordinary ids. Used when an episode is replaced by a freshly fetched
    /// provider record: the new episode carries episode-level TMDb/TVDB ids, while
    /// schedule/scrobble lookups still need the parent show's ids.
    mutating func mergeSeriesProviderIDs(from source: [String: String]) {
        let mappings: [
            (series: ProviderIDNamespace, base: ProviderIDNamespace)
        ] = [
            (.seriesImdb, .imdb),
            (.seriesTmdb, .tmdb),
            (.seriesTvdb, .tvdb),
            (.seriesTvmaze, .tvmaze),
            (.seriesAniList, .aniList),
            (.seriesMal, .myAnimeList),
            (.seriesAniDB, .aniDB),
        ]
        for mapping in mappings where providerID(mapping.series) == nil {
            guard let value =
                source.providerID(mapping.series)
                    ?? source.providerID(mapping.base) else {
                continue
            }
            self[mapping.series.canonicalKey] = value
        }
    }

    /// Removes every spelling/alias of `namespace`.
    mutating func removeProviderID(_ namespace: ProviderIDNamespace) {
        let aliases = Set(namespace.aliases.map(normalizeProviderIDKey))
        self = filter {
            !aliases.contains(normalizeProviderIDKey($0.key))
        }
    }

    /// Canonicalized provider-id map keyed by lowercased alphanumeric tokens.
    /// Example: `["TMDb ID": "278"]` becomes `["tmdbid": "278"]`.
    var normalizedProviderIDs: [String: String] {
        var normalized: [String: String] = [:]
        for (key, value) in self {
            guard let cleanedValue = sanitizeProviderIDValue(value) else { continue }
            let normalizedKey = normalizeProviderIDKey(key)
            if normalized[normalizedKey] == nil {
                normalized[normalizedKey] = cleanedValue
            }
        }
        return normalized
    }
}

public extension MediaItem {
    /// Convenience lookup over `providerIDs`.
    func providerID(_ namespace: ProviderIDNamespace) -> String? {
        providerIDs.providerID(namespace)
    }

    /// Best-effort anime detection for routing keyless anime providers.
    var isLikelyAnime: Bool {
        if providerID(.aniList) != nil || providerID(.myAnimeList) != nil || providerID(.aniDB) != nil {
            return true
        }
        return genres.contains { $0.localizedCaseInsensitiveContains("anime") }
    }
}

private func normalizeProviderIDKey(_ raw: String) -> String {
    raw.unicodeScalars
        .filter { CharacterSet.alphanumerics.contains($0) }
        .map { Character($0).lowercased() }
        .joined()
}

private func sanitizeProviderIDValue(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return trimmed
}
