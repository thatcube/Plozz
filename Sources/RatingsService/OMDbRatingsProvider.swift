import Foundation
import CoreModels
import CoreNetworking

// MARK: - OMDb DTOs

/// Minimal mirror of the OMDb `?i=<imdb>` response. Only the fields we use are
/// modelled; OMDb uses mixed casing (`Ratings`, `imdbRating`).
struct OMDbResponse: Decodable {
    let Response: String?
    let Ratings: [OMDbRating]?
    let imdbRating: String?
}

struct OMDbRating: Decodable {
    let Source: String
    let Value: String
}

/// Fetches the authoritative **IMDb** rating from the OMDb API using an item's
/// IMDb id. Best-effort: returns `[]` on any failure.
///
/// OMDb also surfaces Rotten Tomatoes and Metacritic scores, but OMDb is **not
/// licensed to redistribute** them (it's why post-2017 OMDb keys lost Rotten
/// Tomatoes), and both carry trademark/enforcement risk. So we deliberately map
/// **only** IMDb here. Rotten Tomatoes still appears when the user's own media
/// server provides it (Plex `rating`/`audienceRating`, Jellyfin `CriticRating`),
/// which is their server's licensed metadata rather than something this app
/// fetches.
public struct OMDbRatingsProvider: ExternalRatingsProviding {
    private let apiKey: String
    private let baseURL: URL
    private let http: HTTPClient

    public init(apiKey: String, baseURL: URL, http: HTTPClient = URLSessionHTTPClient()) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.http = http
    }

    public func ratings(for item: MediaItem) async -> [ExternalRating] {
        guard let imdbID = Self.imdbID(from: item) else { return [] }

        let endpoint = Endpoint(
            path: "/",
            queryItems: [
                URLQueryItem(name: "i", value: imdbID),
                URLQueryItem(name: "apikey", value: apiKey)
            ]
        )

        do {
            let response = try await http.decode(OMDbResponse.self, from: endpoint, baseURL: baseURL)
            guard response.Response?.lowercased() != "false" else { return [] }
            return Self.ratings(from: response)
        } catch {
            // Best-effort: never surface enrichment failures to the UI.
            return []
        }
    }

    /// Extracts a normalized IMDb id (`tt…`) from an item's provider ids,
    /// tolerating differing key casing across providers.
    static func imdbID(from item: MediaItem) -> String? {
        for (key, value) in item.providerIDs where key.lowercased() == "imdb" {
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("tt"), trimmed.count > 2 { return trimmed }
        }
        return nil
    }

    static func ratings(from response: OMDbResponse) -> [ExternalRating] {
        var ratings: [ExternalRating] = []
        for entry in response.Ratings ?? [] {
            guard let source = source(forOMDbName: entry.Source),
                  let rating = ExternalRating.parseOMDb(source: source, value: entry.Value)
            else { continue }
            ratings.append(rating)
        }

        // Fall back to the top-level `imdbRating` if it wasn't in the array.
        if !ratings.contains(where: { $0.source == .imdb }),
           let imdb = response.imdbRating,
           let rating = ExternalRating.parseOMDb(source: .imdb, value: imdb) {
            ratings.append(rating)
        }
        return ratings
    }

    private static func source(forOMDbName name: String) -> RatingSource? {
        switch name {
        case "Internet Movie Database": return .imdb
        // Rotten Tomatoes and Metacritic are intentionally not mapped: OMDb is
        // not licensed to redistribute them. They reach the UI only via the
        // user's own server metadata (see the type doc comment).
        default: return nil
        }
    }
}

/// Decorates another provider with a TTL cache keyed by IMDb id (falling back
/// to the item id), so repeat detail views don't re-hit the network.
public struct CachingRatingsProvider: ExternalRatingsProviding {
    private let base: any ExternalRatingsProviding
    private let cache: RatingsCache

    public init(base: any ExternalRatingsProviding, cache: RatingsCache) {
        self.base = base
        self.cache = cache
    }

    public func ratings(for item: MediaItem) async -> [ExternalRating] {
        let key = OMDbRatingsProvider.imdbID(from: item) ?? item.id
        let resolved: [ExternalRating]
        if let cached = await cache.ratings(forKey: key) {
            resolved = cached
        } else {
            let fetched = await base.ratings(for: item)
            // Only cache non-empty results so a transient failure isn't pinned.
            if !fetched.isEmpty {
                await cache.store(fetched, forKey: key)
            }
            resolved = fetched
        }
        // Self-heal: never surface an anime-only score (AniList) on a non-anime
        // item, even if a stale/poisoned cache entry — keyed only by IMDb id —
        // carries one from an earlier misclassification. AniList is keyless and
        // the cache persists for days, so a bad entry would otherwise stick.
        guard resolved.contains(where: { $0.source.isAnimeOnly }),
              !AniListRatingsProvider.isAnime(item)
        else { return resolved }
        return resolved.filter { !$0.source.isAnimeOnly }
    }
}
