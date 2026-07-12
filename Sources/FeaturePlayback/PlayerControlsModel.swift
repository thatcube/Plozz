#if canImport(UIKit)
import Foundation
import CoreGraphics
import Observation
import CoreModels

/// A selectable audio or subtitle option for the in-player track menu.
///
/// `id` is the option's index within its `AVMediaSelectionGroup`; the special
/// id `PlayerTrackOption.offID` represents "Off" (subtitles only).
public struct PlayerTrackOption: Identifiable, Hashable, Sendable {
    public static let offID = -1
    public var id: Int
    public var title: String
    public var isSelected: Bool
    /// `true` for an external (downloaded / sidecar) subtitle, so the menu can mark
    /// it apart from the media's embedded tracks.
    public var isExternal: Bool

    public init(id: Int, title: String, isSelected: Bool, isExternal: Bool = false) {
        self.id = id
        self.title = title
        self.isSelected = isSelected
        self.isExternal = isExternal
    }
}

/// Load state of a selected second (dual) subtitle track, surfaced on the
/// "Second Track" row. Lets the viewer see why a picked track isn't drawing.
public enum SecondarySubtitleStatus: Equatable, Sendable {
    /// The second line is Off — nothing to report.
    case idle
    /// Fetching + parsing the track's sidecar.
    case loading
    /// Loaded with this many cues (0 means the file yielded no lines).
    case loaded(cueCount: Int)
    /// The sidecar couldn't be fetched or decoded.
    case unavailable
}

/// State of the in-player subtitle **search + download** screen (server-proxied
/// on Jellyfin/Plex). Drives the results list, spinner, and empty/error copy.
public enum SubtitleDownloadState: Equatable, Sendable {
    /// Nothing searched yet.
    case idle
    /// Searching the server's subtitle source.
    case searching
    /// Candidate subtitles found (already ranked by the SDH/Forced preference).
    case results([RemoteSubtitle])
    /// The search returned no candidates (often: server has no source configured).
    case empty
    /// Downloading the candidate with this `RemoteSubtitle.id`.
    case downloading(String)
    /// Downloaded and loaded into the running player.
    case added
    /// The search or download failed.
    case failed
}

/// Shared, observable state for the custom player's transport overlay.
///
/// `PlayerViewModel` writes live playback facts (position, duration, buffered,
/// paused); the UIKit input controller writes scrub state and the resolved
/// preview thumbnail; the SwiftUI overlay only reads. Keeping it UI-framework
/// free (CoreGraphics only) lets the overlay stay a thin presentation layer.
@MainActor
@Observable
public final class PlayerControlsModel {
    // MARK: Live playback (written by the view model)
    public var duration: TimeInterval = 0
    public var currentSeconds: TimeInterval = 0
    public var bufferedSeconds: TimeInterval = 0
    public var isPaused: Bool = false
    /// The user's *intent* to be paused — mirrors the view model's truthful
    /// play/pause funnel (`intendsPause == !intendsPlayback`), not the engine's
    /// transient state. `isPaused` can flicker true for a moment after a committed
    /// seek (the producer-restart pipeline briefly reports paused before it
    /// resumes), which made the pause glyph blink on during a *seek-without-
    /// pausing*. The overlay shows the pause indicator only when BOTH `isPaused`
    /// and `intendsPause` hold — i.e. the viewer actually pressed pause — so a
    /// plain seek shows only the loading spinner, never a phantom pause.
    public var intendsPause: Bool = false
    /// True while a committed seek is resolving, so the overlay can show a spinner.
    public var isSeeking: Bool = false

    /// True while the view model is actively re-asserting playback after a
    /// committed seek (the post-seek "did it actually resume?" recovery loop).
    /// The engine can settle into a transient paused/rate-0 state the instant a
    /// seek lands on a buffering edge; the container must NOT mirror that into
    /// `isPaused` while this is set, or the pause icon flickers on by itself and
    /// the recovery loop sees its own engine as "user-paused".
    public var isResumeConfirming: Bool = false

