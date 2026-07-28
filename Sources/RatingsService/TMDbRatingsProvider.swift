import Foundation
import CoreModels
import CoreNetworking

/// The **TMDB** community score, from the same v4 API that already supplies the
/// app's artwork.
///
/// This is the only external rating that reaches *every* backend. Jellyfin's
/// `CommunityRating` is usually this same number but arrives unattributed (the
/// server records no provenance, so it can only be shown as a generic
/// "Community" score); Plex exposes its own attributed set; and plain media
/// shares — SMB, WebDAV, local files — have no server metadata at all and so had
/// no rating whatsoever beyond AniList's anime coverage. Asking TMDb directly
/// gives all three the same properly-attributed score.
///
/// It is also the only option that survives contact with a real user base. Every
/// alternative surveyed is either quota-capped per key (OMDb's 1,000/day, which a
/// shared key exhausts almost immediately), licence-restricted (IMDb's datasets
/// are limited to individual personal use), commercially gated (Rotten Tomatoes,
/// Metacritic), or explicitly not intended for this (Simkl's rules point at TMDb
/// and TVDB for exactly this purpose). TMDb's limit is roughly 40 requests per
/// second with no daily ceiling.
///
/// Resolution prefers a stamped TMDb id — Jellyfin and Plex both provide one, so
/// the common case is a single direct fetch — and falls back to a title/year
/// search for shares, which carry no ids at all. Best-effort throughout: any
/// failure yields `[]` so the detail screen is never blocked by a ratings lookup.
public struct TMDbRatingsProvider: ExternalRatingsProviding {
    private let bearerToken: String
    private let baseURL: URL
    private let http: HTTPClient

    public init(
        bearerToken: String,
        baseURL: URL = URL(string: "https://api.themoviedb.org")!,
        http: HTTPClient = URLSessionHTTPClient()
    ) {
        self.bearerToken = bearerToken
        self.baseURL = baseURL
        self.http = http
    }

    public func ratings(for item: MediaItem) async -> [ExternalRating] {
        guard let lookup = Self.lookup(for: item) else { return [] }
        let score: Score?
        switch lookup {
        case let .id(tmdbID, kind):
            score = await fetchByID(tmdbID, kind: kind)
        case let .search(title, year, kind):
            score = await search(title: title, year: year, kind: kind)
        }
        guard let score, score.average > 0, score.votes > 0 else { return [] }
        return [
            ExternalRating(
                source: .tmdb,
                value: score.average,
                scale: .outOfTen,
                ratingCount: score.votes
            )
        ]
    }

    private func fetchByID(_ id: String, kind: Kind) async -> Score? {
        try? await http.decode(
            Score.self,
            from: Endpoint(path: "/3/\(kind.path)/\(id)", headers: authHeaders),
            baseURL: baseURL
        )
    }

    private func search(title: String, year: Int?, kind: Kind) async -> Score? {  // l10n:content — media title used as a TMDb search query parameter
        var query = [URLQueryItem(name: "query", value: title)]
        if let year {
            // TMDb names the year filter differently per media type, and passing
            // the wrong one is silently ignored rather than rejected — which
            // would quietly return the unfiltered first match.
            query.append(URLQueryItem(name: kind.yearParameter, value: String(year)))
        }
        let endpoint = Endpoint(
            path: "/3/search/\(kind.path)",
            queryItems: query,
            headers: authHeaders
        )
        guard let response = try? await http.decode(
            SearchResponse.self, from: endpoint, baseURL: baseURL
        ) else { return nil }
        return response.results.first
    }

    private var authHeaders: [String: String] {
        ["Authorization": "Bearer \(bearerToken)", "Accept": "application/json"]
    }

    // MARK: - Lookup

    enum Kind {
        case movie
        case tv

        var path: String { self == .movie ? "movie" : "tv" }
        /// `year` filters a movie's release year; TV uses `first_air_date_year`.
        var yearParameter: String {
            self == .movie ? "year" : "first_air_date_year"
        }
    }

    enum Lookup {
        case id(String, Kind)
        case search(title: String, year: Int?, kind: Kind)
    }

    static func lookup(for item: MediaItem) -> Lookup? {
        guard let kind = kind(for: item) else { return nil }

        if let id = tmdbID(from: item.providerIDs) {
            return .id(id, kind)
        }

        let trimmed = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Year only corroborates a film. A series' `productionYear` is often the
        // season's rather than the show's first airing, which would filter out
        // the correct match entirely.
        let year = kind == .movie ? item.productionYear : nil
        return .search(title: trimmed, year: year, kind: kind)
    }

    static func tmdbID(from providerIDs: [String: String]) -> String? {
        for (key, value) in providerIDs where key.lowercased() == "tmdb" {
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            // Guard against a non-numeric id: TMDb would 404, wasting a request.
            if !trimmed.isEmpty, Int(trimmed) != nil { return trimmed }
        }
        return nil
    }

    static func kind(for item: MediaItem) -> Kind? {
        switch item.kind {
        case .movie: return .movie
        case .series: return .tv
        // Episodes and seasons are deliberately excluded rather than falling back
        // to the series' score. Jellyfin scopes its own `CommunityRating` to the
        // individual episode, so lending a series-level score the same tile shape
        // would put "this episode: 8.4" next to "the whole show: 8.9" with nothing
        // to tell them apart. A rating shown against an episode has to be about
        // that episode, or not be shown.
        case .season, .episode: return nil
        // Folders, collections and loose video files have no TMDb equivalent.
        default: return nil
        }
    }

    // MARK: - DTOs

    struct SearchResponse: Decodable {
        let results: [Score]
    }

    /// The score fields, which ride along on both the detail response and every
    /// search result — so the search path costs one request, not two.
    struct Score: Decodable {
        let average: Double
        let votes: Int

        private enum CodingKeys: String, CodingKey {
            case vote_average
            case vote_count
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            average = try container.decodeIfPresent(Double.self, forKey: .vote_average) ?? 0
            votes = try container.decodeIfPresent(Int.self, forKey: .vote_count) ?? 0
        }
    }
}
