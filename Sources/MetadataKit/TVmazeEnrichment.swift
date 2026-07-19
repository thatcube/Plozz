import Foundation
import CoreModels

/// The consolidated TVmaze result: the scattered id (KeylessIDResolver), poster/still
/// (TVmazeArtworkProvider), and overview (OverviewRouter) paths gathered behind one
/// lookup so the pipeline resolves a show once and reads every TVmaze capability
/// from it.
public struct TVmazeResolved: Sendable, Equatable {
    public var showID: Int
    public var imdbID: String?
    public var tvdbID: String?
    public var posterURL: URL?
    public var episodeStillURL: URL?
    public var overview: String?

    public init(
        showID: Int,
        imdbID: String? = nil,
        tvdbID: String? = nil,
        posterURL: URL? = nil,
        episodeStillURL: URL? = nil,
        overview: String? = nil
    ) {
        self.showID = showID
        self.imdbID = imdbID
        self.tvdbID = tvdbID
        self.posterURL = posterURL
        self.episodeStillURL = episodeStillURL
        self.overview = overview
    }
}

/// Seam over TVmaze so the enrichment adapter's mapping is testable without network.
public protocol TVmazeEnriching: Sendable {
    func resolve(_ query: MetadataQuery, wantEpisodeStill: Bool, wantOverview: Bool) async -> TVmazeResolved?
}

/// Keyless TVmaze client that resolves a western-TV show once and reads its ids,
/// poster, per-episode still, and (episode or show) summary. Consolidates the three
/// previously separate TVmaze call sites.
public struct TVmazeClient: TVmazeEnriching {
    public init() {}

    public func resolve(
        _ query: MetadataQuery,
        wantEpisodeStill: Bool,
        wantOverview: Bool
    ) async -> TVmazeResolved? {
        guard query.contentType == .tvShow, let show = await fetchShow(for: query) else { return nil }
        var out = TVmazeResolved(showID: show.id)
        out.imdbID = show.externals?.imdb.flatMap { $0.isEmpty ? nil : $0 }
        out.tvdbID = show.externals?.thetvdb.map(String.init)
        out.posterURL = show.image?.original.flatMap { URL(string: $0) }

        if let season = query.seasonNumber, let episode = query.episodeNumber,
           wantEpisodeStill || wantOverview,
           let ep = await fetchEpisode(showID: show.id, season: season, episode: episode) {
            if wantEpisodeStill { out.episodeStillURL = ep.image?.original.flatMap { URL(string: $0) } }
            if wantOverview { out.overview = OverviewRouter.strippedHTML(ep.summary) }
        }
        if wantOverview, out.overview == nil {
            out.overview = OverviewRouter.strippedHTML(show.summary)
        }
        return out
    }

    private func fetchShow(for query: MetadataQuery) async -> Show? {
        if let imdb = query.providerIDs.providerID(.imdb), !imdb.isEmpty,
           let url = URL(string: "https://api.tvmaze.com/lookup/shows?imdb=\(imdb)"),
           let show = await MetadataHTTP.get(Show.self, url: url) {
            return show
        }
        guard let escaped = metadataEscaped(query.title),
              let url = URL(string: "https://api.tvmaze.com/singlesearch/shows?q=\(escaped)")
        else { return nil }
        return await MetadataHTTP.get(Show.self, url: url)
    }

    private func fetchEpisode(showID: Int, season: Int, episode: Int) async -> Episode? {
        guard let url = URL(string: "https://api.tvmaze.com/shows/\(showID)/episodebynumber?season=\(season)&number=\(episode)") else {
            return nil
        }
        return await MetadataHTTP.get(Episode.self, url: url)
    }

    private struct Show: Decodable {
        let id: Int
        let summary: String?
        let image: Image?
        let externals: Externals?
        struct Externals: Decodable {
            let imdb: String?
            let thetvdb: Int?
        }
    }

    private struct Episode: Decodable {
        let summary: String?
        let image: Image?
    }

    private struct Image: Decodable {
        let original: String?
    }
}

/// TVmaze as the western-TV id / episode-summary / episode-still / poster-fallback
/// source. TV only; anime is served by AniList/Kitsu.
public struct TVmazeEnrichmentProvider: MetadataEnrichmentProvider {
    public let id: MetadataSource = .tvmaze
    public let capabilities: Set<MetadataCapability> = [.externalIDs, .canonicalText, .episodeStill, .poster]
    public let policy: ProviderPolicy
    private let client: any TVmazeEnriching

    public init(client: any TVmazeEnriching = TVmazeClient(), policy: ProviderPolicy = ProviderPolicy()) {
        self.client = client
        self.policy = policy
    }

    public func enrich(_ query: MetadataQuery, missing: Set<MetadataField>) async -> MetadataEnrichment {
        guard query.contentType == .tvShow else { return MetadataEnrichment() }
        let wantStill = missing.contains(.episodeThumbnail)
        let wantOverview = missing.contains(.overview)
        guard let resolved = await client.resolve(
            query, wantEpisodeStill: wantStill, wantOverview: wantOverview
        ) else { return MetadataEnrichment() }

        let sourceURL = URL(string: "https://api.tvmaze.com/shows/\(resolved.showID)")
        var out = MetadataEnrichment()
        if let imdb = resolved.imdbID {
            out.externalIDs["Imdb"] = SourcedValue(value: imdb, source: .tvmaze, sourceURL: sourceURL)
        }
        if let tvdb = resolved.tvdbID {
            out.externalIDs["Tvdb"] = SourcedValue(value: tvdb, source: .tvmaze, sourceURL: sourceURL)
        }
        if wantOverview, let overview = resolved.overview, !overview.isEmpty {
            out.overview = SourcedValue(value: overview, source: .tvmaze, sourceURL: sourceURL)
        }
        if missing.contains(.posterURL), let poster = resolved.posterURL {
            out.posterURL = SourcedValue(value: poster, source: .tvmaze, sourceURL: sourceURL)
        }
        if wantStill, let still = resolved.episodeStillURL {
            out.episodeStillURL = SourcedValue(value: still, source: .tvmaze, sourceURL: sourceURL)
        }
        return out
    }
}
