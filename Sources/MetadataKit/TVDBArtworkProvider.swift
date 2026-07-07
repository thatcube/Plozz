import Foundation
import CoreModels

/// Artwork provider backed by the bundled **TheTVDB** tier. Contributes wide
/// **backdrops** (hero art) for movies and TV — the gap the keyless providers
/// (TVmaze has no backdrops; Wikidata/Wikipedia only sometimes have a landscape
/// lead image) leave, which forced heroes to fall back to a blurred-poster wash.
///
/// Only serves `.hero` (backdrop); posters/logos/stills stay with the existing
/// providers. Inert when TheTVDB isn't configured, or for anime/music (anime
/// backdrops come from the AniList/Kitsu chain).
public struct TVDBArtworkProvider: ArtworkProvider {
    public let id = "tvdb"
    private let client: TVDBClient

    public init(client: TVDBClient) {
        self.client = client
    }

    public func artworkURL(_ kind: ArtworkKind, for query: MetadataQuery) async -> URL? {
        guard kind == .hero else { return nil }
        switch query.contentType {
        case .movie, .tvShow, .unknown: break
        case .anime, .music: return nil
        }
        // `query.title` is already the show-level title for episode/season queries,
        // so a series backdrop resolves for any of its slides.
        let tvdbID = query.providerIDs.providerID(.tvdb)
        return await client.backdropURL(
            title: query.title,
            year: query.year,
            isMovie: !query.isTV,
            tvdbID: tvdbID
        )
    }
}