    /// The latest *committed* seek destination that hasn't yet been reached by
    /// the engine. While non-nil, the engine-poll refresh loop must NOT
    /// overwrite `currentSeconds` with the live engine time — that's what
    /// caused the "press right → snaps back" feel: a 300ms poll arrived
    /// between the optimistic position update and the engine actually arriving,
    /// and snapped the bar back to the *old* position. With this in place, the
    /// scrub head holds at the optimistic target until the engine catches up
    /// (within a small tolerance), then we release.
    public var pendingSeekTarget: TimeInterval?

    /// True until a committed seek has landed, its optimistic timeline position
    /// has reconciled, and playback has demonstrably resumed. Controls must not
    /// auto-hide during any part of this window.
    public var isSeekLoading: Bool {
        isSeeking || isResumeConfirming || pendingSeekTarget != nil
    }

    // MARK: Presentation
    public var title: String = ""
    public var subtitle: String = ""
    public var hasTrickplay: Bool = false

    // MARK: Info panel
    /// Episode title (or movie title) for the now-playing Info card headline —
    /// distinct from `title`, which for episodes holds the *series* name.
    public var infoHeadline: String = ""
    /// Long-form synopsis for the now-playing Info card.
    public var overview: String = ""
    /// Technical badges (resolution/codec/HDR/etc.) for the Info card.
    public var infoBadges: [MediaBadge] = []
    /// Ordered artwork candidates (image → backdrop → poster) for the Info thumbnail.
    public var artworkURLs: [URL] = []
    /// Pre-formatted runtime label (e.g. "37 min") for the Info card meta line.
    public var infoRuntimeLabel: String = ""
    /// Compact season/episode tag for the Info card metadata row (e.g. "S2 · E7").
    /// Empty for movies.
    public var infoEpisodeTag: String = ""
    /// Whether a following episode exists to jump to from the Info card.
    public var hasNextEpisode: Bool = false
    /// Whether a preceding episode exists to jump to from the Info card.
    public var hasPreviousEpisode: Bool = false

    // MARK: Track menus
    public var audioOptions: [PlayerTrackOption] = []
    public var subtitleOptions: [PlayerTrackOption] = []
    /// Eligible tracks for the **second** (dual) subtitle line, as an ordered
    /// picker: "Off" first, then the text subtitle tracks that can drive Plozz's
    /// overlay (a sidecar URL, non-image) excluding whatever is the primary. The
    /// selected entry is flagged `isSelected`. Empty of real tracks means the
    /// current media has nothing a second line could show.
    public var secondarySubtitleOptions: [PlayerTrackOption] = []
    /// Load state of the currently-selected second subtitle track, surfaced on the
    /// "Second Track" row so the viewer can see *why* a picked track isn't drawing
    /// (fetching, no cues in the file, or the sidecar was unavailable) instead of
    /// silently showing nothing. `.idle` when the second line is Off.
    public var secondarySubtitleStatus: SecondarySubtitleStatus = .idle
    /// When non-`nil`, the dual (second) subtitle line is *disallowed* because the
    /// PRIMARY subtitle is a bitmap format (PGS/DVD/DVB/VobSub) that draws at its
    /// own uncontrollable authored position and so can't be positionally stacked
    /// against a second line. Carries the primary's short format hint (e.g. "PGS",
    /// "DVD", "Image") so the picker can explain the reason ("Unavailable with PGS
    /// subtitles") instead of an ambiguous "None available". `nil` when dual is
    /// available — including when it's empty for the ordinary reason that the media
    /// simply has no other text track to show.
    public var secondarySubtitleImagePrimaryFormat: String? = nil

    // MARK: Subtitle search / download
    /// Whether the active provider supports server-proxied subtitle search &
    /// download (Jellyfin/Plex advertise `.remoteSubtitles`; SMB does not). Gates
    /// the "Search for subtitles…" entry row.
    public var canSearchRemoteSubtitles: Bool = false
    /// State of the in-player subtitle search/download screen.
    public var subtitleDownloadState: SubtitleDownloadState = .idle

