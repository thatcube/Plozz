import Foundation

/// Per-profile playback preferences (pure data model, mirrors `SpoilerSettings`
/// / `CaptionSettings`).
///
/// Today this is the **Skip intros** behaviour: an Infuse-style four-way mode
/// (Off / On / Auto (delay) / Auto (instant)) governing whether — and how — the
/// player acts on server-detected intro/credits markers (see `MediaSegment`).
/// Modelled as data so defaults can move with real feedback and finer-grained
/// toggles can be added later without a rewrite.
public struct PlaybackSettings: Codable, Equatable, Sendable {
    /// How intros/credits are handled. Off by default — opt-in, and a no-op on
    /// servers/items that expose no markers. Covers both intros and credits.
    public var skipIntros: SkipIntrosMode

    /// Whether finishing/resuming/marking a title converges your watch state on
    /// **every** server that holds it (the default), or only the server you
    /// actually watched on. ON (default) preserves today's cross-server fan-out;
    /// OFF scopes writes to the origin server and suppresses all cross-server
    /// probing/expansion. Independent of Trakt, which is an account-level
    /// integration and keeps scrobbling either way.
    public var syncWatchAcrossServers: Bool

    public init(skipIntros: SkipIntrosMode = .off, syncWatchAcrossServers: Bool = true) {
        self.skipIntros = skipIntros
        self.syncWatchAcrossServers = syncWatchAcrossServers
    }

    public static let `default` = PlaybackSettings()
}

// MARK: - Codable (tolerant of older / future persisted payloads)

public extension PlaybackSettings {
    private enum CodingKeys: String, CodingKey {
        case skipIntros
        case syncWatchAcrossServers
    }

    /// Decodes leniently so a payload written before a field existed (or in the
    /// older boolean shape) still loads instead of resetting to defaults. The
    /// legacy `{"skipIntros": true/false}` boolean maps to `.on` / `.off`.
    /// `syncWatchAcrossServers` defaults to `true` when absent so installs that
    /// predate the toggle keep today's cross-server sync behaviour.
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
        self.syncWatchAcrossServers =
            (try? container.decodeIfPresent(Bool.self, forKey: .syncWatchAcrossServers))
            .flatMap { $0 } ?? defaults.syncWatchAcrossServers
    }
}
