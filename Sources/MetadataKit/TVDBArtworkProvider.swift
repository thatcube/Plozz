import Foundation
import CoreModels

/// Artwork provider backed by the bundled **TheTVDB** tier. Contributes wide
/// **backdrops** (hero art) and **posters** for movies and TV — the gaps the
/// keyless providers leave (TVmaze has no backdrops and no movie posters;
/// Wikidata/Wikipedia are hit-or-miss), which forced heroes to a blurred-poster
/// wash and left movie cards blank.
///
/// Serves `.hero` (backdrop) and `.poster`; logos/stills stay with the existing
/// providers. Inert when TheTVDB isn't configured, or for anime/music (their
/// art comes from the AniList/Kitsu chain).
public struct TVDBArtworkProvider: ArtworkProvider {
    public let id = "tvdb"
    private let client: TVDBClient

    public init(client: TVDBClient) {
        self.client = client
    }

    public func artworkURL(_ kind: ArtworkKind, for query: MetadataQuery) async -> URL? {
        switch query.contentType {
        case .movie, .tvShow, .unknown: break
        case .anime, .music: return nil
        }
        let tvdbID = query.providerIDs.providerID(.tvdb)
        switch kind {
        case .hero:
            // `query.title` is already the show-level title for episode/season
            // queries, so a series backdrop resolves for any of its slides.
            return await client.backdropURL(
                title: query.title, year: query.year, isMovie: !query.isTV, tvdbID: tvdbID
            )
        case .poster:
            // TheTVDB has posters for both movies and TV — critically it's the only
            // bundled source of **movie** posters (the keyless chain has none), so a
            // share movie card is no longer blank. The search result's primary image
            // is the canonical portrait poster.
            return await client.resolve(title: query.title, year: query.year, isMovie: !query.isTV)?.posterURL
        case .logo, .thumbnail:
            return nil
        }
    }
}
