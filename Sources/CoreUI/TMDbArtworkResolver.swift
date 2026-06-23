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

    /// One episode's identity for a batched still prefetch.
    public struct EpisodeStillRequest: Sendable {
        public let seriesTitle: String
        public let seriesTmdbID: String?
        public let season: Int
        public let episode: Int

        public init(seriesTitle: String, seriesTmdbID: String?, season: Int, episode: Int) {
            self.seriesTitle = seriesTitle
            self.seriesTmdbID = seriesTmdbID
            self.season = season
            self.episode = episode
        }
    }

    private let token: String?
    private let imageBase = "https://image.tmdb.org/t/p/w500"
    /// Backdrops feed the full-bleed detail hero, so pull a large width.
    private let backdropImageBase = "https://image.tmdb.org/t/p/w1280"
    /// Full-resolution backdrop base for the hero, which spans the whole (up to
    /// 4K) screen — `w1280` upscaled there looks soft, so the hero uses `original`.
    private let backdropOriginalBase = "https://image.tmdb.org/t/p/original"
    /// Backdrop path cache, keyed independent of size. A present value of `nil`
    /// is a negative result, so we never re-query a title TMDb couldn't resolve.
    private var backdropCache: [String: String?] = [:]
    /// Per-episode still URL cache (keyed by series + season/episode). A present
    /// value of `nil` is a negative result.
    private var stillCache: [String: URL?] = [:]
    /// Series-id-by-title cache, so prefetching a whole season's per-episode
    /// stills resolves the show's TMDb id once instead of re-searching per episode.
    private var seriesIDCache: [String: String?] = [:]
    /// Logos are transparent PNGs; `w500` keeps them crisp at hero size without
    /// pulling multi-megabyte originals.
    private let logoImageBase = "https://image.tmdb.org/t/p/w500"
    /// Session cache. A present value of `nil` is a negative result, so we never
    /// re-query a title that TMDb couldn't resolve.
    private var cache: [String: URL?] = [:]
    /// Separate cache for logo lookups, same negative-result semantics.
    private var logoCache: [String: URL?] = [:]

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

    /// Returns a TMDb logo (clearLogo-style transparent PNG) URL for the given
    /// title, or `nil` if disabled, not found, or the network call fails.
    ///
    /// Used by the detail hero as a fallback when the provider has no `Logo`
    /// image. Resolves the TMDb id from `tmdbID` when known (skipping a search),
    /// otherwise looks it up by title, then reads the images endpoint and picks
    /// the best logo (English first, then language-neutral; `.svg` skipped).
    /// - Parameters:
    ///   - title: Movie title, or — for TV — the *series* title.
    ///   - year: Release year (movies only; pass `nil` for TV).
    ///   - isTV: Use the `tv` namespace instead of `movie`.
    ///   - tmdbID: A known TMDb numeric id (from `providerIDs["Tmdb"]`), if any.
    public func logoURL(title: String, year: Int?, isTV: Bool, tmdbID: String?) async -> URL? {
        guard let token else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = tmdbID?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || (id?.isEmpty == false) else { return nil }

        let key = "\(isTV ? "tv" : "movie")|\(id ?? "")|\(trimmed.lowercased())|\(year.map(String.init) ?? "")"
        if let cached = logoCache[key] { return cached }

        let resolved = await fetchLogoURL(title: trimmed, year: year, isTV: isTV, tmdbID: id, token: token)
        logoCache[key] = resolved
        return resolved
    }

    /// Returns a TMDb backdrop (wide fanart) URL for the given title, or `nil` if
    /// disabled, not found, or the network call fails. Used by the detail hero as
    /// a fallback when the provider has no backdrop — common for anime via Shoko,
    /// whose AniDB source frequently lacks fanart. Resolves the TMDb id from
    /// `tmdbID` when known (skipping a search), otherwise looks it up by title.
    /// - Parameters:
    ///   - title: Movie title, or — for TV — the *series* title.
    ///   - year: Release year (movies only; pass `nil` for TV).
    ///   - isTV: Use the `tv` namespace instead of `movie`.
    ///   - tmdbID: A known TMDb numeric id (from `providerIDs["Tmdb"]`), if any.
    ///   - large: When `true`, returns the full-resolution `original` image (for
    ///     the full-bleed detail hero); otherwise a `w1280` image (rail/card sized).
    public func backdropURL(title: String, year: Int?, isTV: Bool, tmdbID: String?, large: Bool = false) async -> URL? {
        guard let token else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = tmdbID?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || (id?.isEmpty == false) else { return nil }

        // The cache key is size-independent: the hero (original) and the episode
        // cards (w1280) of the same show share one network lookup.
        let key = "\(isTV ? "tv" : "movie")|\(id ?? "")|\(trimmed.lowercased())|\(year.map(String.init) ?? "")"
        let path: String?
        if let cached = backdropCache[key] {
            path = cached
        } else {
            path = await fetchBackdropPath(title: trimmed, year: year, isTV: isTV, tmdbID: id, token: token)
            backdropCache[key] = path
        }
        guard let path else { return nil }
        return URL(string: (large ? backdropOriginalBase : backdropImageBase) + path)
    }

    /// Returns a TMDb per-episode still URL (a `w1280` frame for the given
    /// season/episode), or `nil` if disabled, not found, or the call fails. This
    /// is the real "episode thumbnail" for anime whose Jellyfin source (Shoko via
    /// AniDB) ships no per-episode stills. Resolves the series TMDb id from
    /// `seriesTmdbID` when known, otherwise by title search.
    /// - Parameters:
    ///   - seriesTitle: The *series* title (used only when `seriesTmdbID` is nil).
    ///   - seriesTmdbID: A known series TMDb numeric id, if any.
    ///   - season: The season number.
    ///   - episode: The episode number within the season.
    public func episodeStillURL(seriesTitle: String, seriesTmdbID: String?, season: Int, episode: Int) async -> URL? {
        guard let token else { return nil }
        let trimmed = seriesTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let id0 = seriesTmdbID?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || (id0?.isEmpty == false) else { return nil }

        let key = "\(id0 ?? "")|\(trimmed.lowercased())|s\(season)e\(episode)"
        if let cached = stillCache[key] { return cached }

        let seriesID: String?
        if let id0, !id0.isEmpty {
            seriesID = id0
        } else {
            seriesID = await resolveSeriesID(title: trimmed, token: token)
        }
        guard let seriesID else { stillCache[key] = .some(nil); return nil }

        let path = await fetchStillPath(seriesID: seriesID, season: season, episode: episode, token: token)
        let url = path.flatMap { URL(string: backdropImageBase + $0) }
        stillCache[key] = url
        return url
    }

    /// Warms the cache for a whole season's per-episode stills ahead of time, so a
    /// card already has its art the moment it scrolls into view instead of
    /// visibly loading in. Resolves+caches each still URL and downloads its bytes
    /// into `URLCache.shared` (which the card's loader reads through). Bounded
    /// concurrency keeps it polite to TMDb while staying well under its rate limit.
    public func prefetchEpisodeStills(_ requests: [EpisodeStillRequest]) async {
        guard token != nil, !requests.isEmpty else { return }
        let maxConcurrent = 6
        await withTaskGroup(of: Void.self) { group in
            var next = 0
            func schedule(_ request: EpisodeStillRequest) {
                group.addTask {
                    if let url = await self.episodeStillURL(
                        seriesTitle: request.seriesTitle,
                        seriesTmdbID: request.seriesTmdbID,
                        season: request.season,
                        episode: request.episode
                    ) {
                        // Download *and decode* into the shared image cache so the
                        // card seeds its still synchronously on appear (no gray
                        // flash) rather than re-decoding from URLCache bytes.
                        #if canImport(UIKit)
                        await ArtworkImageCache.shared.image(for: url)
                        #else
                        _ = try? await URLSession.shared.data(from: url)
                        #endif
                    }
                }
            }
            while next < min(maxConcurrent, requests.count) {
                schedule(requests[next]); next += 1
            }
            while await group.next() != nil {
                if next < requests.count { schedule(requests[next]); next += 1 }
            }
        }
    }

    /// Resolves (and caches) a TV series' TMDb id by title, shared across every
    /// per-episode still lookup for that show.
    private func resolveSeriesID(title: String, token: String) async -> String? {
        let key = title.lowercased()
        if let cached = seriesIDCache[key] { return cached }
        let id = await fetchID(title: title, year: nil, isTV: true, token: token)
        seriesIDCache[key] = id
        return id
    }

    private func fetchStillPath(seriesID: String, season: Int, episode: Int, token: String) async -> String? {
        guard let url = URL(string: "https://api.themoviedb.org/3/tv/\(seriesID)/season/\(season)/episode/\(episode)/images") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "accept")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let decoded = try? JSONDecoder().decode(StillsResponse.self, from: data)
        else {
            return nil
        }
        return Self.bestBackdropPath(decoded.stills)
    }

    private func fetchBackdropPath(title: String, year: Int?, isTV: Bool, tmdbID: String?, token: String) async -> String? {
        let id: String?
        if let tmdbID, !tmdbID.isEmpty {
            id = tmdbID
        } else {
            id = await fetchID(title: title, year: year, isTV: isTV, token: token)
        }
        guard let id else { return nil }

        guard let url = URL(string: "https://api.themoviedb.org/3/\(isTV ? "tv" : "movie")/\(id)/images") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "accept")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let decoded = try? JSONDecoder().decode(ImagesResponse.self, from: data)
        else {
            return nil
        }
        return Self.bestBackdropPath(decoded.backdrops)
    }

    /// Picks the best backdrop: prefer language-neutral fanart (no on-image text)
    /// for a clean hero, then English, then anything; break ties by `vote_average`.
    private static func bestBackdropPath(_ backdrops: [ImagesResponse.Image]?) -> String? {
        guard let backdrops else { return nil }
        let usable = backdrops.filter { ($0.file_path?.isEmpty == false) }
        guard !usable.isEmpty else { return nil }
        func rank(_ image: ImagesResponse.Image) -> Int {
            switch image.iso_639_1 {
            case nil, "": return 0
            case "en": return 1
            default: return 2
            }
        }
        return usable.sorted {
            let (lr, rr) = (rank($0), rank($1))
            if lr != rr { return lr < rr }
            return ($0.vote_average ?? 0) > ($1.vote_average ?? 0)
        }.first?.file_path
    }

    private func fetchLogoURL(title: String, year: Int?, isTV: Bool, tmdbID: String?, token: String) async -> URL? {
        let id: String?
        if let tmdbID, !tmdbID.isEmpty {
            id = tmdbID
        } else {
            id = await fetchID(title: title, year: year, isTV: isTV, token: token)
        }
        guard let id else { return nil }

        guard let url = URL(string: "https://api.themoviedb.org/3/\(isTV ? "tv" : "movie")/\(id)/images") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "accept")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let decoded = try? JSONDecoder().decode(ImagesResponse.self, from: data)
        else {
            return nil
        }
        guard let path = Self.bestLogoPath(decoded.logos) else { return nil }
        return URL(string: logoImageBase + path)
    }

    /// Picks the best logo: skip unrenderable `.svg`, prefer English, then
    /// language-neutral, then anything; break ties by `vote_average`.
    private static func bestLogoPath(_ logos: [ImagesResponse.Image]) -> String? {
        let usable = logos.filter {
            guard let p = $0.file_path, !p.isEmpty else { return false }
            return !p.lowercased().hasSuffix(".svg")
        }
        guard !usable.isEmpty else { return nil }
        func rank(_ image: ImagesResponse.Image) -> Int {
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

    /// Resolves a TMDb id by title search (returns the first result's id).
    private func fetchID(title: String, year: Int?, isTV: Bool, token: String) async -> String? {
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
              let decoded = try? JSONDecoder().decode(IDSearchResponse.self, from: data),
              let id = decoded.results.first?.id
        else {
            return nil
        }
        return String(id)
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

    // MARK: - Trailers

    /// Returns YouTube trailer video ids for the given title, best first, or an
    /// empty array if disabled, not found, or the network call fails.
    ///
    /// This is how the app gets trailers for libraries that ship no local trailer
    /// files (the common case): TMDb's `videos` endpoint lists official YouTube
    /// trailers/teasers, whose ids are then played by extracting their stream
    /// (`ProviderTrailers`). Resolves the TMDb id from `tmdbID` when known
    /// (skipping a search), otherwise looks it up by title.
    /// - Parameters:
    ///   - title: Movie title, or — for TV — the *series* title.
    ///   - year: Release year (movies only; pass `nil` for TV).
    ///   - isTV: Use the `tv` namespace instead of `movie`.
    ///   - tmdbID: A known TMDb numeric id (from `providerIDs["Tmdb"]`), if any.
    public func trailerVideoIDs(title: String, year: Int?, isTV: Bool, tmdbID: String?) async -> [String] {
        guard let token else { return [] }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let knownID = tmdbID?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || (knownID?.isEmpty == false) else { return [] }

        let id: String?
        if let knownID, !knownID.isEmpty {
            id = knownID
        } else {
            id = await fetchID(title: trimmed, year: year, isTV: isTV, token: token)
        }
        guard let id else { return [] }

        guard let url = URL(string: "https://api.themoviedb.org/3/\(isTV ? "tv" : "movie")/\(id)/videos") else {
            return []
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "accept")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let decoded = try? JSONDecoder().decode(VideosResponse.self, from: data)
        else {
            return []
        }
        return Self.rankedYouTubeTrailerKeys(decoded.results)
    }

    /// Pure selection of the best YouTube trailer keys from a TMDb `videos`
    /// payload: keep YouTube `Trailer`/`Teaser` clips, prefer trailers over
    /// teasers, then official clips, then larger sizes. Exposed for testing.
    public static func rankedYouTubeTrailerKeys(_ videos: [Video]) -> [String] {
        let usable = videos.filter { video in
            guard let key = video.key, !key.isEmpty else { return false }
            guard (video.site ?? "").caseInsensitiveCompare("YouTube") == .orderedSame else { return false }
            switch (video.type ?? "").lowercased() {
            case "trailer", "teaser": return true
            default: return false
            }
        }
        func rank(_ video: Video) -> (Int, Int, Int) {
            let isTrailer = (video.type ?? "").caseInsensitiveCompare("Trailer") == .orderedSame
            return (isTrailer ? 0 : 1, (video.official ?? false) ? 0 : 1, -(video.size ?? 0))
        }
        return usable.sorted {
            let (l, r) = (rank($0), rank($1))
            return l < r
        }.compactMap { $0.key }
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

    private struct IDSearchResponse: Decodable {
        let results: [Result]
        struct Result: Decodable { let id: Int }
    }

    private struct ImagesResponse: Decodable {
        let logos: [Image]
        let backdrops: [Image]?
        struct Image: Decodable {
            let file_path: String?
            let iso_639_1: String?
            let vote_average: Double?
        }
    }

    /// The `/tv/{id}/season/{n}/episode/{m}/images` payload, whose frames live
    /// under `stills` (reusing `ImagesResponse.Image` for ranking).
    private struct StillsResponse: Decodable {
        let stills: [ImagesResponse.Image]?
    }

    private struct VideosResponse: Decodable {
        let results: [Video]
    }

    /// One clip from TMDb's `videos` endpoint (trailer, teaser, clip, …).
    public struct Video: Decodable, Equatable, Sendable {
        public let key: String?
        public let site: String?
        public let type: String?
        public let official: Bool?
        public let size: Int?

        public init(key: String?, site: String?, type: String?, official: Bool?, size: Int?) {
            self.key = key
            self.site = site
            self.type = type
            self.official = official
            self.size = size
        }
    }
}
#endif
