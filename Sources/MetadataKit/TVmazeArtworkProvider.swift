import Foundation

/// Keyless western-TV artwork from the **TVmaze** API (`api.tvmaze.com`).
///
/// No API key, rate-limited 20 req / 10 s *per IP* — so it scales with the user
/// base. TVmaze's standout capability is **real per-episode stills** (genuine
/// episode thumbnails), which it exposes for an enormous catalogue of western TV,
/// plus a show-level poster. It does not serve wide heroes or clear logos (those
/// stay TMDb's job), so this provider only answers `thumbnail` and `poster`.
///
/// Resolution: by IMDb id (`/lookup/shows?imdb=`) when known, else a name search
/// (`/singlesearch/shows?q=`); the show id then drives `/episodebynumber`.
public struct TVmazeArtworkProvider: ArtworkProvider {
    public let id = "tvmaze"

    public init() {}

    public func artworkURL(_ kind: ArtworkKind, for query: MetadataQuery) async -> URL? {
        // Anime is served by AniList/Kitsu; TVmaze's anime coverage is poor.
        guard query.contentType == .tvShow else { return nil }
        switch kind {
        case .thumbnail:
            guard let season = query.seasonNumber, let episode = query.episodeNumber,
                  let show = await fetchShow(for: query) else { return nil }
            return await episodeStill(showID: show.id, season: season, episode: episode)
        case .poster:
            guard let show = await fetchShow(for: query) else { return nil }
            return show.image?.original.flatMap { URL(string: $0) }
        case .hero, .logo:
            return nil
        }
    }

    private func fetchShow(for query: MetadataQuery) async -> Show? {
        if let imdb = query.providerIDs.providerID(.imdb), !imdb.isEmpty,
           let url = URL(string: "https://api.tvmaze.com/lookup/shows?imdb=\(imdb)"),
           let show = await MetadataHTTP.get(Show.self, url: url) {
            return show
        }
        guard let escaped = metadataEscaped(query.title),
              let url = URL(string: "https://api.tvmaze.com/singlesearch/shows?q=\(escaped)")
        else { return nil }
        return await MetadataHTTP.get(Show.self, url: url)
    }

    private func episodeStill(showID: Int, season: Int, episode: Int) async -> URL? {
        guard let url = URL(string: "https://api.tvmaze.com/shows/\(showID)/episodebynumber?season=\(season)&number=\(episode)") else {
            return nil
        }
        let ep = await MetadataHTTP.get(Episode.self, url: url)
        return ep?.image?.original.flatMap { URL(string: $0) }
    }

    private struct Show: Decodable {
        let id: Int
        let image: Image?
    }

    private struct Episode: Decodable {
        let image: Image?
    }

    private struct Image: Decodable {
        let medium: String?
        let original: String?
    }
}