    #if DEBUG
    /// DEBUG-only readout of how the *primary* selected subtitle is being routed:
    /// active engine · path (overlay-sidecar / avplayer-draw / live-feed) · live
    /// cue count. Surfaced at the bottom of the Subtitles list so we can see — on
    /// a device whose logs are unreadable in this environment — exactly why a
    /// Plex embedded track lists but never draws. Empty when nothing is selected.
    public var primarySubtitleDiagnostic: String = ""
    #endif

    /// The current subtitle **appearance**, mirrored here so the in-player
    /// appearance editor (hosted in `PlayerControls`) can two-way bind it. The
    /// view model seeds this from the profile's persisted style and updates it
    /// on every edit, keeping the live overlay, this mirror, and persistence in
    /// lock-step.
    public var subtitleStyle: SubtitleStyle = .default

    /// Whether the subtitle overlay is currently rendering over an HDR frame
    /// (the panel is being driven to an HDR/DV display mode). Only then does the
    /// style's `hdrLuminanceScale` do anything, so the menu shows the "HDR
    /// Brightness" row exclusively while this is true — no dead control on SDR.
    public var subtitlesRenderHDR: Bool = false

    // MARK: Live tunables (mirrors of engine state)
    /// What the active engine supports — drives which rows the options menu
    /// renders so AVPlayer doesn't show fake delay sliders, etc.
    public var engineCapabilities: PlayerEngineCapabilities = []
    /// Current playback speed (1.0 == normal).
    public var playbackSpeed: Double = 1.0
    /// Audio offset in seconds (positive = audio later than video).
    public var audioDelaySeconds: TimeInterval = 0
    /// Subtitle offset in seconds (positive = subs later than video).
    public var subtitleDelaySeconds: TimeInterval = 0
    /// Whether subtitle timing can actually be shifted right now: true when the
    /// app's overlay owns the active primary subtitle (a sidecar timeline or an
    /// engine live-feed), so the app-side offset moves the on-screen track.
    /// False when subtitles are off or the underlying player draws an embedded
    /// text track we can't shift. Gates the in-player "Sync" control.
    public var subtitleDelayAdjustable: Bool = false
    /// Whether the dialog-enhance audio filter is engaged (when supported).
    public var dialogEnhanceEnabled: Bool = false

    // MARK: Transport UI state (written by the input controller)
    public var controlsVisible: Bool = false
    public var isScrubbing: Bool = false
    public var scrubSeconds: TimeInterval = 0
    /// The trickplay frame for `scrubSeconds`, shown above the scrub head.
    public var previewImage: CGImage?
    /// Whether a real scrub-preview frame is available for display.
    public var hasPreviewFrame: Bool { previewImage != nil }
    /// True while the focusable bottom control bar owns Siri-Remote focus. The
    /// input controller reads this to suppress scrub gestures and the control bar
    /// reads it to take/relinquish focus.
    public var controlBarVisible: Bool = false

    // MARK: Skip hint (transient ±Ns indicator)
    /// How many seconds a left-press skips backward (per-profile setting).
    public var skipBackwardInterval: SkipInterval = .ten
    /// How many seconds a right-press skips forward (per-profile setting).
    public var skipForwardInterval: SkipInterval = .ten
    /// Whether a horizontal scrub gesture works while playing (per-profile
    /// setting, default true). When false, a swipe during playback is a no-op
    /// for the timeline (no seek, no pause) — the input controller reads this to
    /// gate `beginScrub` so you must pause the video first before scrubbing, and
    /// a stray swipe can't move your position or pause playback.
    public var seekWithoutPausing: Bool = true
    /// Whether the last skip was forward; drives which glyph the hint shows.
    public var skipHintForward: Bool = true
    /// True while the transient skip indicator is on screen.
    public var skipHintVisible: Bool = false
    /// Bumped on every skip so the indicator's pop-in transition replays even
    /// when it's already visible (rapid repeated skips).
    public var skipHintToken: Int = 0
    /// Which side of the thumb the loading spinner sits on while a seek resolves:
    /// the left of the current time after a backward skip, otherwise the right
    /// (forward skip or a plain scrub). Mirrors where the ±10s glyph appeared.
    public var seekIndicatorOnLeft: Bool = false

