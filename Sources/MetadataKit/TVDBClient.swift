import Foundation

/// Resolved TheTVDB metadata for a title (the neutral result the share enricher
/// consumes). All fields best-effort; a partial result still helps.
public struct TVDBMetadata: Sendable, Equatable {
    public var tvdbID: String?
    public var imdbID: String?
    public var tmdbID: String?
    public var overview: String?
    public var posterURL: URL?
    public var genres: [String]
    public var year: Int?

    public init(tvdbID: String? = nil, imdbID: String? = nil, tmdbID: String? = nil,
                overview: String? = nil, posterURL: URL? = nil, genres: [String] = [], year: Int? = nil) {
        self.tvdbID = tvdbID
        self.imdbID = imdbID
        self.tmdbID = tmdbID
        self.overview = overview
        self.posterURL = posterURL
        self.genres = genres
        self.year = year
    }
}

/// Minimal client for **TheTVDB v4** — the bundled keyed metadata/artwork tier.
///
/// Flow: `POST /login` with the project api key → a JWT bearer (~1 month), cached
/// in-memory; then `GET /search?query=…&type=movie|series` with that bearer.
/// One search yields ids (TVDB + IMDb/TMDb from `remote_ids`), overview, a poster
/// (`image_url`) and genres — enough to enrich a share item, especially movies,
/// which have no keyless id/poster source. Never throws; a miss returns `nil`.
///
/// An `actor` so the cached token is mutated safely under concurrent enrichment.
public actor TVDBClient {
    private let config: TVDBConfig
    private var token: String?

    public init(config: TVDBConfig = .resolved()) {
        self.config = config
    }

    public var isConfigured: Bool { config.isConfigured }

    /// Resolve metadata for a title. `year` (when known) disambiguates same-name
    /// results. Returns `nil` when unconfigured or unmatched.
    public func resolve(title: String, year: Int?, isMovie: Bool) async -> TVDBMetadata? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard config.isConfigured, !trimmed.isEmpty else { return nil }

        if let result = await search(query: trimmed, year: year, isMovie: isMovie, allowRelogin: true) {
            return result
        }
        return nil
    }

    // MARK: - Auth

    private func ensureToken() async -> String? {
        if let token { return token }
        guard let key = config.apiKey else { return nil }
        let url = config.apiBaseURL.appendingPathComponent("login")
        let response = await MetadataHTTP.postJSON(LoginResponse.self, url: url, body: ["apikey": key])
        token = response?.data?.token
        return token
    }

    // MARK: - Search

    private func search(query: String, year: Int?, isMovie: Bool, allowRelogin: Bool) async -> TVDBMetadata? {
        guard let token = await ensureToken(),
              let escaped = query.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) else { return nil }
        let type = isMovie ? "movie" : "series"
        guard let url = URL(string: "\(config.apiBaseURL.absoluteString)/search?query=\(escaped)&type=\(type)") else { return nil }

        let (response, reachable) = await MetadataHTTP.getWithStatus(
            SearchResponse.self, url: url, headers: ["Authorization": "Bearer \(token)"]
        )
        guard let response else {
            // A likely-expired token (unreachable non-404) → drop it and retry once.
            if allowRelogin, !reachable {
                self.token = nil
                return await search(query: query, year: year, isMovie: isMovie, allowRelogin: false)
            }
            return nil
        }
        let results = response.data ?? []
        guard let best = Self.bestMatch(results, year: year) else { return nil }
        return best.asMetadata()
    }

    /// Prefer an exact year match when a year is known; otherwise the first result.
    private static func bestMatch(_ results: [SearchResult], year: Int?) -> SearchResult? {
        guard !results.isEmpty else { return nil }
        if let year {
            if let exact = results.first(where: { Int($0.year ?? "") == year }) { return exact }
        }
        return results.first
    }

    // MARK: - DTOs

    private struct LoginResponse: Decodable {
        let data: TokenData?
        struct TokenData: Decodable { let token: String? }
    }

    private struct SearchResponse: Decodable {
        let data: [SearchResult]?
    }

    private struct SearchResult: Decodable {
        let tvdb_id: String?
        let name: String?
        let overview: String?
        let image_url: String?
        let year: String?
        let genres: [String]?
        let remote_ids: [RemoteID]?

        struct RemoteID: Decodable {
            let id: String?
            let sourceName: String?
        }

        func asMetadata() -> TVDBMetadata {
            var imdb: String?
            var tmdb: String?
            for remote in remote_ids ?? [] {
                guard let source = remote.sourceName?.lowercased(), let id = remote.id, !id.isEmpty else { continue }
                if source.contains("imdb") { imdb = id }
                else if source.contains("themoviedb") || source == "tmdb" { tmdb = id }
            }
            return TVDBMetadata(
                tvdbID: tvdb_id,
                imdbID: imdb,
                tmdbID: tmdb,
                overview: overview?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
                posterURL: image_url.flatMap { URL(string: $0) },
                genres: genres ?? [],
                year: year.flatMap { Int($0) }
            )
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

private extension CharacterSet {
    static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=?+")
        return set
    }()
}
