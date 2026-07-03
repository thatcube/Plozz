import Foundation
import CoreModels

/// Pure DTO → `MediaItem` mapping for Seerr results, plus TMDB image URL
/// construction. Kept free of networking and `@MainActor` so it's exhaustively
/// unit-testable off-device.
enum SeerMapper {
    /// TMDB image CDN base. Poster/backdrop paths from Seerr are relative
    /// (`/abc.jpg`) and resolve as `{base}{size}{path}`.
    static let tmdbImageBase = "https://image.tmdb.org/t/p/"

    /// Size buckets chosen for tvOS: a grid-friendly poster, a rail-friendly
    /// backdrop, and a full-bleed hero backdrop.
    static let posterSize = "w500"
    static let backdropSize = "w780"
    static let heroBackdropSize = "w1280"

    /// Builds a full TMDB image URL from a relative path, or `nil` when the path
    /// is absent/blank.
    static func imageURL(path: String?, size: String) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        // Paths are already absolute-from-root ("/abc.jpg"); guard against a
        // stray leading-slash mismatch either way.
        let normalized = path.hasPrefix("/") ? path : "/\(path)"
        return URL(string: "\(tmdbImageBase)\(size)\(normalized)")
    }

    /// The stable `MediaItem.id` for a Seerr title, namespaced by its TMDB id so
    /// it never collides with a Jellyfin/Plex library id.
    static func itemID(tmdbID: Int) -> String { "seer:\(tmdbID)" }

    /// Extracts a production year from a TMDB date string (`YYYY-MM-DD`).
    static func year(from date: String?) -> Int? {
        guard let date, date.count >= 4 else { return nil }
        return Int(date.prefix(4))
    }

    /// Maps one discover/search result to a `MediaItem`, or `nil` when it isn't a
    /// playable/browsable title (people, or a title with no usable name).
    static func mediaItem(from result: SeerDiscoverResult) -> MediaItem? {
        let kind: MediaItemKind
        switch result.mediaType.lowercased() {
        case "tv": kind = .series
        case "movie": kind = .movie
        default: return nil // "person" and anything unexpected
        }

        // Movies carry `title`, TV carries `name`; fall back across both so a
        // mis-tagged result still maps.
        guard let title = (result.title ?? result.name)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty
        else { return nil }

        let status = result.mediaInfo?.status.flatMap(MediaAvailabilityStatus.init(rawValue:))

        return MediaItem(
            id: itemID(tmdbID: result.id),
            title: title,
            originalTitle: result.originalTitle ?? result.originalName,
            kind: kind,
            overview: result.overview,
            productionYear: year(from: result.releaseDate ?? result.firstAirDate),
            posterURL: imageURL(path: result.posterPath, size: posterSize),
            backdropURL: imageURL(path: result.backdropPath, size: backdropSize),
            heroBackdropURL: imageURL(path: result.backdropPath, size: heroBackdropSize),
            providerIDs: ["Tmdb": String(result.id)],
            availability: status
        )
    }

    /// Maps a page of results to `MediaItem`s, dropping people/unmappable
    /// entries, and caps to `limit` (0 or negative = no cap).
    static func mediaItems(from page: SeerDiscoverPage, limit: Int = 0) -> [MediaItem] {
        let mapped = page.results.compactMap(mediaItem(from:))
        guard limit > 0 else { return mapped }
        return Array(mapped.prefix(limit))
    }

    // MARK: - Request derivation

    /// The Seerr `mediaType` string for a `MediaItem`, or `nil` when the item
    /// isn't a movie/series (only those are requestable).
    static func requestMediaType(for item: MediaItem) -> String? {
        switch item.kind {
        case .movie: return "movie"
        case .series: return "tv"
        default: return nil
        }
    }

    /// The TMDB id to request for an item: prefers the `Tmdb` provider id, then
    /// parses a `seer:<id>` synthetic id. `nil` when neither yields an integer.
    static func tmdbID(for item: MediaItem) -> Int? {
        if let raw = item.providerIDs["Tmdb"], let value = Int(raw) {
            return value
        }
        if item.id.hasPrefix("seer:"), let value = Int(item.id.dropFirst("seer:".count)) {
            return value
        }
        return nil
    }
}
