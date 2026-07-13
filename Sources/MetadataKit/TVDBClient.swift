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

/// A per-episode fingerprint from the LOCAL library, used to disambiguate a
/// title collision (e.g. the animated "Archer" vs the 1975 detective drama of the
/// same name) by matching on-disk episode titles against a candidate's episodes.
/// Robust even when only one season was downloaded (season count alone can't tell
/// a 1-season namesake from S1 of a long-running show).
public struct SeriesEpisodeHint: Sendable, Equatable {
    public let season: Int
    public let episode: Int
    public let title: String
    public init(season: Int, episode: Int, title: String) {
        self.season = season
        self.episode = episode
        self.title = title
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
    /// results; `episodeHints` (on-disk episode titles) disambiguate a same-name
    /// collision by content when the year is unknown. Returns `nil` when
    /// unconfigured or unmatched.
    public func resolve(
        title: String,
        year: Int?,
        isMovie: Bool,
        episodeHints: [SeriesEpisodeHint] = []
    ) async -> TVDBMetadata? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard config.isConfigured, !trimmed.isEmpty else { return nil }

        if let result = await search(query: trimmed, year: year, isMovie: isMovie,
                                     episodeHints: episodeHints, allowRelogin: true) {
            return result
        }
        return nil
    }

    /// Resolve a wide **backdrop** (fanart) URL for a title, or `nil`. Uses a known
    /// TVDB id when available (skipping the search), else searches by title/year,
    /// then reads the title's extended record and picks the largest landscape
    /// artwork. TheTVDB has rich fanart for most TV + film, so this fills heroes
    /// that would otherwise have no wide art. Never throws.
    public func backdropURL(title: String, year: Int?, isMovie: Bool, tvdbID: String?) async -> URL? {
        guard config.isConfigured else { return nil }
        let id: String?
        if let tvdbID, !tvdbID.isEmpty {
            id = tvdbID
        } else {
            id = await resolve(title: title, year: year, isMovie: isMovie)?.tvdbID
        }
        guard let id, let token = await ensureToken() else { return nil }
        let type = isMovie ? "movies" : "series"
        guard let url = URL(string: "\(config.apiBaseURL.absoluteString)/\(type)/\(id)/extended") else { return nil }
        let (response, reachable) = await MetadataHTTP.getWithStatus(
            ExtendedResponse.self, url: url, headers: ["Authorization": "Bearer \(token)"]
        )
        guard let response else {
            if !reachable { self.token = nil }   // likely-expired token; re-login next time
            return nil
        }
        return Self.bestBackdrop(response.data?.artworks ?? [])
    }

    /// Pick the highest-resolution genuinely-landscape artwork (a background/fanart
    /// rather than a poster or square), by aspect + area — avoids relying on
    /// TheTVDB's per-content artwork *type* ids, which differ series vs movie.
    private static func bestBackdrop(_ artworks: [Artwork]) -> URL? {
        let landscape = artworks.filter { art in
            guard let w = art.width, let h = art.height, h > 0 else { return false }
            return Double(w) / Double(h) >= 1.4
        }
        let best = landscape.max { (($0.width ?? 0) * ($0.height ?? 0)) < (($1.width ?? 0) * ($1.height ?? 0)) }
        guard let image = best?.image, !image.isEmpty else { return nil }
        return Self.imageURL(image)
    }

    /// TheTVDB artwork `image` fields are usually absolute; prefix the CDN host for
    /// the occasional bare path.
    private static func imageURL(_ raw: String) -> URL? {
        if raw.hasPrefix("http") { return URL(string: raw) }
        return URL(string: "https://artworks.thetvdb.com" + (raw.hasPrefix("/") ? raw : "/" + raw))
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

    private func search(query: String, year: Int?, isMovie: Bool,
                        episodeHints: [SeriesEpisodeHint] = [],
                        allowRelogin: Bool) async -> TVDBMetadata? {
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
                return await search(query: query, year: year, isMovie: isMovie,
                                    episodeHints: episodeHints, allowRelogin: false)
            }
            return nil
        }
        let results = response.data ?? []
        guard !results.isEmpty else { return nil }

