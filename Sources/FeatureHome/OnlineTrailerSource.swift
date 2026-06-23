import Foundation
import CoreModels

/// Resolves an online trailer for an item with **no API key and no TMDb** — the
/// last-resort fallback used only when the provider (Jellyfin/Plex) surfaces no
/// local or server-resolved trailer.
///
/// It searches public, keyless YouTube front-ends (Invidious, then Piped) for the
/// title's official trailer and returns the best match as a playable
/// `MediaItem.youTubeTrailer` (the stream is extracted on-device by the keyless
/// `ProviderTrailers` path). Everything is best-effort: any failure — no instance
/// reachable, nothing relevant found — yields an empty result and the detail page
/// simply hides its Trailer button.
public typealias OnlineTrailerResolving = @Sendable (MediaItem) async -> [MediaItem]

enum OnlineTrailerSource {
    /// A keyless network fetch, injected so tests never touch the network.
    typealias Fetcher = @Sendable (URL) async -> Data?

    /// One YouTube search hit considered for ranking.
    struct SearchResult: Equatable, Sendable {
        let videoID: String
        let title: String
        let author: String
    }

    /// Public Invidious API hosts, tried in order. These are community-run and
    /// come and go; the list is best-effort and failures fall through silently.
    static let invidiousHosts = [
        "yewtu.be",
        "invidious.nerdvpn.de",
        "inv.nadeko.net",
        "invidious.jing.rocks"
    ]

    /// Public Piped API hosts, tried after Invidious.
    static let pipedHosts = [
        "pipedapi.kavin.rocks",
        "pipedapi.adminforge.de"
    ]

    /// Returns at most one online trailer (the best-ranked) for `item`, or empty
    /// when the item isn't a movie/series or nothing suitable is found.
    static func trailers(for item: MediaItem, fetch: @escaping Fetcher = Self.defaultFetch) async -> [MediaItem] {
        guard let q = query(for: item) else { return [] }
        guard let videoID = await searchBestVideoID(title: q.title, year: q.year, isTV: q.isTV, fetch: fetch) else {
            return []
        }
        return [
            MediaItem.youTubeTrailer(
                videoID: videoID,
                title: "\(item.title) — Trailer",
                parentTitle: item.title,
                posterURL: item.posterURL
            )
        ]
    }

    /// Maps an item onto the trailer search it should use, or `nil` for kinds
    /// that don't carry a show/movie-level trailer (seasons, episodes, folders).
    static func query(for item: MediaItem) -> (title: String, year: Int?, isTV: Bool)? {
        switch item.kind {
        case .movie, .video:
            return (item.title, item.productionYear, false)
        case .series:
            return (item.title, nil, true)
        case .season, .episode, .folder, .collection, .unknown:
            return nil
        }
    }

