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
    /// The show's language as TVmaze reports it — an English display *name*
    /// (`English`, `Japanese`). Normalized to ISO-639-1 by the enrichment adapter.
    public var language: String?

    public init(
        showID: Int,
        imdbID: String? = nil,
        tvdbID: String? = nil,
        posterURL: URL? = nil,
        episodeStillURL: URL? = nil,
        overview: String? = nil,
        language: String? = nil
    ) {
        self.showID = showID
        self.imdbID = imdbID
        self.tvdbID = tvdbID
        self.posterURL = posterURL
        self.episodeStillURL = episodeStillURL
        self.overview = overview
        self.language = language
    }
}

/// Seam over TVmaze so the enrichment adapter's mapping is testable without network.
public protocol TVmazeEnriching: Sendable {
    func resolve(_ query: MetadataQuery, wantEpisodeStill: Bool, wantOverview: Bool) async -> TVmazeResolved?
    /// The show's next scheduled episode (TVmaze `?embed=nextepisode`), tagged with
    /// the resolved show id so the adapter can key a series identity. `nil` when the
    /// show can't be resolved or has no scheduled next episode (ended/on hiatus).
    func nextEpisode(_ query: MetadataQuery) async -> TVmazeNextEpisode?
}

/// TVmaze's next scheduled episode plus the show id it belongs to.
public struct TVmazeNextEpisode: Sendable, Equatable {
    public var showID: Int
    public var next: ProviderNextEpisode

    public init(showID: Int, next: ProviderNextEpisode) {
        self.showID = showID
        self.next = next
    }
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
        out.language = show.language?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyOrNil

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

    /// The show's original language as a **transient-aware** ``OriginalLanguageOutcome``
    /// for the play-time audio chain. TVmaze's public API is keyless (no auth), so a
    /// value is `.authoritative`, a reachable "not found" is an `.authoritative(nil)`
    /// miss, and an unreachable call (offline / 5xx / throttle) is `.transient` — so
    /// a TVmaze hiccup never gets cached as a permanent "no original language".
    /// TVmaze is TV-only (it carries no movies), so the router only reaches this for
    /// TV/anime/unknown content; the resolved `language` is an English display *name*
    /// (`English`, `Japanese`) that ``OriginalLanguageNormalizer`` folds to a code.
    public func originalLanguageOutcome(for query: MetadataQuery) async -> OriginalLanguageOutcome {
        let (show, reachable) = await fetchShowWithStatus(for: query)
        guard let show else { return reachable ? .authoritative(nil) : .transient }
        return .authoritative(show.language?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyOrNil)
    }

    /// Like ``fetchShow(for:)`` but surfaces reachability so a transient TVmaze
    /// failure is not mistaken for a real "no such show". An IMDb-id lookup that is
    /// unreachable short-circuits as transient; a reachable IMDb miss falls through
    /// to the title search, whose own reachability is returned.
    private func fetchShowWithStatus(for query: MetadataQuery) async -> (Show?, reachable: Bool) {
        if let imdb = query.providerIDs.providerID(.imdb), !imdb.isEmpty,
           let url = URL(string: "https://api.tvmaze.com/lookup/shows?imdb=\(imdb)") {
            let (show, reachable) = await MetadataHTTP.getWithStatus(Show.self, url: url)
            if let show { return (show, true) }
            if !reachable { return (nil, false) }
        }
        guard let escaped = metadataEscaped(query.title),
              let url = URL(string: "https://api.tvmaze.com/singlesearch/shows?q=\(escaped)")
        else { return (nil, true) }
        return await MetadataHTTP.getWithStatus(Show.self, url: url)
    }

    private func fetchEpisode(showID: Int, season: Int, episode: Int) async -> Episode? {
        guard let url = URL(string: "https://api.tvmaze.com/shows/\(showID)/episodebynumber?season=\(season)&number=\(episode)") else {
            return nil
        }
        return await MetadataHTTP.get(Episode.self, url: url)
    }

