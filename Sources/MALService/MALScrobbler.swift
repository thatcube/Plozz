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

    public init(config: MALConfig, http: HTTPClient, tokenStore: MALTokenStoring) {
        self.client = MALClient(config: config, http: http)
        self.auth = MALAuthService(config: config, http: http)
        self.tokenStore = tokenStore
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
        guard event == .stop, progress >= 80 else { return }
        guard isAnime(item) else { return }
        guard let token = await validAccessToken() else { return }
        try await updateList(item: item, accessToken: token)
    }

    // MARK: - Internal

    private func updateList(item: MediaItem, accessToken: String) async throws {
        guard let malID = extractMALID(from: item.providerIDs) else { return }

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

    private func extractMALID(from providerIDs: [String: String]) -> Int? {
        for (key, rawValue) in providerIDs {
            let value = rawValue.trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }
            switch key.lowercased() {
            case "mal", "myanimelist":
                return Int(value)
            default:
                continue
            }
        }
        return nil
    }
}
