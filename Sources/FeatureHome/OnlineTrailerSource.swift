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

/// Verifies playability of an ordered list of YouTube video ids and returns the
/// first that resolves to a playable **public** stream (skipping private/removed
/// videos), or `nil` when none plays. Injected so tests stay off the network.
public typealias PlayableTrailerResolving = @Sendable ([String]) async -> String?

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

    /// Returns up to `limit` ranked online-trailer candidates for `item` (best
    /// first), or empty when the item isn't a movie/series or nothing suitable is
    /// found. Multiple candidates let the caller skip any that prove unplayable
    /// (e.g. private) and use the first that actually streams.
    static func trailers(
        for item: MediaItem,
        limit: Int = 6,
        fetch: @escaping Fetcher = Self.defaultFetch,
        youtubeFetch: @escaping Fetcher = Self.defaultYouTubeFetch
    ) async -> [MediaItem] {
        guard let q = query(for: item) else { return [] }
        let ids = await searchCandidateVideoIDs(
            title: q.title, year: q.year, isTV: q.isTV, limit: limit,
            fetch: fetch, youtubeFetch: youtubeFetch
        )
        return ids.map { videoID in
            MediaItem.youTubeTrailer(
                videoID: videoID,
                title: "\(item.title) — Trailer",
                parentTitle: item.title,
                posterURL: item.posterURL
            )
        }
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

    /// Tries each keyless source in priority order — YouTube's own search page
    /// first (reachable from any device with a consent cookie), then the
    /// community Invidious/Piped front-ends — returning up to `limit` ranked
    /// candidate video ids from the first source that yields usable matches.
    static func searchCandidateVideoIDs(
        title: String,
        year: Int?,
        isTV: Bool,
        limit: Int,
        fetch: @escaping Fetcher,
        youtubeFetch: @escaping Fetcher
    ) async -> [String] {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let queryString = searchQuery(title: trimmed, year: year, isTV: isTV)

        // 1) YouTube results page — the most reliably reachable source (the
        //    community front-ends are frequently blocked/offline). Public videos
        //    only; ranking + the caller's playability check drop anything dead.
        if let url = youtubeSearchURL(query: queryString),
           let data = await youtubeFetch(url),
           let results = parseYouTube(data), !results.isEmpty {
            let ids = bestVideoIDs(from: results, title: trimmed, year: year, limit: limit)
            if !ids.isEmpty { return ids }
        }

        for host in invidiousHosts {
            guard let url = invidiousSearchURL(host: host, query: queryString),
                  let data = await fetch(url),
                  let results = parseInvidious(data), !results.isEmpty
            else { continue }
            let ids = bestVideoIDs(from: results, title: trimmed, year: year, limit: limit)
            if !ids.isEmpty { return ids }
        }
        for host in pipedHosts {
            guard let url = pipedSearchURL(host: host, query: queryString),
                  let data = await fetch(url),
                  let results = parsePiped(data), !results.isEmpty
            else { continue }
            let ids = bestVideoIDs(from: results, title: trimmed, year: year, limit: limit)
            if !ids.isEmpty { return ids }
        }
        return []
    }

    /// YouTube's public results page for a query (HTML, parsed for `ytInitialData`
    /// video renderers). Filtered to videos via the `sp` param.
    static func youtubeSearchURL(host: String = "www.youtube.com", query: String) -> URL? {
        var c = URLComponents()
        c.scheme = "https"
        c.host = host
        c.path = "/results"
        c.queryItems = [
            URLQueryItem(name: "search_query", value: query),
            // sp=EgIQAQ%3D%3D restricts results to videos.
            URLQueryItem(name: "sp", value: "EgIQAQ==")
        ]
        return c.url
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

    /// Parses YouTube's results-page HTML into ordered search results by walking
    /// the `videoRenderer` blocks embedded in `ytInitialData`, taking each
    /// renderer's own video id and title. Order is preserved as YouTube's own
    /// relevance ranking. Returns `nil` when nothing parses (e.g. a consent
    /// interstitial), so the caller falls through to the next source.
    static func parseYouTube(_ data: Data) -> [SearchResult]? {
        guard let html = String(data: data, encoding: .utf8) else { return nil }
        var results: [SearchResult] = []
        var seen = Set<String>()
        // Each search hit is a `"videoRenderer":{ ... }` object; split on it and
        // read the first id + title out of each chunk.
        let chunks = html.components(separatedBy: "\"videoRenderer\":{")
        for chunk in chunks.dropFirst() {
            guard let id = firstRegexGroup(in: chunk, pattern: "\"videoId\":\"([A-Za-z0-9_-]{11})\""),
                  !seen.contains(id) else { continue }
            let rawTitle = firstRegexGroup(in: chunk, pattern: "\"title\":\\{\"runs\":\\[\\{\"text\":\"((?:[^\"\\\\]|\\\\.)*)\"")
                ?? firstRegexGroup(in: chunk, pattern: "\"title\":\\{[^}]*?\"text\":\"((?:[^\"\\\\]|\\\\.)*)\"")
            seen.insert(id)
            results.append(SearchResult(videoID: id, title: decodeJSONString(rawTitle ?? ""), author: ""))
        }
        return results.isEmpty ? nil : results
    }

    /// First capture group of `pattern` in `text` (dot matches newlines), or `nil`.
    private static func firstRegexGroup(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1,
              let groupRange = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[groupRange])
    }

    /// Decodes a raw JSON string body (the bytes between the quotes) — resolving
    /// `\uXXXX`, `\"`, `\\`, `\/` etc. — by re-quoting it and letting JSON decode.
    private static func decodeJSONString(_ raw: String) -> String {
        guard !raw.isEmpty else { return "" }
        if let data = "\"\(raw)\"".data(using: .utf8),
           let decoded = try? JSONDecoder().decode(String.self, from: data) {
            return decoded
        }
        return raw
    }

    // MARK: - Ranking (quality)

    /// Picks the highest-quality trailer from search results, or `nil` when none
    /// looks like a real trailer for this title.
    static func bestVideoID(from results: [SearchResult], title: String, year: Int?) -> String? {
        bestVideoIDs(from: results, title: title, year: year, limit: 1).first
    }

    /// Ranks search results and returns up to `limit` candidate video ids, best
    /// first. Prefers "official trailer", then teasers; rejects
    /// reactions/reviews/breakdowns; requires the result to mention the title and
    /// the word trailer/teaser so an unrelated clip is never surfaced. De-dupes
    /// ids, preserving the highest-scoring position.
    static func bestVideoIDs(from results: [SearchResult], title: String, year: Int?, limit: Int) -> [String] {
        let wanted = tokenize(title)
        let scored = results.enumerated().compactMap { offset, result -> (id: String, score: Int, offset: Int)? in
            guard let s = score(result, wanted: wanted, year: year) else { return nil }
            return (result.videoID, s, offset)
        }
        // Highest score wins; ties keep search-relevance order (lower offset).
        let ranked = scored.sorted { lhs, rhs in
            lhs.score != rhs.score ? lhs.score > rhs.score : lhs.offset < rhs.offset
        }
        var seen = Set<String>()
        var out: [String] = []
        for candidate in ranked where !candidate.id.isEmpty && !seen.contains(candidate.id) {
            seen.insert(candidate.id)
            out.append(candidate.id)
            if out.count == limit { break }
        }
        return out
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

    /// Fetcher for YouTube's HTML results page: a browser User-Agent plus the
    /// standard consent cookie (`CONSENT`/`SOCS`) so the page returns results
    /// instead of an EU consent interstitial. Best-effort like `defaultFetch`.
    static let defaultYouTubeFetch: Fetcher = { url in
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        request.setValue(
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("text/html", forHTTPHeaderField: "accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "accept-language")
        request.setValue("CONSENT=YES+1; SOCS=CAI", forHTTPHeaderField: "cookie")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode)
        else { return nil }
        return data
    }
}