    /// Whether the live playback-diagnostics overlay is shown. Toggleable from
    /// the in-player control bar; seeded from the caller's initial preference.
    public var diagnosticsEnabled: Bool = false

    // MARK: Skip intros/credits
    /// Server-detected skippable segments (intros/credits) for the playing item.
    /// Populated by the view model only when the per-profile Skip Intros setting
    /// is on; empty otherwise, so no skip button is ever offered.
    public var skippableSegments: [MediaSegment] = []
    /// True while the user has dismissed the skip button for the *current*
    /// segment, so it doesn't keep re-grabbing focus for the rest of that window.
    public var dismissedSegmentID: String?

    /// Mirrors `CustomPlayerContainer.presentingSkipButton`: true only while the
    /// container has actually *presented* the Skip button (focused or the passive
    /// grace-seek present). The SwiftUI `SkipSegmentButton` renders on this — not
    /// the raw `skipButtonVisible` — so it can never draw on top of an open menu
    /// or steal the lower-right slot the container hasn't handed it.
    public var isPresentingSkipButton: Bool = false

    /// Set when a committed seek lands inside a skippable segment, describing how
    /// the landing relates to that segment so the presentation layer can respect
    /// the seek: a *deep* landing (`isWithinGrace == false`) suppresses the Skip
    /// affordance entirely; a *grace-window* landing offers a manual button only
    /// (no auto-skip/countdown, no focus-steal). Cleared automatically once the
    /// live position leaves the segment, so a later natural re-entry is unaffected.
    public var seekLanding: SkipSeekLanding?

    // MARK: Up Next (closing-credits next-episode card)
    /// Presentation data for the next episode, resolved (with spoiler masking)
    /// by the view model when a next episode exists and the Up Next setting is on.
    /// `nil` for movies, the final episode, or when the card is disabled — in
    /// which case no Up Next card is ever offered and credits behave normally.
    public var upNext: UpNextInfo?
    /// True once the user has dismissed the Up Next card for the current item, so
    /// it doesn't keep re-grabbing focus through the rest of the credits.
    public var dismissedUpNext: Bool = false
    /// Mirrors `CustomPlayerContainer.presentingUpNext`: true only while the
    /// container has actually *presented* the Up Next card (focused or the passive
    /// grace-seek present). The SwiftUI `UpNextCardView` renders on this — not the
    /// raw `upNextActive` — so it renders in lockstep with the container's focus
    /// state and never draws on top of an open menu (the root cause of Back
    /// exiting the whole player instead of dismissing the card).
    public var isPresentingUpNext: Bool = false
    /// In `.autoDelay`, the playback position (seconds) at which the Up Next card
    /// auto-advances to the next episode. Drives the card's countdown ring; `nil`
    /// when not counting down.
    public var upNextAdvanceAtSeconds: TimeInterval?

    public init() {}

    /// Where the transport playhead should render: the scrub target while
    /// scrubbing, otherwise the live position.
    public var displaySeconds: TimeInterval { isScrubbing ? scrubSeconds : currentSeconds }

