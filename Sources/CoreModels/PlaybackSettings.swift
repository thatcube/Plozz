import Foundation

/// Per-profile playback preferences (pure data model, mirrors `SpoilerSettings`
/// / `CaptionSettings`).
///
/// Covers skip-intro behaviour, remote skip intervals, and cross-server watch
/// sync. Modelled as data so defaults can move with real feedback and
/// finer-grained toggles can be added later without a rewrite.
public struct PlaybackSettings: Codable, Equatable, Sendable {
    /// How intros/credits are handled. Off by default — opt-in, and a no-op on
    /// servers/items that expose no markers. Covers both intros and credits.
    public var skipIntros: SkipIntrosMode

    /// How many seconds a left-press on the Siri Remote skips backward.
    public var skipBackwardInterval: SkipInterval

    /// How many seconds a right-press on the Siri Remote skips forward.
    public var skipForwardInterval: SkipInterval

    /// Whether finishing/resuming/marking a title converges your watch state on
    /// **every** server that holds it (the default), or only the server you
    /// actually watched on. ON (default) preserves today's cross-server fan-out;
    /// OFF scopes writes to the origin server and suppresses all cross-server
    /// probing/expansion. Independent of Trakt, which is an account-level
    /// integration and keeps scrobbling either way.
    public var syncWatchAcrossServers: Bool

    public init(
        skipIntros: SkipIntrosMode = .off,
        skipBackwardInterval: SkipInterval = .ten,
        skipForwardInterval: SkipInterval = .ten,
        syncWatchAcrossServers: Bool = true
    ) {
        self.skipIntros = skipIntros
        self.skipBackwardInterval = skipBackwardInterval
        self.skipForwardInterval = skipForwardInterval
        self.syncWatchAcrossServers = syncWatchAcrossServers
    }

    public static let `default` = PlaybackSettings()
}

// MARK: - Codable (tolerant of older / future persisted payloads)

public extension PlaybackSettings {
    private enum CodingKeys: String, CodingKey {
        case skipIntros
        case skipBackwardInterval
        case skipForwardInterval
        case syncWatchAcrossServers
    }

    /// Decodes leniently so a payload written before a field existed (or in the
    /// older boolean shape) still loads instead of resetting to defaults. The
    /// legacy `{"skipIntros": true/false}` boolean maps to `.on` / `.off`.
    /// `syncWatchAcrossServers` defaults to `true` when absent so installs that
    /// predate the toggle keep today's cross-server sync behaviour.
    /// `skipBackwardInterval` / `skipForwardInterval` default to `.ten` when
    /// absent so existing installs keep the original 10-second skip behaviour.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = PlaybackSettings.default
        if let mode = try? container.decodeIfPresent(SkipIntrosMode.self, forKey: .skipIntros) {
            self.skipIntros = mode ?? defaults.skipIntros
        } else if let legacy = try? container.decodeIfPresent(Bool.self, forKey: .skipIntros) {
            self.skipIntros = (legacy ?? false) ? .on : .off
        } else {
            self.skipIntros = defaults.skipIntros
        }
        self.skipBackwardInterval =
            (try? container.decodeIfPresent(SkipInterval.self, forKey: .skipBackwardInterval))
            .flatMap { $0 } ?? defaults.skipBackwardInterval
        self.skipForwardInterval =
            (try? container.decodeIfPresent(SkipInterval.self, forKey: .skipForwardInterval))
            .flatMap { $0 } ?? defaults.skipForwardInterval
        self.syncWatchAcrossServers =
            (try? container.decodeIfPresent(Bool.self, forKey: .syncWatchAcrossServers))
            .flatMap { $0 } ?? defaults.syncWatchAcrossServers
    }
}
