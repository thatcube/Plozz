import Foundation
import CoreModels
import CoreUI

/// Resolves online (TMDb → YouTube) trailers for an item. Injected into
/// ``ItemDetailViewModel`` so the network path can be substituted in tests.
public typealias OnlineTrailerResolving = @Sendable (MediaItem) async -> [MediaItem]

/// Builds online-trailer `MediaItem`s for an item using TMDb's `videos` endpoint.
///
/// This is the fallback used when a library has no *local* trailer files (the
/// common case): TMDb lists official YouTube trailers for the title, and we
/// surface the best one as a playable online trailer (`MediaItem.youTubeTrailer`).
enum OnlineTrailerSource {
    /// Returns at most one online trailer (the best-ranked) for `item`, or empty
    /// when the item isn't a movie/series, TMDb is disabled, or none is found.
    static func trailers(for item: MediaItem, resolver: TMDbArtworkResolver = .shared) async -> [MediaItem] {
        guard let q = query(for: item) else { return [] }
        let videoIDs = await resolver.trailerVideoIDs(
            title: q.title,
            year: q.year,
            isTV: q.isTV,
            tmdbID: q.tmdbID,
            imdbID: q.imdbID,
            tvdbID: q.tvdbID
        )
        guard let best = videoIDs.first else { return [] }
        return [
            MediaItem.youTubeTrailer(
                videoID: best,
                title: "\(item.title) — Trailer",
                parentTitle: item.title,
                posterURL: item.posterURL
            )
        ]
    }

    /// Maps an item onto the TMDb lookup it should use, or `nil` for kinds that
    /// don't carry a show/movie-level trailer (seasons, episodes, folders).
    /// External ids (IMDb/TVDB) are passed alongside the title so the resolver
    /// can match by id — far more reliable than a name search — when present.
    static func query(for item: MediaItem) -> (title: String, year: Int?, isTV: Bool, tmdbID: String?, imdbID: String?, tvdbID: String?)? {
        switch item.kind {
        case .movie, .video:
            return (item.title, item.productionYear, false, item.providerIDs["Tmdb"], item.providerIDs["Imdb"], nil)
        case .series:
            return (item.title, nil, true, item.providerIDs["Tmdb"], item.providerIDs["Imdb"], item.providerIDs["Tvdb"])
        case .season, .episode, .folder, .collection, .unknown:
            return nil
        }
    }
}
