import Foundation

/// TMDb-backed artwork (backdrops, posters, logos, per-episode stills) reached via
/// the optional, maintainer-controlled ``TMDbAccess`` (proxy or local token).
///
/// TMDb is the gold standard for western movie/TV heroes, clear logos and episode
/// stills, but its terms forbid distributing a key in an open-source client. So
/// this provider is *only* enabled when a self-hostable caching proxy or a local
/// token is configured (never in the public build). The JSON metadata calls go
/// through `access`; the image *bytes* always come straight from TMDb's keyless
/// CDN (`image.tmdb.org`), keeping any proxy tiny and the byte path uncapped.
public struct TMDbMetadataProvider: ArtworkProvider {
    public let id = "tmdb"
    private let access: TMDbAccess

    /// API host: the proxy base (which forwards to TMDb, injecting the key) or
    /// TMDb directly when a local token is configured.
    private var apiBase: String {
        switch access {
        case .proxy(let url): return url.absoluteString.hasSuffix("/") ? String(url.absoluteString.dropLast()) : url.absoluteString
        case .directToken, .userToken, .disabled: return "https://api.themoviedb.org"
        }
    }

    private let imageBase = "https://image.tmdb.org/t/p"

    /// Auth header for the JSON API: a v4 bearer in direct-token / user BYOK mode;
    /// none in proxy mode (the proxy injects the key server-side).
    private var authHeaders: [String: String] {
        switch access {
        case .directToken(let token), .userToken(let token): return ["Authorization": "Bearer \(token)"]
        case .proxy, .disabled: return [:]
        }
    }

    public init(access: TMDbAccess) {
        self.access = access
    }

    public var isEnabled: Bool { access.isEnabled }

    /// Ordered wide-backdrop URLs (best first), up to `limit`. Retaining a *set*
    /// (not just the single best) lets one response serve both the home hero and a
    /// distinct detail backdrop without a second search.
    public func backdropURLs(for query: MetadataQuery, limit: Int = 4) async -> [URL] {
        guard access.isEnabled, query.contentType != .music,
              let id = await resolveID(for: query) else { return [] }
        let images = await images(forID: id, isTV: query.isTV)
        return Self.rankedImagePaths(images?.backdrops, preferNeutral: true, limit: limit)
            .compactMap { URL(string: "\(imageBase)/original\($0)") }
    }

    public func artworkURL(_ kind: ArtworkKind, for query: MetadataQuery) async -> URL? {
        guard access.isEnabled, query.contentType != .music else { return nil }
        switch kind {
        case .hero:
            guard let path = await backdropPath(for: query) else { return nil }
            return URL(string: "\(imageBase)/original\(path)")
        case .poster:
            guard let path = await posterPath(for: query) else { return nil }
            return URL(string: "\(imageBase)/w500\(path)")
        case .logo:
            guard let path = await logoPath(for: query) else { return nil }
            return URL(string: "\(imageBase)/w500\(path)")
        case .thumbnail:
            guard let season = query.seasonNumber, let episode = query.episodeNumber,
                  let seriesID = await resolveID(for: query, forceTV: true),
                  let path = await stillPath(seriesID: seriesID, season: season, episode: episode)
            else { return nil }
            return URL(string: "\(imageBase)/w1280\(path)")
        }
    }

    // MARK: - Lookups

    private func backdropPath(for query: MetadataQuery) async -> String? {
        guard let id = await resolveID(for: query) else { return nil }
        let images = await images(forID: id, isTV: query.isTV)
        return Self.bestImagePath(images?.backdrops, preferNeutral: true)
    }

    private func logoPath(for query: MetadataQuery) async -> String? {
        guard let id = await resolveID(for: query) else { return nil }
        let images = await images(forID: id, isTV: query.isTV)
        return Self.bestLogoPath(images?.logos)
    }

    private func posterPath(for query: MetadataQuery) async -> String? {
        // The search result already carries a poster, so this is a single call.
        await search(query)?.poster_path
    }

    private func stillPath(seriesID: String, season: Int, episode: Int) async -> String? {
        guard let url = url("/3/tv/\(seriesID)/season/\(season)/episode/\(episode)/images") else { return nil }
        let response = await MetadataHTTP.get(StillsResponse.self, url: url, headers: authHeaders)
        return Self.bestImagePath(response?.stills, preferNeutral: true)
    }

