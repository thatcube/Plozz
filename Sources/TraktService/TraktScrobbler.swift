import Foundation
import CoreModels
import CoreNetworking

/// Sends playback state to Trakt so the user's watches sync to their history.
///
/// Best-effort by contract — like the in-app progress report, a scrobble must
/// never interrupt or fail playback, so `scrobble(...)` is non-throwing and
/// swallows every error.
public protocol TraktScrobbling: Sendable {
    /// Records a playback event for `item` at `progress` (watched percent, 0...100).
    func scrobble(item: MediaItem, progress: Double, event: PlaybackEvent) async
}

/// No-op scrobbler used when Trakt is unconfigured or disconnected, so callers
/// can always inject a non-optional value.
public struct DisabledTraktScrobbler: TraktScrobbling {
    public init() {}
    public func scrobble(item: MediaItem, progress: Double, event: PlaybackEvent) async {}
}

/// Live scrobbler. An `actor` so token refresh is serialized and the type is
/// `Sendable` for use from the `@MainActor` player.
public actor TraktScrobbler: TraktScrobbling {
    private let client: TraktClient
    private let auth: TraktAuthService
    private let tokenStore: TraktTokenStoring

    public init(config: TraktConfig, http: HTTPClient, tokenStore: TraktTokenStoring) {
        self.client = TraktClient(config: config, http: http)
        self.auth = TraktAuthService(config: config, http: http)
        self.tokenStore = tokenStore
    }

    public func scrobble(item: MediaItem, progress: Double, event: PlaybackEvent) async {
        // Trakt only models start/pause/stop; periodic progress is inferred, so
        // we deliberately skip `.progress` to avoid spamming the scrobble API.
        guard let action = Self.action(for: event) else { return }
        guard let body = Self.scrobbleBody(for: item, progress: progress) else { return }
        guard let token = await validAccessToken() else { return }

        do {
            try await client.scrobble(action: action, body: body, accessToken: token)
            PlozzLog.playback.debug("Trakt scrobble \(action) succeeded")
        } catch {
            PlozzLog.playback.debug("Trakt scrobble failed (non-fatal)")
        }
    }

    /// Returns a usable access token, refreshing (and persisting) an expired one.
    /// `nil` means "not connected" or "refresh failed" — caller no-ops.
    private func validAccessToken() async -> String? {
        guard let tokens = tokenStore.load() else { return nil }
        guard tokens.isExpired else { return tokens.accessToken }
        do {
            let refreshed = try await auth.refresh(tokens.refreshToken)
            try? tokenStore.save(refreshed)
            return refreshed.accessToken
        } catch {
            PlozzLog.playback.debug("Trakt token refresh failed (non-fatal)")
            return nil
        }
    }

    // MARK: - Mapping

    /// Maps an in-app playback event to a Trakt scrobble action. `.progress`
    /// maps to `nil` (skipped).
    static func action(for event: PlaybackEvent) -> String? {
        switch event {
        case .start, .unpause: return "start"
        case .pause: return "pause"
        case .stop: return "stop"
        case .progress: return nil
        }
    }

    /// Builds a scrobble body from a `MediaItem`, or `nil` when the item can't be
    /// identified on Trakt (no usable external ids).
    static func scrobbleBody(for item: MediaItem, progress: Double) -> TraktScrobbleBody? {
        let clamped = min(max(progress, 0), 100)
        let ids = traktIDs(from: item.providerIDs)

        switch item.kind {
        case .episode:
            guard !ids.isEmpty else { return nil }
            let episode = TraktEpisodeRef(season: item.seasonNumber, number: item.episodeNumber, ids: ids)
            return TraktScrobbleBody(episode: episode, progress: clamped)
        case .movie, .video:
            guard !ids.isEmpty else { return nil }
            let movie = TraktMovieRef(title: item.title, year: item.productionYear, ids: ids)
            return TraktScrobbleBody(movie: movie, progress: clamped)
        default:
            // Series/seasons/folders aren't directly playable scrobble targets.
            return nil
        }
    }

    /// Extracts Trakt-shaped ids from a provider's id map, tolerating the
    /// differing key casing across providers (`Imdb`/`imdb`, `Tmdb`/`tmdb`, …).
    static func traktIDs(from providerIDs: [String: String]) -> TraktIDs {
        var ids = TraktIDs()
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
            case "trakt":
                ids.trakt = Int(value)
            default:
                continue
            }
        }
        return ids
    }
}
