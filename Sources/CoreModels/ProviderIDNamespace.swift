import Foundation

/// Canonical external-id namespaces used across metadata/artwork/rating
/// enrichment. Each namespace resolves through a set of provider-specific key
/// aliases (`Imdb`, `IMDb`, `myanimelist`, …) found in `MediaItem.providerIDs`.
public enum ProviderIDNamespace: Sendable {
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

    fileprivate var aliases: [String] {
        switch self {
        case .imdb: return ["imdb"]
        case .tmdb: return ["tmdb"]
        case .tvdb: return ["tvdb", "thetvdb"]
        case .tvmaze: return ["tvmaze", "tvmazeid"]
        case .aniList: return ["anilist", "anilistid"]
        case .myAnimeList: return ["myanimelist", "myanimelistid", "mal"]
        case .aniDB: return ["anidb", "anidbid"]

        case .seriesImdb: return ["seriesimdb"]
        case .seriesTmdb: return ["seriestmdb"]
        case .seriesTvdb: return ["seriestvdb"]
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
