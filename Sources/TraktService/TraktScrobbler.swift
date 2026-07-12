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

    /// Durable variant for the watch-state outbox: performs the same scrobble but
    /// **surfaces a failure** (so the reconciler can retry it) while treating
    /// "already scrobbled" (Trakt 409) and "nothing to scrobble" (not connected /
    /// unidentifiable item) as success — i.e. it only throws on a genuinely
    /// retryable error (token refresh / network).
    func scrobbleResult(item: MediaItem, progress: Double, event: PlaybackEvent) async throws
}

public extension TraktScrobbling {
    /// Default bridges to the best-effort `scrobble` (success unless overridden).
    func scrobbleResult(item: MediaItem, progress: Double, event: PlaybackEvent) async throws {
        await scrobble(item: item, progress: progress, event: event)
    }
}

/// No-op scrobbler used when Trakt is unconfigured or disconnected, so callers
/// can always inject a non-optional value.
public struct DisabledTraktScrobbler: TraktScrobbling {
    public init() {}
    public func scrobble(item: MediaItem, progress: Double, event: PlaybackEvent) async {}
}

final class TraktProfileGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: UInt64 = 0

    func advance(
        performing update: () -> Void = {}
    ) -> UInt64 {
        lock.lock()
        storage &+= 1
        update()
        let value = storage
        lock.unlock()
        return value
    }

    func performIfCurrent(
        _ generation: UInt64,
        operation: () -> Void
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard generation == storage else { return false }
        operation()
        return true
    }

    var current: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

/// Live scrobbler. An `actor` so token refresh is serialized and the type is
/// `Sendable` for use from the `@MainActor` player.
public actor TraktScrobbler: TraktScrobbling {
    private let client: TraktClient
    private let auth: TraktAuthService
    private let tokenStore: TraktTokenStoring
    private let profileGeneration: TraktProfileGeneration

    public init(
        config: TraktConfig,
        http: HTTPClient,
        tokenStore: TraktTokenStoring
    ) {
        self.init(
            config: config,
            http: http,
            tokenStore: tokenStore,
            profileGeneration: TraktProfileGeneration()
        )
    }

    init(
        config: TraktConfig,
        http: HTTPClient,
        tokenStore: TraktTokenStoring,
        profileGeneration: TraktProfileGeneration
    ) {
        self.client = TraktClient(config: config, http: http)
        self.auth = TraktAuthService(config: config, http: http)
        self.tokenStore = tokenStore
        self.profileGeneration = profileGeneration
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

    /// Durable variant: same scrobble, but rethrows a retryable failure (network /
    /// token refresh) so the outbox can retry, while a 409 is already swallowed as
    /// success inside ``TraktClient/scrobble`` and an unidentifiable / not-connected
    /// item is a no-op success.
    public func scrobbleResult(item: MediaItem, progress: Double, event: PlaybackEvent) async throws {
        guard let action = Self.action(for: event) else {
            FanoutDiagnostics.emit(FanoutDiagnostics.scrobbleLine(tracker: "trakt", item: item, outcome: "skip(event=\(event) not scrobbled)"))
            return
        }
        guard let body = Self.scrobbleBody(for: item, progress: progress) else {
            FanoutDiagnostics.emit(FanoutDiagnostics.scrobbleLine(tracker: "trakt", item: item, outcome: "skip(no usable ids)"))
            return
        }
        guard let token = await validAccessToken() else {
            FanoutDiagnostics.emit(FanoutDiagnostics.scrobbleLine(tracker: "trakt", item: item, outcome: "skip(not connected)"))
            return
        }
        do {
            try await client.scrobble(action: action, body: body, accessToken: token)
            FanoutDiagnostics.emit(FanoutDiagnostics.scrobbleLine(tracker: "trakt", item: item, outcome: "OK(\(action))"))
        } catch {
            FanoutDiagnostics.emit(FanoutDiagnostics.scrobbleLine(tracker: "trakt", item: item, outcome: "THROW(\(error))"))
            throw error
        }
    }

    /// Returns a usable access token, refreshing (and persisting) an expired one.
    /// `nil` means "not connected" or "refresh failed" — caller no-ops.
    private func validAccessToken() async -> String? {
        let generation = profileGeneration.current
        guard let tokens = tokenStore.load() else { return nil }
        guard tokens.isExpired else { return tokens.accessToken }
        do {
            let refreshed = try await auth.refresh(tokens.refreshToken)
            guard profileGeneration.performIfCurrent(
                generation,
                operation: { try? tokenStore.save(refreshed) }
            ) else {
                return nil
            }
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
