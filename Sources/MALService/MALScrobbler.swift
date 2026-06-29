import Foundation
import CoreModels
import CoreNetworking

/// Sends anime watch progress to MyAnimeList. Only fires for anime content.
public protocol MALScrobbling: Sendable {
    func scrobble(item: MediaItem, progress: Double, event: PlaybackEvent) async
    func scrobbleResult(item: MediaItem, progress: Double, event: PlaybackEvent) async throws
}

public extension MALScrobbling {
    func scrobbleResult(item: MediaItem, progress: Double, event: PlaybackEvent) async throws {
        await scrobble(item: item, progress: progress, event: event)
    }
}

/// No-op scrobbler when MAL is unconfigured/disconnected.
public struct DisabledMALScrobbler: MALScrobbling {
    public init() {}
    public func scrobble(item: MediaItem, progress: Double, event: PlaybackEvent) async {}
}

/// Live MAL scrobbler. Updates the user's anime list when an episode finishes.
public actor MALScrobbler: MALScrobbling {
    private let client: MALClient
    private let auth: MALAuthService
    private let tokenStore: MALTokenStoring
    private let idMapper: AnimeIDMapper

    public init(config: MALConfig, http: HTTPClient, tokenStore: MALTokenStoring, idMapper: AnimeIDMapper = .shared) {
        self.client = MALClient(config: config, http: http)
        self.auth = MALAuthService(config: config, http: http)
        self.tokenStore = tokenStore
        self.idMapper = idMapper
    }

    public func scrobble(item: MediaItem, progress: Double, event: PlaybackEvent) async {
        guard event == .stop, progress >= 80 else { return }
        guard isAnime(item) else { return }
        guard let token = await validAccessToken() else { return }

        do {
            try await updateList(item: item, accessToken: token)
            PlozzLog.playback.debug("MAL scrobble succeeded")
        } catch {
            PlozzLog.playback.debug("MAL scrobble failed (non-fatal)")
        }
    }

    public func scrobbleResult(item: MediaItem, progress: Double, event: PlaybackEvent) async throws {
        guard event == .stop, progress >= 80 else {
            FanoutDiagnostics.emit(FanoutDiagnostics.scrobbleLine(tracker: "mal", item: item, outcome: "skip(gate event=\(event) progress=\(Int(progress)))"))
            return
        }
        guard isAnime(item) else {
            FanoutDiagnostics.emit(FanoutDiagnostics.scrobbleLine(tracker: "mal", item: item, outcome: "skip(not anime)"))
            return
        }
        guard let token = await validAccessToken() else {
            FanoutDiagnostics.emit(FanoutDiagnostics.scrobbleLine(tracker: "mal", item: item, outcome: "skip(not connected)"))
            return
        }
        do {
            try await updateList(item: item, accessToken: token)
            FanoutDiagnostics.emit(FanoutDiagnostics.scrobbleLine(tracker: "mal", item: item, outcome: "OK"))
        } catch {
            FanoutDiagnostics.emit(FanoutDiagnostics.scrobbleLine(tracker: "mal", item: item, outcome: "THROW(\(error))"))
            throw error
        }
    }

    // MARK: - Internal

    private func updateList(item: MediaItem, accessToken: String) async throws {
        // Most anime libraries (Shoko/Jellyfin) tag only AniDB; resolve a MAL id
        // on demand so MAL-only users still scrobble. No-op when one is present.
        let mapped = await idMapper.enrich(extractMappedIDs(from: item.providerIDs))
        var malID = mapped.mal
        // ARM misses brand-new seasons; fall back to a MAL catalog title search.
        if malID == nil {
            let title = item.parentTitle ?? item.title
            malID = try? await client.searchAnimeID(title: title, accessToken: accessToken)
            FanoutDiagnostics.emit("mal.resolve title=\"\(title)\" arm=nil search->\(malID.map(String.init) ?? "miss")")
        } else {
            FanoutDiagnostics.emit("mal.resolve via=arm/native id=\(malID!)")
        }
        guard let malID else { return }

        let episodeProgress = item.episodeNumber
        try await client.updateAnimeListStatus(
            animeID: malID,
            status: .watching,
            numWatchedEpisodes: episodeProgress,
            accessToken: accessToken
        )
    }

    /// Returns a usable access token, refreshing an expired one.
    private func validAccessToken() async -> String? {
        guard let tokens = tokenStore.load() else { return nil }
        guard tokens.isExpired else { return tokens.accessToken }
        do {
            let refreshed = try await auth.refresh(tokens.refreshToken)
            try? tokenStore.save(refreshed)
            return refreshed.accessToken
        } catch {
            PlozzLog.playback.debug("MAL token refresh failed (non-fatal)")
            return nil
        }
    }

    /// Determines if a media item is anime by checking for MAL/anime-specific IDs.
    private func isAnime(_ item: MediaItem) -> Bool {
        for (key, value) in item.providerIDs {
            let k = key.lowercased()
            if (k == "mal" || k == "myanimelist" || k == "anilist" || k == "anidb" || k == "kitsu"),
               !value.trimmingCharacters(in: .whitespaces).isEmpty {
                return true
            }
        }
        return false
    }

    private func extractMappedIDs(from providerIDs: [String: String]) -> AnimeMappedIDs {
        var ids = AnimeMappedIDs()
        for (key, rawValue) in providerIDs {
            let value = rawValue.trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty, let n = Int(value) else { continue }
            switch key.lowercased() {
            case "mal", "myanimelist": ids.mal = n
            case "anilist": ids.anilist = n
            case "anidb": ids.anidb = n
            case "kitsu": ids.kitsu = n
            default: continue
            }
        }
        return ids
    }
}