    /// Resolves a TMDb id, preferring a stamped id (`Tmdb`, or `SeriesTmdb` for
    /// episodes/seasons) over a title search.
    private func resolveID(for query: MetadataQuery, forceTV: Bool = false) async -> String? {
        let isTV = forceTV || query.isTV
        if isTV, let series = query.providerIDs.providerID(.seriesTmdb), !series.isEmpty {
            return series
        }
        // An episode/season's own `Tmdb` id is the episode, not the show, so only
        // trust a stamped `Tmdb` for series/movies.
        switch query.kind {
        case .movie, .video, .series:
            if let own = query.providerIDs.providerID(.tmdb), !own.isEmpty {
                return own
            }
        default:
            break
        }
        return await search(query, forceTV: forceTV)?.id.map(String.init)
    }

    private func search(_ query: MetadataQuery, forceTV: Bool = false) async -> SearchResult? {
        let isTV = forceTV || query.isTV
        guard let escaped = metadataEscaped(query.title) else { return nil }
        var path = "/3/search/\(isTV ? "tv" : "movie")?query=\(escaped)&include_adult=false"
        if let year = query.year {
            path += "&\(isTV ? "first_air_date_year" : "year")=\(year)"
        }
        guard let url = url(path) else { return nil }
        return await MetadataHTTP.get(SearchResponse.self, url: url, headers: authHeaders)?.results.first
    }

    private func images(forID id: String, isTV: Bool) async -> ImagesResponse? {
        guard let url = url("/3/\(isTV ? "tv" : "movie")/\(id)/images") else { return nil }
        return await MetadataHTTP.get(ImagesResponse.self, url: url, headers: authHeaders)
    }

    /// Builds a TMDb API URL against `apiBase`, attaching the bearer token only in
    /// direct-token mode (the proxy injects auth itself).
    private func url(_ path: String) -> URL? {
        URL(string: apiBase + path)
    }

    // MARK: - Selection (pure, shared with the legacy resolver's logic)

    static func bestImagePath(_ images: [Image]?, preferNeutral: Bool) -> String? {
        rankedImagePaths(images, preferNeutral: preferNeutral, limit: 1).first
    }

    /// The usable image paths ranked best-first (neutral/`en` language preferred,
    /// then by vote average), capped at `limit`. Shared by ``bestImagePath`` and the
    /// backdrop candidate-set path so both use identical selection logic.
    static func rankedImagePaths(_ images: [Image]?, preferNeutral: Bool, limit: Int) -> [String] {
        guard let images, limit > 0 else { return [] }
        let usable = images.filter { ($0.file_path?.isEmpty == false) }
        guard !usable.isEmpty else { return [] }
        func rank(_ image: Image) -> Int {
            switch image.iso_639_1 {
            case nil, "": return preferNeutral ? 0 : 1
            case "en": return preferNeutral ? 1 : 0
            default: return 2
            }
        }
        return usable.sorted {
            let (lr, rr) = (rank($0), rank($1))
            if lr != rr { return lr < rr }
            return ($0.vote_average ?? 0) > ($1.vote_average ?? 0)
        }.prefix(limit).compactMap(\.file_path)
    }

    static func bestLogoPath(_ logos: [Image]?) -> String? {
        guard let logos else { return nil }
        let usable = logos.filter {
            guard let p = $0.file_path, !p.isEmpty else { return false }
            return !p.lowercased().hasSuffix(".svg")
        }
        guard !usable.isEmpty else { return nil }
        func rank(_ image: Image) -> Int {
            switch image.iso_639_1 {
            case "en": return 0
            case nil, "": return 1
            default: return 2
            }
        }
        return usable.sorted {
            let (lr, rr) = (rank($0), rank($1))
            if lr != rr { return lr < rr }
            return ($0.vote_average ?? 0) > ($1.vote_average ?? 0)
        }.first?.file_path
    }

    // MARK: - DTOs

    struct SearchResponse: Decodable {
        let results: [SearchResult]
    }
    struct SearchResult: Decodable {
        let id: Int?
        let poster_path: String?
    }
    struct ImagesResponse: Decodable {
        let backdrops: [Image]?
        let logos: [Image]?
    }
    struct StillsResponse: Decodable {
        let stills: [Image]?
    }
    struct Image: Decodable {
        let file_path: String?
        let iso_639_1: String?
        let vote_average: Double?
    }
}
