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

/// Live Simkl scrobbler. Only fires on `.stop` past the finished threshold (like Trakt).
public actor SimklScrobbler: SimklScrobbling {
    private let client: SimklClient
    private let tokenStore: SimklTokenStoring

    public init(config: SimklConfig, http: HTTPClient, tokenStore: SimklTokenStoring) {
        self.client = SimklClient(config: config, http: http)
        self.tokenStore = tokenStore
    }

    public func scrobble(item: MediaItem, progress: Double, event: PlaybackEvent) async {
        // Simkl history is "mark as watched" — only fire on stop past threshold.
        guard event == .stop, progress >= 80 else { return }
        guard let body = Self.historyBody(for: item) else { return }
        guard let token = tokenStore.load()?.accessToken else { return }

        do {
            try await client.addToHistory(body: body, accessToken: token)
            PlozzLog.playback.debug("Simkl scrobble succeeded")
        } catch {
            PlozzLog.playback.debug("Simkl scrobble failed (non-fatal)")
        }
    }

    public func scrobbleResult(item: MediaItem, progress: Double, event: PlaybackEvent) async throws {
        guard event == .stop, progress >= 80 else {
            FanoutDiagnostics.emit(FanoutDiagnostics.scrobbleLine(tracker: "simkl", item: item, outcome: "skip(gate event=\(event) progress=\(Int(progress)))"))
            return
        }
        guard let body = Self.historyBody(for: item) else {
            FanoutDiagnostics.emit(FanoutDiagnostics.scrobbleLine(tracker: "simkl", item: item, outcome: "skip(no usable ids)"))
            return
        }
        guard let token = tokenStore.load()?.accessToken else {
            FanoutDiagnostics.emit(FanoutDiagnostics.scrobbleLine(tracker: "simkl", item: item, outcome: "skip(not connected)"))
            return
        }
        do {
            try await client.addToHistory(body: body, accessToken: token)
            FanoutDiagnostics.emit(FanoutDiagnostics.scrobbleLine(tracker: "simkl", item: item, outcome: "OK"))
        } catch {
            FanoutDiagnostics.emit(FanoutDiagnostics.scrobbleLine(tracker: "simkl", item: item, outcome: "THROW(\(error))"))
            throw error
        }
    }

    // MARK: - Mapping

    static func historyBody(for item: MediaItem) -> SimklHistoryBody? {
        let ids = simklIDs(from: item.providerIDs)
        guard !ids.isEmpty else { return nil }

        let now = ISO8601DateFormatter().string(from: Date())

        switch item.kind {
        case .movie, .video:
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
            let episodeEntry = SimklEpisodeEntry(number: episode, watchedAt: now)
            let seasonEntry = SimklSeasonEntry(number: season, episodes: [episodeEntry])
            // For episodes, the show ids come from providerIDs (which are typically
            // the series-level ids from the media server).
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

    /// Extracts Simkl-compatible ids from a provider id map.
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
}