    /// Builds the search query string, e.g. `Dune 2021 official trailer`.
    static func searchQuery(title: String, year: Int?, isTV: Bool) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let year, !isTV {
            return "\(trimmed) \(year) official trailer"
        }
        return "\(trimmed) official trailer"
    }

    /// Tries each keyless front-end until one yields a usable best match.
    static func searchBestVideoID(title: String, year: Int?, isTV: Bool, fetch: @escaping Fetcher) async -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let queryString = searchQuery(title: trimmed, year: year, isTV: isTV)

        for host in invidiousHosts {
            guard let url = invidiousSearchURL(host: host, query: queryString),
                  let data = await fetch(url),
                  let results = parseInvidious(data), !results.isEmpty
            else { continue }
            if let best = bestVideoID(from: results, title: trimmed, year: year) { return best }
        }
        for host in pipedHosts {
            guard let url = pipedSearchURL(host: host, query: queryString),
                  let data = await fetch(url),
                  let results = parsePiped(data), !results.isEmpty
            else { continue }
            if let best = bestVideoID(from: results, title: trimmed, year: year) { return best }
        }
        return nil
    }

    static func invidiousSearchURL(host: String, query: String) -> URL? {
        var c = URLComponents()
        c.scheme = "https"
        c.host = host
        c.path = "/api/v1/search"
        c.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "type", value: "video"),
            URLQueryItem(name: "sort_by", value: "relevance")
        ]
        return c.url
    }

    static func pipedSearchURL(host: String, query: String) -> URL? {
        var c = URLComponents()
        c.scheme = "https"
        c.host = host
        c.path = "/search"
        c.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "filter", value: "videos")
        ]
        return c.url
    }

    // MARK: - Parsing

    private struct InvidiousVideo: Decodable {
        let type: String?
        let videoId: String?
        let title: String?
        let author: String?
    }

    static func parseInvidious(_ data: Data) -> [SearchResult]? {
        guard let videos = try? JSONDecoder().decode([InvidiousVideo].self, from: data) else { return nil }
        return videos.compactMap { v in
            guard (v.type ?? "video") == "video", let id = v.videoId, !id.isEmpty else { return nil }
            return SearchResult(videoID: id, title: v.title ?? "", author: v.author ?? "")
        }
    }

    private struct PipedResponse: Decodable {
        let items: [PipedItem]?
        struct PipedItem: Decodable {
            let url: String?
            let title: String?
            let uploaderName: String?
        }
    }

    static func parsePiped(_ data: Data) -> [SearchResult]? {
        guard let decoded = try? JSONDecoder().decode(PipedResponse.self, from: data) else { return nil }
        return (decoded.items ?? []).compactMap { item in
            guard let url = item.url, let id = MediaItem.youTubeVideoID(fromURL: "https://www.youtube.com\(url)") ?? MediaItem.youTubeVideoID(fromURL: url) else {
                return nil
            }
            return SearchResult(videoID: id, title: item.title ?? "", author: item.uploaderName ?? "")
        }
    }

    // MARK: - Ranking (quality)

    /// Picks the highest-quality trailer from search results, or `nil` when none
    /// looks like a real trailer for this title. Prefers "official trailer", then
    /// teasers; rejects reactions/reviews/breakdowns; requires the result to
    /// mention the title and the word trailer/teaser so we never surface an
    /// unrelated clip.
    static func bestVideoID(from results: [SearchResult], title: String, year: Int?) -> String? {
        let wanted = tokenize(title)
        let scored = results.compactMap { result -> (id: String, score: Int)? in
            guard let s = score(result, wanted: wanted, year: year) else { return nil }
            return (result.videoID, s)
        }
        // Stable: first result wins ties (search relevance order).
        return scored.enumerated().max(by: { lhs, rhs in
            lhs.element.score != rhs.element.score ? lhs.element.score < rhs.element.score : lhs.offset > rhs.offset
        })?.element.id
    }

    private static let rejectMarkers = [
        "reaction", "review", "breakdown", "explained", "recap", "honest trailer",
        "parody", "first time", "commentary", "behind the scenes", "making of",
        "easter egg", "things you missed", "ranking", "tier list"
    ]

    private static func score(_ result: SearchResult, wanted: Set<String>, year: Int?) -> Int? {
        let t = result.title.lowercased()
        guard !t.isEmpty else { return nil }
        if rejectMarkers.contains(where: t.contains) { return nil }
        guard t.contains("trailer") || t.contains("teaser") else { return nil }

        let have = tokenize(result.title)
        let overlap = wanted.intersection(have).count
        // Require at least one shared significant word so we don't grab a
        // same-named-but-different clip.
        if !wanted.isEmpty && overlap == 0 { return nil }

        var s = 0
        if t.contains("official trailer") { s += 100 }
        else if t.contains("official teaser") { s += 80 }
        else if t.contains("trailer") { s += 60 }
        else { s += 40 }
        s += overlap * 10
        if let year, result.title.contains(String(year)) { s += 5 }
        if result.author.lowercased().contains("trailer") { s += 5 }
        return s
    }

    /// Lowercased significant word tokens (drops punctuation and short stopwords).
    static func tokenize(_ string: String) -> Set<String> {
        let stop: Set<String> = ["the", "a", "an", "of", "and", "to", "in", "official", "trailer", "teaser"]
        let words = string.lowercased()
            .map { ($0.isLetter || $0.isNumber) ? $0 : " " }
            .reduce(into: "") { $0.append($1) }
            .split(separator: " ")
            .map(String.init)
            .filter { $0.count > 1 && !stop.contains($0) }
        return Set(words)
    }

    // MARK: - Default network

    static let defaultFetch: Fetcher = { url in
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        request.setValue("application/json", forHTTPHeaderField: "accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode)
        else { return nil }
        return data
    }
}