    public var progressFraction: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, displaySeconds / duration))
    }

    public var bufferedFraction: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, bufferedSeconds / duration))
    }

    public var hasSelectableAudio: Bool { audioOptions.count > 1 }
    public var hasSelectableSubtitles: Bool { !subtitleOptions.isEmpty }

    /// The skippable segment whose window currently contains the live position,
    /// unless the user already dismissed that segment's button — or a committed
    /// seek landed *deep* inside it (past the opening grace window), which we read
    /// as a deliberate jump into the segment and therefore respect by offering no
    /// button at all. Drives whether the in-player Skip button is shown/focusable.
    public var activeSkipSegment: MediaSegment? {
        guard let segment = skippableSegments.activeSkippable(at: currentSeconds) else { return nil }
        if segment.id == dismissedSegmentID { return nil }
        // Deep-seek suppression: a seek that landed beyond the grace window of
        // this exact segment means the viewer jumped *into* it on purpose — honor
        // the seek and surface nothing. (Grace-window landings keep the segment so
        // a manual, non-focus-stealing button can still be offered.)
        if let landing = seekLanding, landing.segmentID == segment.id, !landing.isWithinGrace {
            return nil
        }
        return segment
    }

    /// Whether the currently-active skip segment was entered via a *seek* that
    /// landed inside its opening grace window (as opposed to natural playback).
    /// When true the presentation layer offers a manual Skip button only — no
    /// auto-skip, no countdown, and no focus-steal — so a deliberate seek is never
    /// hijacked. Natural entry (this is false) keeps the full per-mode behavior.
    public var activeSkipWasSeekEntered: Bool {
        guard let landing = seekLanding, let segment = activeSkipSegment else { return false }
        return landing.segmentID == segment.id && landing.isWithinGrace
    }

    /// Whether the in-player Skip button should be visible at all. Mirrors the
    /// rendering gate the overlay uses: shown whenever a segment is active and the
    /// mode offers a manual button (On / Auto-delay), or the segment was
    /// seek-entered (which always offers a manual button regardless of mode). The
    /// Up Next card supersedes the Skip Credits button, so it's hidden whenever
    /// the Up Next card owns the lower-right slot — the two never co-occur.
    public var skipButtonVisible: Bool {
        guard activeSkipSegment != nil else { return false }
        if creditsOwnedByUpNext { return false }
        // Skip OFF must never surface a button — even after a grace-window seek.
        // Markers are now fetched when the Up Next card is enabled (skip can be
        // off), so without this guard a seek near an intro/credits marker would
        // resurrect a Skip button the viewer turned off.
        guard skipMode != .off else { return false }
        if activeSkipWasSeekEntered { return true }
        return skipMode == .on || skipMode == .autoDelay
    }

    // MARK: Up Next presentation

    /// The active skippable segment when it is the closing **credits** (not an
    /// intro). Factors in deep-seek suppression via ``activeSkipSegment``, so a
    /// deliberate deep seek into credits returns `nil` (the seek is respected).
    public var activeCreditsSegment: MediaSegment? {
        guard let segment = activeSkipSegment, segment.kind == .credits else { return nil }
        return segment
    }

    /// Credits with a queued next episode are "owned" by Up Next: the Skip
    /// Credits button is never offered for that window — the card, an auto-advance,
    /// or a dismissal handles it — so the two affordances can never both appear.
    /// (A deep seek into credits clears ``activeCreditsSegment``, so a deliberate
    /// jump still falls through to normal handling.)
    public var creditsOwnedByUpNext: Bool {
        upNext != nil && activeCreditsSegment != nil
    }

    /// Seconds before the end at which the Up Next card appears when there is NO
    /// closing-credits marker to anchor it — marker-less servers (SMB shares) or
    /// content the server never analysed for segments. Marker-based content still
    /// triggers on its real credits segment (usually earlier / more accurate).
    /// Set from the profile's `PlaybackSettings.upNextLeadSeconds`; default 30s.
    public var upNextLeadSeconds: TimeInterval = 30

    /// Whether playback is in its final stretch by time alone — the fallback
    /// trigger for the Up Next card when there's no credits marker. Guarded on a
    /// known duration and real forward progress so it never fires at position 0 or
    /// on a live / unknown-duration stream. `duration`/`currentSeconds` are kept
    /// live from the engine each tick, so this works even for SMB items that carry
    /// no server-provided runtime until played.
    public var isNearEndByTime: Bool {
        guard duration > 0, currentSeconds > 0 else { return false }
        let remaining = duration - currentSeconds
        return remaining > 0 && remaining <= upNextLeadSeconds
    }

    /// Whether this content has a closing-credits marker at all. When it does, the
    /// Up Next card waits for that (accurate) marker rather than the time fallback;
    /// when it doesn't (SMB shares, unanalysed content), the time fallback applies.
    public var hasCreditsMarker: Bool {
        skippableSegments.contains { $0.kind == .credits }
    }

    /// Whether the Up Next card should own the lower-right slot right now: there's
    /// a queued next episode, the user hasn't dismissed the card, and we've reached
    /// the hand-off window — the server's closing-credits marker (accurate, when
    /// provided) OR, only for content with NO credits marker (SMB shares), the
    /// final ``markerlessUpNextLeadSeconds`` by time. Marker-based content is
    /// unaffected — it still triggers exactly on its credits segment.
    public var upNextActive: Bool {
        guard !dismissedUpNext, upNext != nil else { return false }
        if creditsOwnedByUpNext { return true }
        return !hasCreditsMarker && isNearEndByTime
    }

    /// How intros/credits are handled (Off / On / Auto (delay) / Auto (instant)).
    /// Mirrors the per-profile setting; set when markers load. Drives whether the
    /// Skip button is surfaced, auto-skipped after a delay, or skipped instantly.
    public var skipMode: SkipIntrosMode = .off

    /// In `.autoDelay`, the playback position (seconds) at which the active
    /// segment auto-skips. Set while the button counts down; `nil` otherwise.
    /// The button's ring depletes toward this so the wait is visible.
    public var autoSkipAtSeconds: TimeInterval?

    /// A transient, non-interactive confirmation shown briefly after a segment is
    /// auto-skipped instantly (e.g. "Skipping Intro"). Set by the view model and
    /// cleared on a short timer; `nil` the rest of the time.
    public var autoSkipNotice: AutoSkipNotice?
}