        // An exact year match is the strongest disambiguator when a year is known.
        if let year, let exact = results.first(where: { Int($0.year ?? "") == year }) {
            return exact.asMetadata()
        }
        // Otherwise, when there's a same-name collision (>1 result) and we have
        // on-disk episode titles, pick the candidate whose episodes match ours —
        // robust even when only one season was downloaded (season count alone
        // can't tell a 1-season namesake from S1 of a long-running show).
        if !isMovie, results.count > 1, !episodeHints.isEmpty,
           let matched = await disambiguateByEpisodes(results, hints: episodeHints, token: token) {
            return matched.asMetadata()
        }
        // Fallback: TheTVDB's own relevance order.
        return results.first?.asMetadata()
    }

    // MARK: - Episode-title disambiguation

    /// Picks the search candidate whose episode titles best match the on-disk
    /// library. Fetches each candidate's episode list (bounded to the first few
    /// candidates) and scores exact per-`SxxEyy` title matches. Returns the best
    /// candidate only when the match is confident, else `nil` (caller falls back
    /// to relevance order). Never throws.
    private func disambiguateByEpisodes(
        _ results: [SearchResult],
        hints: [SeriesEpisodeHint],
        token: String
    ) async -> SearchResult? {
        var best: (result: SearchResult, score: Int)?
        var secondBestScore = 0
        // Distinctive-enough acceptance: a clear majority of hints, or (for a
        // tiny hint set) at least two matches. A single generic title ("Pilot")
        // must not decide a collision.
        let strongThreshold = max(2, (hints.count + 1) / 2)

        for candidate in results.prefix(5) {
            guard let id = candidate.tvdb_id else { continue }
            let names = await episodeNames(seriesID: id, token: token)
            guard !names.isEmpty else { continue }
            var score = 0
            for hint in hints {
                let key = "\(hint.season)x\(hint.episode)"
                if let name = names[key], Self.titlesMatch(name, hint.title) { score += 1 }
            }
            if score > (best?.score ?? 0) {
                secondBestScore = best?.score ?? 0
                best = (candidate, score)
            } else if score > secondBestScore {
                secondBestScore = score
            }
        }

        guard let best else { return nil }
        // Confident when the winner clears the threshold AND beats the runner-up
        // (so a title both namesakes happen to share can't decide it alone).
        if best.score >= strongThreshold, best.score > secondBestScore {
            return best.result
        }
        return nil
    }

    /// `"<season>x<episode>" -> episode name` for a series' first page of episodes
    /// (the default order leads with season 1 — enough to match the seasons a
    /// viewer is most likely to have). Empty on any failure.
    private func episodeNames(seriesID: String, token: String) async -> [String: String] {
        guard let url = URL(string: "\(config.apiBaseURL.absoluteString)/series/\(seriesID)/episodes/default?page=0") else { return [:] }
        let (response, _) = await MetadataHTTP.getWithStatus(
            EpisodesResponse.self, url: url, headers: ["Authorization": "Bearer \(token)"]
        )
        guard let episodes = response?.data?.episodes else { return [:] }
        var map: [String: String] = [:]
        for ep in episodes {
            guard let s = ep.seasonNumber, let n = ep.number,
                  let name = ep.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty
            else { continue }
            map["\(s)x\(n)"] = name
        }
        return map
    }

    /// Two episode titles match when their alphanumeric token sets are equal or
    /// one contains the other — tolerant of scene/quality remnants the local
    /// parser may leave and of minor punctuation/casing differences. A bare
    /// numeric-only overlap never matches.
    static func titlesMatch(_ a: String, _ b: String) -> Bool {
        let ta = tokens(a), tb = tokens(b)
        guard !ta.isEmpty, !tb.isEmpty else { return false }
        if ta == tb { return true }
        return ta.isSubset(of: tb) || tb.isSubset(of: ta)
    }

    private static func tokens(_ s: String) -> Set<String> {
        Set(
            s.lowercased()
                .unicodeScalars
                .map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
                .reduce(into: "") { $0.append($1) }
                .split(separator: " ")
                .map(String.init)
                .filter { $0.count >= 2 && Int($0) == nil }
        )
    }

    // MARK: - DTOs

    private struct LoginResponse: Decodable {
        let data: TokenData?
        struct TokenData: Decodable { let token: String? }
    }

    private struct ExtendedResponse: Decodable {
        let data: DataField?
        struct DataField: Decodable { let artworks: [Artwork]? }
    }

    private struct Artwork: Decodable {
        let image: String?
        let width: Int?
        let height: Int?
        let type: Int?
    }

    private struct SearchResponse: Decodable {
        let data: [SearchResult]?
    }

    /// TheTVDB v4 `/series/{id}/episodes/{seasonType}` payload (first page).
    private struct EpisodesResponse: Decodable {
        let data: DataField?
        struct DataField: Decodable { let episodes: [Episode]? }
        struct Episode: Decodable {
            let number: Int?
            let seasonNumber: Int?
            let name: String?
        }
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
