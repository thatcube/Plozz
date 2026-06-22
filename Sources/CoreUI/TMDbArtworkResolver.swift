#if canImport(SwiftUI)
import Foundation

/// Resolves a canonical TMDb poster for items whose provider artwork is missing
/// or "junk" (rejected by the poster aspect-ratio guard). Used as a last-resort
/// fallback so unmatched Plex movies / odd episodes still get a real poster.
///
/// Scale notes: TMDb's API rate limit is per-IP (~50 req/s, no daily cap), and
/// we only ever call it for the small set of items whose provider poster failed
/// — then cache the result for the session. The poster *image bytes* are served
/// by TMDb's CDN (image.tmdb.org), which needs no key and isn't rate-limited.
///
/// The bearer token is read from the app's Info.plist (`TMDBBearerToken`,
/// substituted from the gitignored `TMDB_BEARER_TOKEN` build setting). When it is
/// absent the resolver is inert and simply returns `nil`, disabling the feature.
public actor TMDbArtworkResolver {
    public static let shared = TMDbArtworkResolver()

    private let token: String?
    private let imageBase = "https://image.tmdb.org/t/p/w500"
    /// Session cache. A present value of `nil` is a negative result, so we never
    /// re-query a title that TMDb couldn't resolve.
    private var cache: [String: URL?] = [:]

    public init(token: String? = TMDbArtworkResolver.tokenFromBundle()) {
        self.token = token
    }

    /// `true` when a usable token is configured.
    public var isEnabled: Bool { token != nil }

    /// Returns a TMDb poster URL for the given title, or `nil` if disabled, not
    /// found, or the network call fails.
    /// - Parameters:
    ///   - title: Movie title, or — for TV — the *series* title.
    ///   - year: Release year (movies only; pass `nil` for TV, where the item's
    ///     year is an episode air date, not the series start).
    ///   - isTV: Search the `tv` namespace instead of `movie`.
    public func posterURL(title: String, year: Int?, isTV: Bool) async -> URL? {
        guard let token else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let key = "\(isTV ? "tv" : "movie")|\(trimmed.lowercased())|\(year.map(String.init) ?? "")"
        if let cached = cache[key] { return cached }

        let resolved = await fetchPosterURL(title: trimmed, year: year, isTV: isTV, token: token)
        cache[key] = resolved
        return resolved
    }

    private func fetchPosterURL(title: String, year: Int?, isTV: Bool, token: String) async -> URL? {
        guard var components = URLComponents(string: "https://api.themoviedb.org/3/search/\(isTV ? "tv" : "movie")") else {
            return nil
        }
        var query = [
            URLQueryItem(name: "query", value: title),
            URLQueryItem(name: "include_adult", value: "false")
        ]
        if let year {
            query.append(URLQueryItem(name: isTV ? "first_air_date_year" : "year", value: String(year)))
        }
        components.queryItems = query
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "accept")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let decoded = try? JSONDecoder().decode(SearchResponse.self, from: data),
              let path = decoded.results.first(where: { $0.poster_path?.isEmpty == false })?.poster_path
        else {
            return nil
        }
        return URL(string: imageBase + path)
    }

    /// Reads and validates the bundled token, treating an empty value or an
    /// unsubstituted `$(TMDB_BEARER_TOKEN)` placeholder as "not configured".
    public static func tokenFromBundle(_ bundle: Bundle = .main) -> String? {
        guard let raw = bundle.object(forInfoDictionaryKey: "TMDBBearerToken") as? String else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("$(") else { return nil }
        return trimmed
    }

    private struct SearchResponse: Decodable {
        let results: [Result]
        struct Result: Decodable { let poster_path: String? }
    }
}
#endif