    public func nextEpisode(_ query: MetadataQuery) async -> TVmazeNextEpisode? {
        guard query.contentType == .tvShow, let showID = await fetchShowID(for: query) else { return nil }
        guard let url = URL(string: "https://api.tvmaze.com/shows/\(showID)?embed=nextepisode"),
              let show = await MetadataHTTP.get(ShowWithNext.self, url: url),
              let next = show.embedded?.nextepisode else { return nil }

        let airDate: Date
        let precision: AirDatePrecision
        if let stamp = ScheduleDateParsing.instant(next.airstamp) {
            airDate = stamp
            precision = .dateAndTime
        } else if let day = ScheduleDateParsing.calendarDate(next.airdate) {
            airDate = day
            precision = .dateOnly
        } else {
            return nil
        }

        let raw = ProviderNextEpisode(
            seasonNumber: next.season,
            episodeNumber: next.number,
            title: next.name?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyOrNil,
            airDate: airDate,
            datePrecision: precision,
            sourceURL: URL(string: "https://api.tvmaze.com/shows/\(showID)")
        )
        return TVmazeNextEpisode(showID: showID, next: raw)
    }

    private func fetchShowID(for query: MetadataQuery) async -> Int? {
        await fetchShow(for: query)?.id
    }

    private struct Show: Decodable {
        let id: Int
        let summary: String?
        let image: Image?
        let externals: Externals?
        let language: String?
        struct Externals: Decodable {
            let imdb: String?
            let thetvdb: Int?
        }
    }

    private struct Episode: Decodable {
        let summary: String?
        let image: Image?
    }

    private struct ShowWithNext: Decodable {
        let embedded: Embedded?
        enum CodingKeys: String, CodingKey {
            case embedded = "_embedded"
        }
        struct Embedded: Decodable {
            let nextepisode: NextEpisode?
        }
        struct NextEpisode: Decodable {
            let season: Int?
            let number: Int?
            let name: String?
            let airstamp: String?
            let airdate: String?
        }
    }

    private struct Image: Decodable {
        let original: String?
    }
}

private extension String {
    var nonEmptyOrNil: String? { isEmpty ? nil : self }
}

/// TVmaze as the western-TV id / episode-summary / episode-still / poster-fallback
/// source. TV only; anime is served by AniList/Kitsu.
public struct TVmazeEnrichmentProvider: MetadataEnrichmentProvider {
    public let id: MetadataSource = .tvmaze
    public let capabilities: Set<MetadataCapability> = [.externalIDs, .canonicalText, .episodeStill, .poster, .nextAiringEpisode, .originalLanguage]
    public let policy: ProviderPolicy
    private let client: any TVmazeEnriching

    public init(client: any TVmazeEnriching = TVmazeClient(), policy: ProviderPolicy = ProviderPolicy()) {
        self.client = client
        self.policy = policy
    }

    public func enrich(_ query: MetadataQuery, missing: Set<MetadataField>) async -> MetadataEnrichment {
        guard query.contentType == .tvShow else { return MetadataEnrichment() }
        var out = MetadataEnrichment()

        if missing.contains(.nextAiringEpisode), let schedule = await client.nextEpisode(query) {
            out.upcomingEpisode = schedule.next.upcomingEpisode(
                seriesIdentity: .external(source: "tvmaze", value: String(schedule.showID)),
                source: .tvmaze,
                refreshedAt: Date()
            )
        }

        // The remaining TVmaze capabilities need the show resolve; skip it entirely
        // for a schedule-only request so "Airing Soon" adds no extra work.
        let wantStill = missing.contains(.episodeThumbnail)
        let wantOverview = missing.contains(.overview)
        let wantsShowResolve = wantStill || wantOverview || missing.contains(.posterURL)
            || missing.contains(.originalLanguage)
            || missing.contains { $0.rawValue.hasPrefix("providerID.") }
        guard wantsShowResolve, let resolved = await client.resolve(
            query, wantEpisodeStill: wantStill, wantOverview: wantOverview
        ) else { return out }

        let sourceURL = URL(string: "https://api.tvmaze.com/shows/\(resolved.showID)")
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
        if missing.contains(.originalLanguage),
           let code = OriginalLanguageNormalizer.normalized(resolved.language) {
            out.originalLanguage = SourcedValue(value: code, source: .tvmaze, sourceURL: sourceURL)
        }
        return out
    }
}
