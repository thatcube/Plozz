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

    /// How many seconds *earlier* than the saved resume point a partially-watched
    /// title starts when you return to it ("resume rewind"). A gentle nudge to
    /// re-establish context. `.five` by default; `.off` restores exact resume.
    public var resumeRewindInterval: ResumeRewindInterval

    /// Whether finishing/resuming/marking a title converges your watch state on
    /// **every** server that holds it (the default), or only the server you
    /// actually watched on. ON (default) preserves today's cross-server fan-out;
    /// OFF scopes writes to the origin server and suppresses all cross-server
    /// probing/expansion. Independent of Trakt, which is an account-level
    /// integration and keeps scrobbling either way.
    public var syncWatchAcrossServers: Bool

    /// Whether a horizontal scrub gesture works **while playing** (the default),
    /// or only after you pause. ON (default) keeps today's faster "seek without
    /// pausing" feel — swipe to scrub mid-playback and it auto-resumes on
    /// landing. OFF makes a swipe during playback a no-op for the timeline (it
    /// neither seeks nor pauses): you must pause the video yourself first (remote
    /// Play/Pause, or a center-press on the scrub timeline), then scrub while
    /// paused; it stays paused on landing until you explicitly resume. This makes
    /// accidental seeks impossible while playing.
    public var seekWithoutPausing: Bool

    /// Whether the "Up Next" card is offered during an episode's closing credits
    /// when a next episode is queued. ON (default) shows a spoiler-safe card with
    /// the next episode's thumbnail so you can advance with one press (and it
    /// supersedes the Skip Credits button, since skipping to a black final frame
    /// is pointless when intent is "play next"). OFF never shows the card; credits
    /// fall back to the normal Skip Credits / natural-end auto-advance behaviour.
    /// Only ever applies to episodes with a next episode — movies are unaffected.
    public var showUpNextCard: Bool

    /// How many seconds before the end the Up Next card appears for content with
    /// **no** closing-credits marker — local/SMB files (and anything the server
    /// never analysed for segments). Server-marker content (Jellyfin/Plex) still
    /// triggers on its real credits segment and ignores this. There's no reliable
    /// way to detect where credits start in a bare file, so this mirrors how Kodi's
    /// Up Next and Infuse behave: a fixed, user-tunable lead time. Default 30s.
    public var upNextLeadSeconds: Int

    /// The profile's default audio-language preference: original spoken language
    /// (e.g. Japanese for anime), the viewer's device language (dub-friendly), or
    /// an explicit language. `.original` by default — the maintainer's primary
    /// user watches mostly anime and wants subbed originals. Per-content-type
    /// overrides ("original for anime, device for everything else") live in
    /// `AudioPolicy`; this is the base they fall back to.
    ///
    /// Replaces the legacy `preferOriginalLanguageAudio` boolean (`true` →
    /// `.original`, `false` → `.device`), migrated in the decoder below.
    public var audioLanguagePreference: AudioLanguagePreference

    /// Remember the chosen **audio language** per series: switching audio on any
    /// episode makes that language stick for every other episode of that series
    /// (per profile). Stored by language, re-resolved to a concrete track per
    /// episode. ON by default (mirrors Plex/Jellyfin).
    public var rememberAudioTrackPerSeries: Bool

    /// Remember the chosen **subtitle language (or Off)** per series, the subtitle
    /// counterpart to `rememberAudioTrackPerSeries`. ON by default.
    public var rememberSubtitleTrackPerSeries: Bool

    public init(
        skipIntros: SkipIntrosMode = .off,
        skipBackwardInterval: SkipInterval = .ten,
        skipForwardInterval: SkipInterval = .ten,
        resumeRewindInterval: ResumeRewindInterval = .five,
        syncWatchAcrossServers: Bool = true,
        seekWithoutPausing: Bool = true,
        showUpNextCard: Bool = true,
        upNextLeadSeconds: Int = 30,
        audioLanguagePreference: AudioLanguagePreference = .original,
        rememberAudioTrackPerSeries: Bool = true,
        rememberSubtitleTrackPerSeries: Bool = true
    ) {
        self.skipIntros = skipIntros
        self.skipBackwardInterval = skipBackwardInterval
        self.skipForwardInterval = skipForwardInterval
        self.resumeRewindInterval = resumeRewindInterval
        self.syncWatchAcrossServers = syncWatchAcrossServers
        self.seekWithoutPausing = seekWithoutPausing
        self.showUpNextCard = showUpNextCard
        self.upNextLeadSeconds = upNextLeadSeconds
        self.audioLanguagePreference = audioLanguagePreference
        self.rememberAudioTrackPerSeries = rememberAudioTrackPerSeries
        self.rememberSubtitleTrackPerSeries = rememberSubtitleTrackPerSeries
    }

    public static let `default` = PlaybackSettings()

    /// Selectable values (seconds) for ``upNextLeadSeconds`` in Settings. A small,
    /// curated set — err late (never interrupt real content) with room to go
    /// earlier for shows with long credits. `default`'s 30s must be a member.
    public static let upNextLeadSecondsOptions: [Int] = [15, 20, 30, 45, 60]
}

