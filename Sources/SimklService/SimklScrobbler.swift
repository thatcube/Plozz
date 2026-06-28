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

    public init(config: SimklConfig, http: HTTPClient, tokenStore: SimklTokenStoring) {
        self.client = SimklClient(config: config, http: http)
        self.tokenStore = tokenStore
    }

    public func scrobble(item: MediaItem, progress: Double, event: PlaybackEvent) async {
        guard let action = Self.action(for: event) else { return }
        guard let body = Self.scrobbleBody(for: item, progress: progress) else { return }
        guard let token = tokenStore.load()?.accessToken else { return }

        do {
            try await client.scrobble(action: action, body: body, accessToken: token)
            PlozzLog.playback.debug("Simkl scrobble \(action) succeeded")
        } catch {
            PlozzLog.playback.debug("Simkl scrobble \(action) failed (non-fatal)")
        }
    }

    public func scrobbleResult(item: MediaItem, progress: Double, event: PlaybackEvent) async throws {
        guard let action = Self.action(for: event) else {
            FanoutDiagnostics.emit(FanoutDiagnostics.scrobbleLine(tracker: "simkl", item: item, outcome: "skip(event=\(event) not scrobbled)"))
            return
        }
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
            let seriesIDs = simklSeriesIDs(from: item.providerIDs)
            let ids = seriesIDs.isEmpty ? simklIDs(from: item.providerIDs) : seriesIDs
            guard !ids.isEmpty else { return nil }
            let show = SimklScrobbleShowRef(title: nil, year: nil, ids: ids)
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
            // namespace (SeriesTmdb, SeriesImdb, etc.) when available, falling
            // back to the episode-level IDs only if the series IDs are missing.
            let seriesIDs = simklSeriesIDs(from: item.providerIDs)
            let ids = seriesIDs.isEmpty ? simklIDs(from: item.providerIDs) : seriesIDs
            guard !ids.isEmpty else { return nil }
            let episodeEntry = SimklEpisodeEntry(number: episode, watchedAt: now)
            let seasonEntry = SimklSeasonEntry(number: season, episodes: [episodeEntry])
            let showEntry = SimklHistoryShowEntry(
                title: nil,
                year: nil,
                ids: ids,
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
            default:
                continue
            }
        }
        return ids
    }
}
