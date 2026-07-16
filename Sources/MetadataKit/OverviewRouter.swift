import Foundation
import CoreModels

/// Keyless, cached, best-effort plot/overview **text** for video items whose
/// provider gives none — a local media share has no server to describe its files.
///
/// Deliberately mirrors ``ArtworkRouter``'s shape: a shared actor with an in-memory
/// cache (positive *and* negative), exactly one lightweight JSON request per lookup,
/// never throws, and is kept **off the critical path** by its single caller (the
/// detail page's speculative enrichment, which is cancellable and dwell-gated). No
/// TMDb — this is the free/keyless backbone, so it never risks TMDb's commercial
/// terms and works forever in the public build:
///   - TV (series / season / episode): **TVmaze** — the episode summary when a
///     season+episode is known, else the show summary.
///   - Movie / anime / unknown: **Wikipedia** — one search-scoped `extract` call
///     (`generator=search`), so the right page resolves in a single request.
///
/// The result is cached by the query's stable identity, so re-opening a detail (or
/// opening another episode of the same show) is instant and issues no new request.
public actor OverviewRouter {
    public static let shared = OverviewRouter()

    /// Positive + negative cache. A cached `nil` (`.some(nil)`) means "we looked and
    /// found nothing" so a miss is never re-fetched within a run.
    private var cache: [String: SourcedValue<String>?] = [:]

    public init() {}

    /// Resolves an overview for `item`, or `nil` when none can be found. Convenience
    /// over the ``MetadataQuery`` entry point.
    public func overview(for item: MediaItem) async -> String? {
        await overview(for: MetadataQuery(item))
    }

    public func sourcedOverview(for item: MediaItem) async -> SourcedValue<String>? {
        await sourcedOverview(for: MetadataQuery(item))
    }

    /// Lower-level entry point taking a prebuilt ``MetadataQuery``.
    public func overview(for query: MetadataQuery) async -> String? {
        await sourcedOverview(for: query)?.value
    }

    /// Resolves overview text together with its provider attribution.
    public func sourcedOverview(for query: MetadataQuery) async -> SourcedValue<String>? {
        let key = cacheKey(for: query)
        if let hit = cache[key] { return hit }
        let text = await resolve(query)
        cache[key] = text
        return text
    }

    // MARK: - Routing

    private func resolve(_ query: MetadataQuery) async -> SourcedValue<String>? {
        let title = query.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        for source in CurrentMetadataPriority.overviewSources(for: query.contentType) {
            switch source {
            case .tvmaze:
                if let value = await Self.tvmazeOverview(for: query) { return value }
            case .wikipedia:
                if let value = await Self.wikipediaOverview(for: query) {
                    return SourcedValue(value: value, source: .wikipedia)
                }
            default:
                continue
            }
        }
        return nil
    }

    /// A stable cache identity: prefers a concrete external id (so every episode of
    /// a show shares one show-level lookup) and otherwise a normalized title+year,
    /// with the SxE appended only when we're resolving a per-episode summary.
    private func cacheKey(for query: MetadataQuery) -> String {
        var parts: [String] = ["overview", query.contentType.rawValue]
        if let tmdb = query.providerIDs.providerID(.tmdb) ?? query.providerIDs.providerID(.seriesTmdb) {
            parts.append("tmdb:\(tmdb)")
        } else if let imdb = query.providerIDs.providerID(.imdb) {
            parts.append("imdb:\(imdb)")
        } else {
            parts.append("t:\(query.title.lowercased())|y:\(query.year.map(String.init) ?? "")")
        }
        if query.contentType == .tvShow, let s = query.seasonNumber, let e = query.episodeNumber {
            parts.append("s\(s)e\(e)")
        }
        return parts.joined(separator: "|")
    }

    // MARK: - TVmaze (western TV)

    /// The episode summary (real per-episode synopsis) when a season+episode is
    /// known, falling back to the show summary; both keyless, one request each.
    private static func tvmazeOverview(
        for query: MetadataQuery
    ) async -> SourcedValue<String>? {
        guard let show = await tvmazeShow(for: query) else { return nil }
        if let season = query.seasonNumber, let episode = query.episodeNumber,
           let url = URL(string: "https://api.tvmaze.com/shows/\(show.id)/episodebynumber?season=\(season)&number=\(episode)"),
           let ep = await MetadataHTTP.get(TVmazeEpisode.self, url: url),
           let text = strippedHTML(ep.summary) {
            return SourcedValue(value: text, source: .tvmaze, sourceURL: url)
        }
        guard let text = strippedHTML(show.summary) else { return nil }
        return SourcedValue(
            value: text,
            source: .tvmaze,
            sourceURL: URL(string: "https://api.tvmaze.com/shows/\(show.id)")
        )
    }

    private static func tvmazeShow(for query: MetadataQuery) async -> TVmazeShow? {
        if let imdb = query.providerIDs.providerID(.imdb), !imdb.isEmpty,
           let url = URL(string: "https://api.tvmaze.com/lookup/shows?imdb=\(imdb)"),
           let show = await MetadataHTTP.get(TVmazeShow.self, url: url) {
            return show
        }
        guard let escaped = metadataEscaped(query.title),
              let url = URL(string: "https://api.tvmaze.com/singlesearch/shows?q=\(escaped)")
        else { return nil }
        return await MetadataHTTP.get(TVmazeShow.self, url: url)
    }

    private struct TVmazeShow: Decodable {
        let id: Int
        let summary: String?
    }

    private struct TVmazeEpisode: Decodable {
        let summary: String?
    }

    // MARK: - Wikipedia (movies / anime / unknown)

    /// A single search-scoped extract call: `generator=search` finds the best page
    /// for "<title> [<year>] film" and `prop=extracts` returns its plain-text intro
    /// in the *same* request — accurate (search-ranked, not title-guessed) and cheap.
    private static func wikipediaOverview(for query: MetadataQuery) async -> String? {
        var search = query.title
        if let year = query.year { search += " \(year)" }
        // A gentle hint toward the film/series article without hard-filtering, so a
        // title that isn't disambiguated still resolves.
        search += query.contentType == .anime ? " anime" : " film"
        guard let escaped = metadataEscaped(search),
              let url = URL(string: "https://en.wikipedia.org/w/api.php?action=query&format=json&prop=extracts&exintro=1&explaintext=1&redirects=1&generator=search&gsrlimit=1&gsrsearch=\(escaped)")
        else { return nil }
        guard let response = await MetadataHTTP.get(WikipediaResponse.self, url: url),
              let page = response.query?.pages?.values.first,
              let extract = page.extract?.trimmingCharacters(in: .whitespacesAndNewlines),
              !extract.isEmpty
        else { return nil }
        return extract
    }

    private struct WikipediaResponse: Decodable {
        let query: Query?
        struct Query: Decodable { let pages: [String: Page]? }
        struct Page: Decodable { let extract: String? }
    }

    // MARK: - Helpers

    /// TVmaze summaries are small HTML fragments (`<p>…</p>`). Strip tags and decode
    /// the handful of entities that actually appear, returning `nil` for empty text.
    static func strippedHTML(_ html: String?) -> String? {
        guard let html else { return nil }
        var text = html.replacingOccurrences(
            of: "<[^>]+>", with: "", options: .regularExpression
        )
        let entities = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
                        "&#39;": "'", "&apos;": "'", "&nbsp;": " "]
        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