/// Describes where a committed seek landed relative to a skippable segment, so
/// the player can honor a deliberate seek (Option B): a deep landing suppresses
/// the Skip affordance, a grace-window landing offers a manual button only.
public struct SkipSeekLanding: Equatable, Sendable {
    /// The skippable segment the seek landed inside.
    public let segmentID: String
    /// Whether the landing fell within the segment's opening grace window. `true`
    /// → still offer a manual Skip button; `false` → suppress it (respect the seek).
    public let isWithinGrace: Bool

    public init(segmentID: String, isWithinGrace: Bool) {
        self.segmentID = segmentID
        self.isWithinGrace = isWithinGrace
    }
}

/// A brief on-screen confirmation that an intro/credits segment was skipped
/// automatically. A fresh `id` per occurrence re-triggers the reveal animation
/// even when consecutive notices share the same `label`.
public struct AutoSkipNotice: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let label: String

    public init(label: String) {
        self.id = UUID()
        self.label = label
    }
}

/// Spoiler-aware presentation data for the "Up Next" card shown during an
/// episode's closing credits. Built once by the view model when the next episode
/// resolves, so all spoiler masking is decided up front and the view/container
/// just render it. Equatable so the overlay diffs cheaply.
public struct UpNextInfo: Equatable, Sendable {
    /// The episode to advance to when the card is actioned. Passed back through
    /// `playEpisode` for the in-place VM swap (never a seek-to-end, so the next
    /// episode never flashes the series page).
    public let episode: MediaItem
    /// Eyebrow line above the title (always "Up Next").
    public let eyebrow: String
    /// The **show** name (series title) — the card's prominent line. The show is
    /// never a spoiler (you're already watching it) and stays readable where a
    /// long, often-obscure episode title would just truncate. Falls back to the
    /// episode title (spoiler-masked when needed) only when the series title is
    /// unknown.
    public let showName: String
    /// Secondary meta line, e.g. "S2 · E3 · 48m" (season/episode + runtime).
    /// Season/episode numbers and runtime are never spoilers, so this shows even
    /// when the thumbnail is masked.
    public let metaLine: String?
    /// Ordered thumbnail candidates: the real episode still when it may be shown,
    /// or the spoiler-safe series backdrop (never the episode's own frame) when
    /// the thumbnail is hidden in placeholder mode.
    public let thumbnailURLs: [URL]
    /// Whether to blur the (real) thumbnail — spoiler "blur" mode over the still.
    public let blurThumbnail: Bool

    public init(
        episode: MediaItem,
        eyebrow: String = "Up Next",
        showName: String,
        metaLine: String?,
        thumbnailURLs: [URL],
        blurThumbnail: Bool
    ) {
        self.episode = episode
        self.eyebrow = eyebrow
        self.showName = showName
        self.metaLine = metaLine
        self.thumbnailURLs = thumbnailURLs
        self.blurThumbnail = blurThumbnail
    }
}
#endif
