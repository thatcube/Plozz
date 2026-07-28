import CoreModels
import Foundation

/// Binds a provider-supplied ``RelatedTitle`` to the viewer's own copy, so a row
/// entry plays instead of dead-ending.
///
/// Neither Jellyfin nor Plex can look a title up by external id, so discovery has
/// to go through free-text search — and a search matches on the name alone. That is
/// exactly how "Lucky!" (a 2022 documentary) ended up wearing a 2026 drama's
/// schedule earlier: the title matched and nothing checked the ids.
///
/// So a hit is only accepted when it **shares a strong external id** with the
/// related title. A title-only agreement is discarded, even when it looks obviously
/// right. The cost of a false match here is high — the wrong show, playing — and
/// the cost of a miss is one absent row entry.
public enum RelatedTitleMatcher {

    /// The library item corresponding to `related`, or `nil` when no candidate can
    /// be verified by id.
    ///
    /// - Parameters:
    ///   - related: the provider's title, carrying its external ids.
    ///   - candidates: search hits for that title, from any account.
    public static func match(_ related: RelatedTitle, in candidates: [MediaItem]) -> MediaItem? {
        let wanted = strongIDs(of: related)
        guard !wanted.isEmpty else { return nil }
        return candidates.first { candidate in
            // Kind must agree before ids are compared: TMDb and TheTVDB reuse one
            // integer id space across films and series, so id 550 alone can name
            // both a movie and an unrelated show.
            guard sameKind(candidate.kind, as: related.kind) else { return false }
            return !wanted.isDisjoint(with: strongIDs(of: candidate))
        }
    }

    /// The queries to issue when hunting for `related` in a library, most likely
    /// first. Mirrors ``CrossServerSourceResolver/searchQueries(for:)``: a server may
    /// store the title differently (localised, "The" reordered, punctuation), so a
    /// normalized form widens recall. Precision is unaffected — every hit still has
    /// to pass the id check.
    public static func searchQueries(for related: RelatedTitle) -> [String] {
        let raw = related.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return [] }
        var queries = [raw]
        let normalized = MediaItemIdentity.normalizedTitle(raw)
        if !normalized.isEmpty, normalized.caseInsensitiveCompare(raw) != .orderedSame {
            queries.append(normalized)
        }
        return queries
    }

    /// A season or episode hit stands in for its series: a library search for a show
    /// can surface an episode, and that still means the viewer has the show.
    static func sameKind(_ candidate: MediaItemKind, as wanted: MediaItemKind) -> Bool {
        switch wanted {
        case .series: return candidate == .series || candidate == .season || candidate == .episode
        case .movie: return candidate == .movie || candidate == .video
        default: return candidate == wanted
        }
    }

    static func strongIDs(of related: RelatedTitle) -> Set<String> {
        var out: Set<String> = []
        for namespace in RelatedTitlesResolver.comparableNamespaces {
            if let value = related.providerIDs.providerID(namespace)?.nonEmptyTrimmed {
                out.insert("\(namespace.canonicalKey.lowercased()):\(value.lowercased())")
            }
        }
        return out
    }

    /// A library item's own strong ids, reading **series-scoped** namespaces for an
    /// episode or season — an episode's own Imdb id identifies the episode, and
    /// comparing that against a show's would reject every candidate.
    static func strongIDs(of item: MediaItem) -> Set<String> {
        var out: Set<String> = []
        let isChild = item.kind == .season || item.kind == .episode
        let pairs: [(ProviderIDNamespace, ProviderIDNamespace)] = isChild
            ? [(.seriesImdb, .imdb), (.seriesTmdb, .tmdb), (.seriesTvdb, .tvdb),
               (.seriesAniList, .aniList), (.seriesMal, .myAnimeList)]
            : [(.imdb, .imdb), (.tmdb, .tmdb), (.tvdb, .tvdb),
               (.aniList, .aniList), (.myAnimeList, .myAnimeList)]
        for (read, write) in pairs {
            if let value = item.providerIDs.providerID(read)?.nonEmptyTrimmed {
                out.insert("\(write.canonicalKey.lowercased()):\(value.lowercased())")
            }
        }
        return out
    }
}

private extension String {
    var nonEmptyTrimmed: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
