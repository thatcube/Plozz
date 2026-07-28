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
    /// The show's next scheduled episode (TVmaze `?embed=nextepisode`), tagged with
    /// the resolved show id so the adapter can key a series identity. `nil` when the
    /// show can't be resolved or has no scheduled next episode (ended/on hiatus).
    func nextEpisode(_ query: MetadataQuery) async -> TVmazeNextEpisode?
    /// Every not-yet-aired episode plus the show's stated airing days. Keyless and
    /// resolved by title/IMDb like the rest of TVmaze, so it works for a series no
    /// TheTVDB id is known for — which is most of them, since the schedule request
    /// deliberately never runs a title resolve to find one.
    func upcomingEpisodes(_ query: MetadataQuery, limit: Int) async -> TVmazeUpcoming?
}

/// TVmaze's future episodes for a show, plus its airing cadence.
public struct TVmazeUpcoming: Sendable, Equatable {
    public var showID: Int
    public var episodes: [ProviderNextEpisode]
    public var cadence: AirCadence?

    public init(showID: Int, episodes: [ProviderNextEpisode], cadence: AirCadence? = nil) {
        self.showID = showID
        self.episodes = episodes
        self.cadence = cadence
    }
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

    public func upcomingEpisodes(_ query: MetadataQuery, limit: Int = 24) async -> TVmazeUpcoming? {
        guard query.contentType == .tvShow || query.contentType == .anime,
              let showID = await fetchShowID(for: query) else { return nil }

        async let listingTask = MetadataHTTP.get(
            [ListedEpisode].self,
            url: URL(string: "https://api.tvmaze.com/shows/\(showID)/episodes")!
        )
        async let showTask = MetadataHTTP.get(
            ShowWithSchedule.self,
            url: URL(string: "https://api.tvmaze.com/shows/\(showID)")!
        )
        let (listing, show) = await (listingTask, showTask)

        // Compared against the start of today so an episode airing *today* still
        // counts as upcoming — a date-only schedule can't say whether it has aired.
        let today = Calendar.current.startOfDay(for: Date())
        let sourceURL = URL(string: "https://api.tvmaze.com/shows/\(showID)")
        let upcoming = (listing ?? []).compactMap { ep -> ProviderNextEpisode? in
            let airDate: Date
            let precision: AirDatePrecision
            if let stamp = ScheduleDateParsing.instant(ep.airstamp) {
                airDate = stamp
                precision = .dateAndTime
            } else if let day = ScheduleDateParsing.calendarDate(ep.airdate) {
                airDate = day
                precision = .dateOnly
            } else {
                return nil
            }
            guard airDate >= today else { return nil }
            return ProviderNextEpisode(
                seasonNumber: ep.season,
                episodeNumber: ep.number,
                title: ep.name?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyOrNil,
                airDate: airDate,
                datePrecision: precision,
                sourceURL: sourceURL
            )
        }
        .sorted { $0.airDate < $1.airDate }
        .prefix(limit)

        let cadence = AirCadence(
            weekdays: Self.weekdayIndices(from: show?.schedule?.days),
            airsTime: show?.schedule?.time?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyOrNil
        )
        guard !upcoming.isEmpty || !cadence.isEmpty else { return nil }
        return TVmazeUpcoming(
            showID: showID,
            episodes: Array(upcoming),
            cadence: cadence.isEmpty ? nil : cadence
        )
    }

    /// TVmaze names its airing days ("Friday"); map them to `Calendar` weekday
    /// indices (1 = Sunday) so cadence is provider-neutral.
    static func weekdayIndices(from days: [String]?) -> [Int] {
        let order = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        return (days ?? []).compactMap { day in
            order.firstIndex(of: day.lowercased()).map { $0 + 1 }
        }.sorted()
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
        struct Externals: Decodable {
            let imdb: String?
            let thetvdb: Int?
        }
    }

    private struct Episode: Decodable {
        let summary: String?
        let image: Image?
    }

    /// A show's full episode listing entry (`/shows/{id}/episodes`), which includes
    /// not-yet-aired episodes.
    private struct ListedEpisode: Decodable {
        let season: Int?
        let number: Int?
        let name: String?
        let airdate: String?
        let airstamp: String?
    }

    /// The show record's `schedule` block: the weekdays it airs on.
    private struct ShowSchedule: Decodable {
        let days: [String]?
        let time: String?
    }

    private struct ShowWithSchedule: Decodable {
        let id: Int
        let schedule: ShowSchedule?
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
    public let capabilities: Set<MetadataCapability> = [.externalIDs, .canonicalText, .episodeStill, .poster, .nextAiringEpisode]
    public let policy: ProviderPolicy
    private let client: any TVmazeEnriching

    /// `version: 3` — the cache is keyed per provider version, so a change to what
    /// this provider *returns* has to invalidate it or the old answer is served
    /// without the provider ever running.
    ///
    /// v2: started returning a show's whole upcoming run plus its airing days rather
    /// than only the next episode. v3: started answering for anime schedules at all
    /// — while it refused them it returned an empty enrichment, and those empties
    /// were cached, so admitting anime changed nothing until this bump.
    public init(
        client: any TVmazeEnriching = TVmazeClient(),
        policy: ProviderPolicy = ProviderPolicy(version: 3)
    ) {
        self.client = client
        self.policy = policy
    }

    public func enrich(_ query: MetadataQuery, missing: Set<MetadataField>) async -> MetadataEnrichment {
        // Anime is admitted for the SCHEDULE only. AniList owns anime identity, art
        // and score and stays first in that chain — but it models a series as
        // absolute-numbered with no season (an anime "season" is a separate AniList
        // entry), and an episode with no season can't be placed in a season's rail.
        // TVmaze numbers per season, matching how the library itself is organised,
        // so it supplies the run while AniList still supplies the next episode.
        //
        // The configured priority already lists TVmaze as an anime schedule source
        // (`schedule(.anime, [.anilist, .tvdb, .tvmaze])`); this guard was silently
        // contradicting it.
        let wantsSchedule = missing.contains(.nextAiringEpisode)
        switch query.contentType {
        case .tvShow: break
        case .anime where wantsSchedule: break
        default: return MetadataEnrichment()
        }
        var out = MetadataEnrichment()

        if wantsSchedule {
            let now = Date()
            // The full listing first — it fills the whole upcoming run and the
            // cadence in one pass. `nextEpisode` stays the fallback for a show whose
            // listing is unavailable but whose next episode is known.
            if let listed = await client.upcomingEpisodes(query, limit: 24), !listed.episodes.isEmpty {
                let identity = MediaIdentity.external(source: "tvmaze", value: String(listed.showID))
                let mapped = listed.episodes.map {
                    $0.upcomingEpisode(seriesIdentity: identity, source: .tvmaze, refreshedAt: now)
                }
                out.upcomingEpisodes = mapped
                out.upcomingEpisode = mapped.first
                out.cadence = listed.cadence
            } else if let schedule = await client.nextEpisode(query) {
                out.upcomingEpisode = schedule.next.upcomingEpisode(
                    seriesIdentity: .external(source: "tvmaze", value: String(schedule.showID)),
                    source: .tvmaze,
                    refreshedAt: now
                )
            }
        }

        // The remaining TVmaze capabilities need the show resolve; skip it entirely
        // for a schedule-only request so "Airing Soon" adds no extra work.
        let wantStill = missing.contains(.episodeThumbnail)
        let wantOverview = missing.contains(.overview)
        let wantsShowResolve = wantStill || wantOverview || missing.contains(.posterURL)
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
        return out
    }
}