// MARK: - Codable (tolerant of older / future persisted payloads)

public extension PlaybackSettings {
    private enum CodingKeys: String, CodingKey {
        case skipIntros
        case skipBackwardInterval
        case skipForwardInterval
        case resumeRewindInterval
        case syncWatchAcrossServers
        case seekWithoutPausing
        case showUpNextCard
        case upNextLeadSeconds
        case audioLanguagePreference
        /// Legacy boolean predecessor of `audioLanguagePreference`, still read for
        /// migration (`true` → `.original`, `false` → `.device`).
        case preferOriginalLanguageAudio
        case rememberAudioTrackPerSeries
        case rememberSubtitleTrackPerSeries
    }

    /// Decodes leniently so a payload written before a field existed (or in the
    /// older boolean shape) still loads instead of resetting to defaults. The
    /// legacy `{"skipIntros": true/false}` boolean maps to `.on` / `.off`.
    /// `syncWatchAcrossServers` defaults to `true` when absent so installs that
    /// predate the toggle keep today's cross-server sync behaviour.
    /// `seekWithoutPausing` likewise defaults to `true` so existing installs keep
    /// today's scrub-while-playing behaviour.
    /// `showUpNextCard` defaults to `true` so existing installs get the Up Next
    /// card during episode credits.
    /// `skipBackwardInterval` / `skipForwardInterval` default to `.ten` when
    /// absent so existing installs keep the original 10-second skip behaviour.
    /// `resumeRewindInterval` defaults to `.five` when absent — the maintainer
    /// wants the resume-rewind nudge on for upgrading installs too, not just fresh
    /// ones (`.off` is available for anyone who prefers exact resume).
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
        self.resumeRewindInterval =
            (try? container.decodeIfPresent(ResumeRewindInterval.self, forKey: .resumeRewindInterval))
            .flatMap { $0 } ?? defaults.resumeRewindInterval
        self.syncWatchAcrossServers =
            (try? container.decodeIfPresent(Bool.self, forKey: .syncWatchAcrossServers))
            .flatMap { $0 } ?? defaults.syncWatchAcrossServers
        self.seekWithoutPausing =
            (try? container.decodeIfPresent(Bool.self, forKey: .seekWithoutPausing))
            .flatMap { $0 } ?? defaults.seekWithoutPausing
        self.showUpNextCard =
            (try? container.decodeIfPresent(Bool.self, forKey: .showUpNextCard))
            .flatMap { $0 } ?? defaults.showUpNextCard
        self.upNextLeadSeconds =
            (try? container.decodeIfPresent(Int.self, forKey: .upNextLeadSeconds))
            .flatMap { $0 } ?? defaults.upNextLeadSeconds
        // Prefer the new preference; fall back to the legacy boolean (true →
        // original, false → device) so installs that predate the dropdown keep
        // their prefer-original choice; default to `.original` when neither is set.
        if let preference = try? container.decodeIfPresent(AudioLanguagePreference.self, forKey: .audioLanguagePreference) {
            self.audioLanguagePreference = preference
        } else if let legacy = try? container.decodeIfPresent(Bool.self, forKey: .preferOriginalLanguageAudio) {
            self.audioLanguagePreference = legacy ? .original : .device
        } else {
            self.audioLanguagePreference = defaults.audioLanguagePreference
        }
        self.rememberAudioTrackPerSeries =
            (try? container.decodeIfPresent(Bool.self, forKey: .rememberAudioTrackPerSeries))
            .flatMap { $0 } ?? defaults.rememberAudioTrackPerSeries
        self.rememberSubtitleTrackPerSeries =
            (try? container.decodeIfPresent(Bool.self, forKey: .rememberSubtitleTrackPerSeries))
            .flatMap { $0 } ?? defaults.rememberSubtitleTrackPerSeries
    }

    /// Explicit encoder so the legacy-only `preferOriginalLanguageAudio` coding
    /// key (kept for decode-time migration) doesn't break Encodable synthesis and
    /// is never written back — only the current `audioLanguagePreference` is
    /// persisted.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(skipIntros, forKey: .skipIntros)
        try container.encode(skipBackwardInterval, forKey: .skipBackwardInterval)
        try container.encode(skipForwardInterval, forKey: .skipForwardInterval)
        try container.encode(resumeRewindInterval, forKey: .resumeRewindInterval)
        try container.encode(syncWatchAcrossServers, forKey: .syncWatchAcrossServers)
        try container.encode(seekWithoutPausing, forKey: .seekWithoutPausing)
        try container.encode(showUpNextCard, forKey: .showUpNextCard)
        try container.encode(upNextLeadSeconds, forKey: .upNextLeadSeconds)
        try container.encode(audioLanguagePreference, forKey: .audioLanguagePreference)
        try container.encode(rememberAudioTrackPerSeries, forKey: .rememberAudioTrackPerSeries)
        try container.encode(rememberSubtitleTrackPerSeries, forKey: .rememberSubtitleTrackPerSeries)
    }
}
