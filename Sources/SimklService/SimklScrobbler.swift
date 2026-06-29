import Foundation
import CoreModels
import CoreNetworking

/// Sends watch history to Simkl. Best-effort by contract (like Trakt).
public protocol SimklScrobbling: Sendable {
    func scrobble(item: MediaItem, progress: Double, event: PlaybackEvent) async
    func scrobbleResult(item: MediaItem, progress: Double, event: PlaybackEvent) async throws
}

public extension SimklScrobbling {
    func scrobbleResult(item: MediaItem, progress: Double, event: PlaybackEvent) async throws {
        await scrobble(item: item, progress: progress, event: event)
    }
}

/// No-op scrobbler when Simkl is unconfigured/disconnected.
public struct DisabledSimklScrobbler: SimklScrobbling {
    public init() {}
    public func scrobble(item: MediaItem, progress: Double, event: PlaybackEvent) async {}
}

/// Live Simkl scrobbler. Sends real-time scrobble events (start/pause/stop)
/// so "Now Watching" appears on the user's dashboard, plus fires sync/history
/// on stop past the threshold for durable watched marking.
public actor SimklScrobbler: SimklScrobbling {
    private let client: SimklClient
    private let tokenStore: SimklTokenStoring
    private let idMapper: AnimeIDMapper

    public init(config: SimklConfig, http: HTTPClient, tokenStore: SimklTokenStoring, idMapper: AnimeIDMapper = .shared) {
        self.client = SimklClient(config: config, http: http)
        self.tokenStore = tokenStore
        self.idMapper = idMapper
    }

    public func scrobble(item: MediaItem, progress: Double, event: PlaybackEvent) async {
        guard let action = Self.action(for: event) else { return }
        let item = await enrichAnime(item)
        guard let body = Self.scrobbleBody(for: item, progress: progress) else {
            FanoutDiagnostics.emit(FanoutDiagnostics.scrobbleLine(tracker: "simkl-rt", item: item, outcome: "skip(no body event=\(event) s=\(item.seasonNumber.map(String.init) ?? "nil") e=\(item.episodeNumber.map(String.init) ?? "nil"))"))
            return
        }
        guard let token = tokenStore.load()?.accessToken else {
            FanoutDiagnostics.emit(FanoutDiagnostics.scrobbleLine(tracker: "simkl-rt", item: item, outcome: "skip(not connected)"))
            return
        }

        do {
            let resp = try await client.scrobble(action: action, body: body, accessToken: token)
            FanoutDiagnostics.emit(FanoutDiagnostics.scrobbleLine(tracker: "simkl-rt", item: item, outcome: "OK(\(action)) resp=\(resp.prefix(200))"))
        } catch {
            FanoutDiagnostics.emit(FanoutDiagnostics.scrobbleLine(tracker: "simkl-rt", item: item, outcome: "THROW(\(action) \(error))"))
        }
    }

    public func scrobbleResult(item: MediaItem, progress: Double, event: PlaybackEvent) async throws {
        guard let action = Self.action(for: event) else {
            FanoutDiagnostics.emit(FanoutDiagnostics.scrobbleLine(tracker: "simkl", item: item, outcome: "skip(event=\(event) not scrobbled)"))
            return
        }
        let item = await enrichAnime(item)
        guard let body = Self.scrobbleBody(for: item, progress: progress) else {
            FanoutDiagnostics.emit(FanoutDiagnostics.scrobbleLine(tracker: "simkl", item: item, outcome: "skip(no usable ids)"))
            return
        }
        guard let token = tokenStore.load()?.accessToken else {
            FanoutDiagnostics.emit(FanoutDiagnostics.scrobbleLine(tracker: "simkl", item: item, outcome: "skip(not connected)"))
            return
        }

        // Fire real-time scrobble for all events.
        do {
            try await client.scrobble(action: action, body: body, accessToken: token)
            FanoutDiagnostics.emit(FanoutDiagnostics.scrobbleLine(tracker: "simkl", item: item, outcome: "OK(\(action))"))
        } catch AppError.conflict {
            // 409 = already scrobbled (the real-time path beat the durable drain
            // to it). That's a success, not a retry — never leave it pending.
            FanoutDiagnostics.emit(FanoutDiagnostics.scrobbleLine(tracker: "simkl", item: item, outcome: "OK(\(action) already-scrobbled)"))
        } catch {
            FanoutDiagnostics.emit(FanoutDiagnostics.scrobbleLine(tracker: "simkl", item: item, outcome: "THROW(\(error))"))
            throw error
        }

        // On stop past threshold, also fire sync/history as a durable backup
        // (the outbox retries this path on failure).
        if event == .stop, progress >= 80, let histBody = Self.historyBody(for: item) {
            do {
                try await client.addToHistory(body: histBody, accessToken: token)
                FanoutDiagnostics.emit(FanoutDiagnostics.scrobbleLine(tracker: "simkl", item: item, outcome: "history-backup OK"))
            } catch {
                // Non-fatal — the scrobble/stop already marked it watched.
                FanoutDiagnostics.emit(FanoutDiagnostics.scrobbleLine(tracker: "simkl", item: item, outcome: "history-backup fail (non-fatal)"))
            }
        }
    }

    // MARK: - Event → action mapping

    /// Maps a playback event to a Simkl scrobble action. `.progress` is skipped
    /// per Simkl docs ("Do not poll /scrobble/* periodically").
    static func action(for event: PlaybackEvent) -> String? {
        switch event {
        case .start, .unpause: return "start"
        case .pause: return "pause"
        case .stop: return "stop"
        case .progress: return nil
        }
    }

    // MARK: - Anime ID enrichment

    /// For anime tagged only with AniDB (Shoko/Jellyfin), resolves MAL/AniList ids
    /// via the shared mapper so Simkl can match — exactly like the MAL/AniList
    /// scrobblers. No-op for non-anime or when usable ids already exist. The few
    /// resolved ids are cached on disk, so each title queries at most once.
    private func enrichAnime(_ item: MediaItem) async -> MediaItem {
        let ids = item.providerIDs
        // Only spend a lookup when we have an anidb anchor but no native list id.
        let lowered = ids.reduce(into: [String: String]()) { $0[$1.key.lowercased()] = $1.value }
        let hasAnidb = (lowered["anidb"] ?? lowered["seriesanidb"]) != nil
        let hasNative = ["mal", "myanimelist", "anilist", "seriesmal", "seriesanilist"].contains { lowered[$0] != nil }
        guard hasAnidb, !hasNative else { return item }
        let anidb = Int(lowered["anidb"] ?? lowered["seriesanidb"] ?? "")
        let mapped = await idMapper.enrich(AnimeMappedIDs(anidb: anidb))
        guard !mapped.isEmpty else { return item }
        var merged = ids
        if let mal = mapped.mal { merged["mal"] = String(mal); merged["seriesmal"] = String(mal) }
        if let al = mapped.anilist { merged["anilist"] = String(al); merged["seriesanilist"] = String(al) }
        var copy = item
        copy.providerIDs = merged
        return copy
    }

    // MARK: - Scrobble body (real-time)

    /// Builds a scrobble body for `POST /scrobble/{start,pause,stop}`.
    static func scrobbleBody(for item: MediaItem, progress: Double) -> SimklScrobbleBody? {
        let clamped = min(max(progress, 0), 100)

        switch item.kind {
        case .movie, .video:
            let ids = simklIDs(from: item.providerIDs)
            guard !ids.isEmpty else { return nil }
            let movie = SimklScrobbleMovieRef(title: item.title, year: item.productionYear, ids: ids)
            return SimklScrobbleBody(movie: movie, progress: clamped)
        case .episode:
            guard let season = item.seasonNumber, let episode = item.episodeNumber else {
                return nil
            }
            // Simkl needs the SHOW's ids (or title), never the episode's. Use the
            // series-namespace ids when present; otherwise fall back to the series
            // title so Simkl can match. Episode-level ids would resolve to the
            // wrong show, so never send them as show ids.
            let seriesIDs = simklSeriesIDs(from: item.providerIDs)
            let title = item.parentTitle
            guard !seriesIDs.isEmpty || title != nil else { return nil }
            let show = SimklScrobbleShowRef(title: title, year: item.productionYear, ids: seriesIDs)
            let ep = SimklScrobbleEpisodeRef(season: season, number: episode)
            return SimklScrobbleBody(show: show, episode: ep, progress: clamped)
        default:
            return nil
        }
    }

    // MARK: - Mapping

    static func historyBody(for item: MediaItem) -> SimklHistoryBody? {
        let now = ISO8601DateFormatter().string(from: Date())

        switch item.kind {
        case .movie, .video:
            let ids = simklIDs(from: item.providerIDs)
            guard !ids.isEmpty else { return nil }
            let entry = SimklHistoryMovieEntry(
                title: item.title,
                year: item.productionYear,
                ids: ids,
                watchedAt: now
            )
            return SimklHistoryBody(movies: [entry])
        case .episode:
            guard let season = item.seasonNumber, let episode = item.episodeNumber else {
                return nil
            }
            // Simkl expects show-level IDs, not episode-level. Use the series
            // namespace (SeriesTmdb, SeriesImdb, etc.) when available, else fall
            // back to the series title — never episode-level IDs, which resolve
            // to the wrong show.
            let seriesIDs = simklSeriesIDs(from: item.providerIDs)
            let title = item.parentTitle
            guard !seriesIDs.isEmpty || title != nil else { return nil }
            let episodeEntry = SimklEpisodeEntry(number: episode, watchedAt: now)
            let seasonEntry = SimklSeasonEntry(number: season, episodes: [episodeEntry])
            let showEntry = SimklHistoryShowEntry(
                title: title,
                year: item.productionYear,
                ids: seriesIDs,
                seasons: [seasonEntry]
            )
            return SimklHistoryBody(shows: [showEntry])
        default:
            return nil
        }
    }

    /// Extracts Simkl-compatible ids from a provider id map (episode/movie level).
    static func simklIDs(from providerIDs: [String: String]) -> SimklIDs {
        var ids = SimklIDs()
        for (key, rawValue) in providerIDs {
            let value = rawValue.trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }
            switch key.lowercased() {
            case "imdb":
                if value.hasPrefix("tt") { ids.imdb = value }
            case "tmdb":
                ids.tmdb = Int(value)
            case "tvdb":
                ids.tvdb = Int(value)
            case "simkl":
                ids.simkl = Int(value)
            case "mal", "myanimelist":
                ids.mal = Int(value)
            case "anilist":
                ids.anilist = Int(value)
            case "anidb":
                ids.anidb = Int(value)
            default:
                continue
            }
        }
        return ids
    }

    /// Extracts series-level IDs (SeriesImdb, SeriesTmdb, SeriesTvdb) for
    /// episode scrobbles. Simkl needs the *show* ID, not the episode ID.
    static func simklSeriesIDs(from providerIDs: [String: String]) -> SimklIDs {
        var ids = SimklIDs()
        for (key, rawValue) in providerIDs {
            let value = rawValue.trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }
            switch key.lowercased() {
            case "seriesimdb":
                if value.hasPrefix("tt") { ids.imdb = value }
            case "seriestmdb":
                ids.tmdb = Int(value)
            case "seriestvdb":
                ids.tvdb = Int(value)
            case "seriesmal", "seriesmyanimelist":
                ids.mal = Int(value)
            case "seriesanilist":
                ids.anilist = Int(value)
            case "seriesanidb", "anidb":
                ids.anidb = Int(value)
            default:
                continue
            }
        }
        return ids
    }
}
