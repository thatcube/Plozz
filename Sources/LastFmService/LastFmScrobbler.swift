import Foundation
import CoreModels
import CoreNetworking

/// Sends listening activity to Last.fm. Best-effort by contract — failures are
/// logged and swallowed so a scrobble never disrupts playback.
///
/// The controller drives this with the SAME playback events it already reports to
/// the media server (start/unpause/stop), so wiring it in is just a fan-out.
public protocol LastFmScrobbling: Sendable {
    /// - Parameters:
    ///   - track: the track the event is about.
    ///   - event: the playback lifecycle event.
    ///   - position: seconds played when the event fired.
    ///   - duration: the engine-resolved track length (server metadata often omits it).
    func handle(track: MusicTrack, event: PlaybackEvent, position: TimeInterval, duration: TimeInterval) async
}

/// No-op scrobbler used when Last.fm is unconfigured/disconnected.
public struct DisabledLastFmScrobbler: LastFmScrobbling {
    public init() {}
    public func handle(track: MusicTrack, event: PlaybackEvent, position: TimeInterval, duration: TimeInterval) async {}
}

/// Live Last.fm scrobbler.
///
/// - `.start` / `.unpause` → `track.updateNowPlaying` (shows "Scrobbling now").
/// - completed `.stop` → `track.scrobble`, gated by Last.fm's own rule: the track
///   must be longer than 30s AND have played at least half its length (or 4
///   minutes, whichever comes first). This is independent of the Plex 80% gate.
public actor LastFmScrobbler: LastFmScrobbling {
    private let client: LastFmClient
    private let tokenStore: LastFmTokenStoring

    public init(config: LastFmConfig, http: HTTPClient, tokenStore: LastFmTokenStoring) {
        self.client = LastFmClient(config: config, http: http)
        self.tokenStore = tokenStore
    }

    public func handle(track: MusicTrack, event: PlaybackEvent, position: TimeInterval, duration: TimeInterval) async {
        guard let sessionKey = tokenStore.load()?.sessionKey else { return }
        guard let params = LastFmTrackParams(track, durationSeconds: duration) else { return }

        switch event {
        case .start, .unpause:
            do {
                try await client.updateNowPlaying(params, sessionKey: sessionKey)
                PlozzLog.playback.debug("Last.fm nowplaying '\(params.artist) – \(params.track)'")
            } catch {
                PlozzLog.playback.error("Last.fm nowplaying failed: \(String(describing: error))")
            }
        case .stop:
            guard Self.isScrobbleEligible(position: position, duration: duration) else { return }
            let timestamp = Int((Date().timeIntervalSince1970 - position).rounded())
            do {
                try await client.scrobble(params, timestamp: timestamp, sessionKey: sessionKey)
                PlozzLog.playback.debug("Last.fm scrobble '\(params.artist) – \(params.track)' @\(timestamp)")
            } catch {
                PlozzLog.playback.error("Last.fm scrobble failed: \(String(describing: error))")
            }
        case .pause, .progress:
            break
        }
    }

    /// Last.fm scrobble rule: length > 30s AND played ≥ min(50% of length, 4 min).
    static func isScrobbleEligible(position: TimeInterval, duration: TimeInterval) -> Bool {
        guard duration > 30 else { return false }
        let threshold = min(duration * 0.5, 240)
        return position >= threshold
    }
}
