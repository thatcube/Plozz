#if canImport(AVFoundation)
import Foundation
import AVFoundation
import Observation
import CoreModels
import CoreNetworking
import TraktService
import MetadataKit
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Orchestrates a single playback session over a `VideoEngine`.
///
/// The view model owns the provider-facing concerns — resolving a
/// `PlaybackRequest`, reporting progress so resume points stay in sync, the
/// automatic transcode fallback policy, and auto subtitle download — and drives a
/// `VideoEngine` (a `NativeVideoEngine` by default) for the actual playback
/// mechanics. The engine knows nothing about the provider; it reports *when*
/// something happens (a report-cadence tick, a playback failure) and the view
/// model decides what to do about it.
///
/// Responsibilities:
///  * resolve a `PlaybackRequest` via the provider;
///  * seek to the saved resume position on start (delegated to the engine);
///  * report progress to the server periodically + on pause/stop so resume
///    points stay in sync (Phase 1 requirement);
///  * surface a graceful error state instead of a blank screen.
@MainActor
@Observable
public final class PlayerViewModel {
    public enum Phase: Equatable {
        case loading
        case ready
        case failed(AppError)
    }

    public private(set) var phase: Phase = .loading

    /// A fully-resolved, engine-routed playback ready to be adopted verbatim —
    /// no `playbackInfo` re-resolve needed. Produced by the next-episode prefetch
    /// (``prefetchedNext``) on the outgoing player and injected into the incoming
    /// player (``adoptedResolved``) so an episode hand-off skips the network
    /// resolve, commits the right engine immediately, and reuses the already-open
    /// server session (Jellyfin) rather than minting a second one.
    public struct PrefetchedPlayback: Sendable {
        public let itemID: String
        public let request: PlaybackRequest
        public let engineKind: PlaybackEngineKind
        public init(itemID: String, request: PlaybackRequest, engineKind: PlaybackEngineKind) {
            self.itemID = itemID
            self.request = request
            self.engineKind = engineKind
        }
    }

    /// True from bring-up until the engine is genuinely presenting moving frames.
    /// While it's set (and we're not in `.failed`), the bring-up spinner stays up,
    /// so the viewer sees ONE continuous loading indicator from tap → first frame
    /// instead of a spinner that vanishes the instant `engine.load()` returns and
    /// then a black gap / second in-player spinner while the picture actually
    /// arrives. Driven by ``beginAwaitingFirstFrame``.
    public private(set) var awaitingFirstFrame = false

    /// Whether the full-screen bring-up spinner should be shown: while resolving/
    /// loading, and while `.ready` but the first frame hasn't been presented yet.
    /// Off once frames advance (or on failure). Lets the view keep a single
    /// spinner across the `.loading` → `.ready` boundary.
    public var showBringUpSpinner: Bool {
        switch phase {
        case .loading: return true
        case .ready: return awaitingFirstFrame
        case .failed: return false
        }
    }

    /// Set to `true` when playback reaches its natural end *and* this player was
    /// configured to auto-dismiss on completion (currently trailers). The view
    /// observes this and dismisses itself. Ignored for regular library playback,
    /// which keeps the finished frame on screen as before.
    public private(set) var shouldDismiss = false

    /// The dynamic-range class the connected display is currently being driven
    /// to. `.sdr` until a request resolves on the **native** engine. Drives the
    /// HDR/Dolby-Vision display-mode transition smoothing in `PlayerView`: when
    /// this moves off `.sdr`, the TV switches HDMI display mode, so the view
    /// fades to black around the switch.
    ///
    /// Only the native engine drives `AVDisplayManager`'s HDMI mode switch; the
    /// Plozzigen engine renders HDR without a panel mode switch, so it stays
    /// `.sdr` here and the view never raises an unnecessary veil. Provider-
    /// agnostic — derived from `MediaSourceMetadata`, identical for Plex/Jellyfin.
    private(set) var displayMode: HDRDisplayMode = .sdr

    /// The dynamic range of the **content** being played, independent of which
    /// engine renders it. `displayMode` only goes HDR for the native engine
    /// (the only one that drives `AVDisplayManager`'s mode switch *itself*), but
    /// on some TVs the Plozzigen engine's HDR/DV output still makes the panel switch
    /// HDMI modes — so the exit veil must cover that switch for *any* engine
    /// playing HDR/DV content. Gating the exit veil on content (not engine)
    /// avoids the flash-on-Home when a Plozzigen-played HDR/DV title is dismissed.
    private(set) var contentDisplayMode: HDRDisplayMode = .sdr

    /// Shared, observable transport state for the custom player overlay. The
    /// view model writes live playback facts here; the input controller writes
    /// scrub state; the SwiftUI overlay reads.
    public let controls = PlayerControlsModel()

    /// Drives Plozz's **owned** subtitle overlay during playback. The view model
    /// parses a selected text sidecar into cues, loads them here, and suppresses
    /// the engine's own subtitle draw — so our renderer (full styling, HDR
    /// luminance, live offset) owns every text-subtitle pixel. Image-based
    /// subtitles still route to the hybrid engine.
    public let liveSubtitles = LiveSubtitleModel()

    /// Invoked when the viewer edits the subtitle **appearance** in the in-player
    /// Style screen, so the host (AppShell) can persist the new look to the
    /// profile's appearance store. Set by whoever constructs the view model;
    /// defaults to a no-op (e.g. previews / tests). See ``applySubtitleStyle(_:)``.
    public var onSubtitleStyleChanged: (SubtitleStyle) -> Void = { _ in }
    /// Fetches + parses the selected sidecar into cues off the main actor; one at
    /// a time, cancelled when the selection changes or playback stops.
    @ObservationIgnored private var subtitleCueLoadTask: Task<Void, Never>?
    /// The equivalent one-at-a-time fetch for the **secondary** (dual) subtitle
    /// sidecar. Separate from the primary task so the two never cancel each other.
    @ObservationIgnored private var secondaryCueLoadTask: Task<Void, Never>?

    private let provider: any MediaProvider
    private let itemID: String
    /// The chosen `MediaVersion.id` (Jellyfin `MediaSourceId` / Plex `Media` id)
    /// to play when the title has multiple versions; `nil` plays the default.
    private let mediaSourceID: String?
    private let behavior: SubtitleBehavior
    private var style: SubtitleStyle
    /// The resolved per-content-type subtitle policy for this profile (design
    /// §5.0/§5.3): base mirrors `behavior`, with optional per-category
    /// overrides ("forced-only on movies, full subs on anime"). Read-only here —
    /// the Settings UI owns edits — and resolved once per playback, so it's a
    /// value, not a live store. Defaults to inheriting the caption settings, so a
    /// profile that set no overrides behaves exactly as before.
    private let subtitlePolicy: SubtitlePolicy
    /// The resolved per-content-type audio-language policy for this profile: base
    /// preference mirrors `playbackSettings.audioLanguagePreference`, with optional
    /// per-category overrides ("original audio for anime, device language for
    /// everything else"). Read-only here — the Settings UI owns edits — and
    /// resolved once per playback. Defaults to inheriting the playback settings, so
    /// a profile that set no overrides behaves exactly as before.
    private let audioPolicy: AudioPolicy
    /// Per-profile playback prefs. Today: whether to offer the Skip Intro/Credits
    /// button. When `skipIntros` is off, segments are never fetched or shown.
    private let playbackSettings: PlaybackSettings
    /// Per-profile spoiler protection, used to mask the Up Next card's thumbnail
    /// and title for an unwatched next episode (the common case). Pure value type.
    private let spoilerSettings: SpoilerSettings
    /// Per-profile remembered per-series audio/subtitle language choices. `nil`
    /// disables the feature (tests, previews). Read at load to steer the initial
    /// tracks and written when the viewer manually switches a track.
    private let seriesTrackStore: (any SeriesTrackPreferenceStoring)?
    /// A stable fallback account id (the profile's primary account) used to scope
    /// per-series memory when the played item carries no `sourceAccountID`. Mirrors
    /// the `liveAccountID` fallback the watch reconciler uses. Without it, two
    /// servers' identically-numbered series (e.g. Plex per-server ratingKeys) would
    /// collapse to one key and bleed remembered tracks across servers within a
    /// profile.
    private let seriesAccountFallbackID: String?
    /// Loads server-detected skip segments once playback is ready; cancelled on
    /// stop. Best-effort — a failure leaves the skip button simply unavailable.
    private var segmentsTask: Task<Void, Never>?
    /// Clears the transient "Skipping…" auto-skip notice after a short delay.
    private var autoSkipNoticeTask: Task<Void, Never>?
    /// Best-effort Trakt scrobbler. Receives the same start/pause/stop lifecycle
    /// as the in-app progress report so watches sync to Trakt. A no-op when Trakt
    /// is unconfigured or disconnected.
    private let scrobbler: any TraktScrobbling
    /// Explicit start position (seconds) that overrides the provider's resume
    /// point when set. `nil` keeps the default behaviour (derive from the
    /// `PlaybackRequest`); `0` forces "start over"; a positive value resumes.
    private let startPositionOverride: TimeInterval?

    /// Builds the engine for a routed ``PlaybackEngineKind``. Injected by the
    /// composition root so this module never depends on the VLCKit engine.
    private let engineFactory: EngineFactory
    /// Device/display/audio policy the router uses to pick an engine.
    private let capabilities: MediaCapabilities

    /// The active engine. A `var` so the cross-engine fallback can swap engines
    /// at runtime (e.g. a failed VLCKit attempt → native, or vice-versa).
    private var engine: any VideoEngine
    /// Which engine ``engine`` currently is, so swaps know the alternate.
    private var currentEngineKind: PlaybackEngineKind = .native
    /// Bumped whenever ``engine`` is swapped, so the SwiftUI player re-hosts the
    /// new engine's bare video surface (`.id(engineToken)`).
    public private(set) var engineToken = UUID()

    /// Bumped the moment a request resolves and the engine is committed (before
    /// the engine's `load()` is even awaited), so the diagnostics overlay can
    /// populate its Engine / Source / codec rows during loading and on failure —
    /// not just once playback reaches `.ready`. Lets the user see *why* a file is
    /// stuck instead of an opaque spinner.
    public private(set) var diagnosticsToken = UUID()

    /// Watches the active engine for stalled start-up: if playback never makes
    /// real progress within a deadline, it converts a silent "loads forever" hang
    /// into an engine failure so the cross-engine / transcode fallback chain runs.
    private var watchdogTask: Task<Void, Never>?

    /// How long the watchdog waits for the first real progress before declaring a
    /// stall. Generous enough for legitimate 4K start-up buffering.
    private let watchdogTimeout: TimeInterval = 30

    private var request: PlaybackRequest?
    private var subtitleDownloadTask: Task<Void, Never>?

    /// Guards the cross-engine swap so it only ever fires once: a chosen engine's
    /// failure swaps to the *other* engine exactly once before escalating.
    private var hasTriedAlternateEngine = false
    /// Guards the automatic transcode fallback so it only ever fires once — a
    /// second failure surfaces the error instead of looping.
    private var hasAttemptedTranscodeFallback = false
    /// Tracks whether the first routed engine has been committed. We avoid
    /// bumping `engineToken` for this first selection to prevent an unnecessary
    /// host re-build during initial SwiftUI bring-up.
    private var hasCommittedInitialEngine = false

    /// Current in-player track-menu selection, so the menu can show a checkmark.
    /// `selectedSubtitleTrackID == nil` represents "Off".
    private var selectedAudioTrackID: Int?
    private var selectedSubtitleTrackID: Int?
    /// The track feeding the overlay's **second** (dual) subtitle line, or `nil`
    /// when off. Independent of the primary: it always renders through Plozz's
    /// overlay (never the engine's own draw), so it must be a text sidecar track.
    private var selectedSecondarySubtitleTrackID: Int?

    /// A just-requested audio track id whose engine switch is still in flight.
    /// AetherEngine reloads to change audio, so `currentAudioTrackID` lags the
    /// pick by a beat; we show the target optimistically until the engine
    /// confirms it, then clear this and let engine truth govern the indicator.
    private var pendingAudioTrackID: Int?

    /// Whether the load-time *default* subtitle has been routed through the
    /// overlay yet for the current `playResolved`. Native tracks are known
    /// synchronously, but Plozzigen demuxes its track list asynchronously (it
    /// arrives via `onTracksChanged` after `playResolved` has returned), so this
    /// guards the auto-selection to run exactly once per load — on whichever of
    /// the two moments has the tracks — without re-applying on every subsequent
    /// `onTracksChanged` or clobbering a manual menu pick made afterwards.
    private var initialSubtitleApplied = false

    /// A provider subtitle track the viewer manually picked that turned out to be
    /// image-based (PGS/DVB/DVD), triggering a native→Plozzigen swap so it can be
    /// decoded and drawn on-device. The provider id-space doesn't line up with
    /// Plozzigen's FFmpeg AVStream ids, so we can't select it until Plozzigen's
    /// track list arrives; this holds the picked track so
    /// `applyInitialSubtitleSelectionIfReady` can attribute-match it to the
    /// equivalent engine track once demux completes, then clears itself.
    private var pendingImageSubtitleMatch: MediaTrack?

    /// True once the viewer manually changed the **audio** track this playback
    /// session. Used by cross-server reconcile to decide whether the stored memory
    /// or this session's audio pick is the newer truth (resolved per dimension so
    /// changing only one track doesn't suppress importing the other).
    private var viewerChangedAudioThisSession = false

    /// True once the viewer manually changed the **subtitle** track this session.
    private var viewerChangedSubtitleThisSession = false

    /// A cross-server-imported audio language awaiting application — set when
    /// reconcile finds a remembered choice from another server but the engine's
    /// audio tracks aren't known yet (Plozzigen pre-demux). Applied on the next
    /// `onTracksChanged`.
    private var crossServerAudioImportLanguage: String?

    /// Content-detected subtitle languages, keyed by track id. Filled
    /// opportunistically when a *text* subtitle with no provider language tag is
    /// parsed for the overlay: `NLLanguageRecognizer` guesses the language from
    /// the cue text so the menu can label an otherwise-anonymous "Track 8" as
    /// e.g. "English (auto)". Bitmap subs (PGS) can't be detected without OCR, so
    /// they stay provider-tagged. Cached so a second selection is instant and the
    /// menu label persists for the session.
    private var detectedSubtitleLanguages: [Int: String] = [:]

    /// Seek-coordinator state. `latestSeekTarget` is the most-recently-requested
    /// committed seek time; `seekTask` is the single in-flight loop that drains
    /// it. Together they guarantee rapid presses ACCUMULATE and resolve to the
    /// final target without overlapping engine seeks racing each other.
    private var latestSeekTarget: TimeInterval?
    private var seekTask: Task<Void, Never>?

    /// Trailing-debounce that coalesces a burst of rapid skip presses into a
    /// single committed seek. Each press updates `latestSeekTarget` + the on-screen
    /// position instantly (in `requestSeek`) but the actual engine seek is deferred
    /// by `seekCommitDebounce`; every fresh press resets the timer, so spamming
    /// back-10s resolves to ONE re-buffer at the final target instead of serially
    /// waiting on each intermediate restart. A single press just pays the tiny
    /// window, which is masked by the instant indicator and dwarfed by the seek's
    /// own re-buffer.
    private var seekCommitTask: Task<Void, Never>?
    private let seekCommitDebounce: UInt64 = 200_000_000 // 200ms

    /// Re-assert-play loop that runs AFTER a committed seek lands. AEEngine /
    /// AVPlayer can settle at rate 0 when a seek resolves on a buffering edge, so
    /// a single `play()` is sometimes swallowed and playback silently never
    /// resumes (the model still reads "playing", so there's no spinner — a
    /// pause→play would start it instantly). This task verifies the clock
    /// actually advances and re-issues `play()` until it does. Superseded by a
    /// new seek and cancelled by a user pause.
    private var resumeConfirmTask: Task<Void, Never>?

    /// The single source of truth for "should the video be playing right now",
    /// driven ONLY by genuine play/pause commands via `setPaused`. Unlike
    /// `engine.isPaused` / `controls.isPaused`, it is never written by the engine
    /// state mirror, so it stays correct even while the engine transiently
    /// settles to rate-0 after a seek. All post-seek resume and transport
    /// decisions key off this, not the (mirror-polluted) paused flags. Defaults
    /// true because load auto-plays.
    private var intendsPlayback = true

    /// Persisted player preferences (e.g. last-used playback speed).
    private let preferencesStore: PlaybackPreferencesStoring

    /// When `true`, the player dismisses itself once playback reaches the natural
    /// end of the stream. Used for trailers, which should close when finished;
    /// regular library playback leaves this `false`.
    private let autoDismissOnEnd: Bool

    /// Episode the player will advance to when this one ends, and the neighbor
    /// behind it — both `nil` for movies/trailers/last episode. Resolved once via
    /// ``neighborResolver`` after load so the controls can offer next/previous
    /// mid-playback and so a clean playthrough auto-advances instead of dismissing.
    public private(set) var nextEpisode: MediaItem?
    public private(set) var previousEpisode: MediaItem?

    /// A resolved, engine-routed playback for the NEXT episode, prefetched during
    /// this episode so the hand-off is near-instant. Handed to the incoming player
    /// via ``consumePrefetchedNext(matching:)``; released on ``stop()`` if the
    /// viewer backs out without advancing (so a Jellyfin session isn't orphaned).
    public private(set) var prefetchedNext: PrefetchedPlayback?

    /// A prefetched playback injected at init by the OUTGOING episode's player, to
    /// be adopted by ``startPlayback`` instead of re-resolving over the network.
    private var adoptedResolved: PrefetchedPlayback?

    /// Resolves the surrounding episodes (previous, next) for the playing item,
    /// off the main actor. `nil` for non-episode playback.
    private let neighborResolver: (@Sendable () async -> (previous: MediaItem?, next: MediaItem?))?

    /// Resolves the playing episode's *series-level* external IDs (off the main
    /// actor) and merges them into the scrobble item so trackers that need the
    /// show's ids — Simkl — can match an episode whose metadata only carries
    /// episode-level ids. `nil` for non-episode playback.
    private let seriesIDResolver: (@Sendable () async -> [String: String]?)?

    /// Set when the player wants to advance to a different episode — either at
    /// natural end (auto-advance) or from a manual next/previous jump. The
    /// ``PlayerPresentation`` observes this and swaps the VM in-place so the
    /// full-screen cover never dismisses (no series-page flash).
    public var pendingNextEpisode: MediaItem?

    /// Durable cross-server convergence hook, called once on `stop()` with the final
    /// position and watched percentage. The AppShell wires this to enqueue a
    /// ``WatchMutation`` so the watch fans out (resume / played+Trakt) to **every**
    /// server holding the title and survives relaunch — independent of the live
    /// per-report path, which only touches the launch server. Defaults to a no-op so
    /// the player is usable standalone / in tests.
    private let onPlaybackStopped: @Sendable (_ position: TimeInterval, _ watchedPercent: Double) -> Void

    /// Called once the live playback session has actually begun (right after the
    /// first `.start` report). The AppShell wires this to register the streaming
    /// server as a live session so the convergence reconciler defers out-of-band
    /// writes against it until playback ends — a mid-play drain can never disturb
    /// the now-playing session. Idempotent on the receiver. Defaults to a no-op.
    private let onPlaybackStarted: @Sendable () -> Void

    /// Periodic mid-playback convergence hook, called roughly every
    /// ``checkpointInterval`` seconds of continuous play with the current position
    /// and watched percentage. The AppShell wires this to enqueue a ``WatchMutation``
    /// into the durable outbox so progress fans out to **other** servers within a
    /// minute *without* the user pressing Back (a "walk away" mid-movie still
    /// converges). The launch server stays deferred by the live-session guard until
    /// `stop()`, so its now-playing session is never disturbed. Enqueue is a local
    /// actor + small disk write — never a network round-trip on this path. Defaults
    /// to a no-op so the player is usable standalone / in tests.
    private let onPlaybackCheckpoint: @Sendable (_ position: TimeInterval, _ watchedPercent: Double) -> Void

    /// How often (seconds) the periodic convergence checkpoint fires during
    /// continuous play. ~60s is the agreed compromise: a casual "walk away"
    /// propagates to other servers within a minute, while servers and their Trakt
    /// plugins aren't spammed. Tunable; `0` (or non-positive) disables the loop.
    private let checkpointInterval: TimeInterval

    /// Drives the periodic checkpoint; cancelled on `stop()`.
    private var checkpointTask: Task<Void, Never>?

    /// The position reported by the last checkpoint, so a stalled/paused player
    /// doesn't re-enqueue the same position and a checkpoint only fires on real
    /// forward progress.
    private var lastCheckpointPosition: TimeInterval = 0

    /// Optional playback bring-up started eagerly in `init` so the (network-bound)
    /// `playbackInfo` resolution and engine warm-up overlap the SwiftUI fullscreen
    /// navigation transition instead of starting only once the view appears. The
    /// view's `load()` adopts (awaits) this task rather than starting a second
    /// bring-up; `stop()` cancels it so a Back during the transition tears down
    /// cleanly via the cancellation checks in `startPlayback`.
    private var prefetchTask: Task<Void, Never>?
    /// Background resolve of the NEXT episode's playback (see ``prefetchedNext``).
    private var nextEpisodePrefetchTask: Task<Void, Never>?
    /// Fires the next-episode prefetch at most once per player.
    private var didStartNextEpisodePrefetch = false
    /// Polls the engine for its first presented frame so the bring-up spinner can
    /// be held until the picture is actually on screen (see ``awaitingFirstFrame``).
    private var firstFrameTask: Task<Void, Never>?
    /// When the current bring-up began, for hand-off latency telemetry
    /// (``HandoffDiagnostics``). `nil` until ``startPlayback`` runs.
    private var bringUpStartedAt: Date?
    /// How long before the end to prefetch the next episode when the provider's
    /// `playbackInfo` is NOT idempotent (Jellyfin) and no closing-credits marker
    /// opened the Up Next window — a safety net for marker-less servers so the
    /// hand-off is still resolved ahead of time without orphaning a session early.
    private static let windowedNextPrefetchLeadTime: TimeInterval = 90
    /// Background series-id enrichment; awaited (briefly) at stop so a fast
    /// finisher still scrobbles with the show's ids resolved.
    private var enrichTask: Task<Void, Never>?

    public init(
        provider: any MediaProvider,
        itemID: String,
        mediaSourceID: String? = nil,
        behavior: SubtitleBehavior = .default,
        style: SubtitleStyle = .default,
        subtitlePolicy: SubtitlePolicy? = nil,
        audioPolicy: AudioPolicy? = nil,
        playbackSettings: PlaybackSettings = .default,
        spoilerSettings: SpoilerSettings = .default,
        seriesTrackStore: (any SeriesTrackPreferenceStoring)? = nil,
        seriesAccountFallbackID: String? = nil,
        startPosition: TimeInterval? = nil,
        scrobbler: any TraktScrobbling = DisabledTraktScrobbler(),
        engineFactory: EngineFactory = .native,
        capabilities: MediaCapabilities = .detected(),
        preferencesStore: PlaybackPreferencesStoring = PlaybackPreferencesStore(),
        autoDismissOnEnd: Bool = false,
        neighborResolver: (@Sendable () async -> (previous: MediaItem?, next: MediaItem?))? = nil,
        seriesIDResolver: (@Sendable () async -> [String: String]?)? = nil,
        onPlaybackStopped: @escaping @Sendable (_ position: TimeInterval, _ watchedPercent: Double) -> Void = { _, _ in },
        onPlaybackStarted: @escaping @Sendable () -> Void = {},
        onPlaybackCheckpoint: @escaping @Sendable (_ position: TimeInterval, _ watchedPercent: Double) -> Void = { _, _ in },
        checkpointInterval: TimeInterval = 60,
        adoptedResolved: PrefetchedPlayback? = nil
    ) {
        self.provider = provider
        self.itemID = itemID
        self.mediaSourceID = mediaSourceID
        self.behavior = behavior
        self.style = style
        self.subtitlePolicy = subtitlePolicy ?? .inheriting(from: behavior)
        self.audioPolicy = audioPolicy ?? .inheriting(from: playbackSettings)
        self.playbackSettings = playbackSettings
        self.spoilerSettings = spoilerSettings
        self.seriesTrackStore = seriesTrackStore
        self.seriesAccountFallbackID = seriesAccountFallbackID
        self.startPositionOverride = startPosition
        self.scrobbler = scrobbler
        self.engineFactory = engineFactory
        self.capabilities = capabilities
        self.preferencesStore = preferencesStore
        self.autoDismissOnEnd = autoDismissOnEnd
        self.neighborResolver = neighborResolver
        self.seriesIDResolver = seriesIDResolver
        self.onPlaybackStopped = onPlaybackStopped
        self.onPlaybackStarted = onPlaybackStarted
        self.onPlaybackCheckpoint = onPlaybackCheckpoint
        self.checkpointInterval = checkpointInterval
        self.adoptedResolved = adoptedResolved
        // Boot directly on the engine the hand-off already resolved, so an adopted
        // prefetch skips the native→Plozzigen swap entirely — no mid-bring-up
        // engine switch, no SDR-drop→DV-resync, one loading indicator. This is the
        // "know the engine before it even starts" path. Falls back to native when
        // there's no adopted decision (fresh launch) or Plozzigen isn't linked.
        if let adopted = adoptedResolved, adopted.engineKind == .plozzigen,
           let makePlozzigen = engineFactory.makePlozzigen, let plozzigen = makePlozzigen() {
            self.engine = plozzigen
            self.currentEngineKind = .plozzigen
            HandoffDiagnostics.emit("engine BOOT plozzigen (adopted; no native→plozzigen swap)")
        } else {
            self.engine = engineFactory.makeNative(style)
            self.currentEngineKind = .native
        }
        PlaybackInstrumentation.increment(.viewModel)
        // Seed last-used speed so a user who set 1.25× on the last show keeps it.
        self.controls.playbackSpeed = preferencesStore.loadPlaybackSpeed()
        self.controls.skipBackwardInterval = playbackSettings.skipBackwardInterval
        self.controls.skipForwardInterval = playbackSettings.skipForwardInterval
        self.controls.seekWithoutPausing = playbackSettings.seekWithoutPausing
        self.controls.upNextLeadSeconds = TimeInterval(playbackSettings.upNextLeadSeconds)
        // Seed the overlay with the profile's persisted subtitle appearance so a
        // selected subtitle renders in the user's style from the first cue.
        self.liveSubtitles.style = style
        // Seed the controls mirror so the in-player appearance editor opens on the
        // viewer's current style rather than the bare default.
        self.controls.subtitleStyle = style
        configureEngineCallbacks()

        // Kick off bring-up now so playbackInfo + engine warm-up run *during* the
        // navigation transition. `load()` (from the view's `.task`) adopts this
        // task; `stop()` cancels it on an early Back.
        prefetchTask = Task { @MainActor [weak self] in
            await self?.startPlayback(forceTranscode: false, resumeOverride: nil)
        }
        // Resolve next/previous episodes in the background so a clean playthrough
        // auto-advances and controls can offer a mid-play jump. Never blocks bring-up.
        if neighborResolver != nil {
            Task { @MainActor [weak self] in await self?.resolveNeighbors() }
        }
    }

    deinit {
        PlaybackInstrumentation.decrement(.viewModel)
    }

    private func configureEngineCallbacks() {
        engine.onProgress = { [weak self] in
            guard let self else { return }
            // Jellyfin (non-idempotent) next-episode prefetch fires once the
            // hand-off window opens; idempotent providers prefetch eagerly instead.
            self.maybeStartWindowedNextPrefetch()
            self.logUpNextStateIfNearEnd()
            Task { await self.report(event: .progress, isPaused: false) }
        }
        engine.onFailure = { [weak self] error in
            guard let self else { return }
            Task { await self.handleEngineFailure(error) }
        }
        engine.onEnded = { [weak self] in
            self?.handlePlaybackEnded()
        }
        // Engines that discover tracks asynchronously (Plozzigen) tell us to
        // rebuild the options menu once their lists arrive — otherwise the menu,
        // built once at playResolved, stays empty for the whole session. This is
        // also the moment Plozzigen's tracks first become known, so it's where we
        // route its load-time default subtitle through the overlay.
        engine.onTracksChanged = { [weak self] in
            guard let self else { return }
            self.loadTrackOptions()
            self.applyImportedAudioIfPossible()
            if let request = self.request {
                self.applyInitialSubtitleSelectionIfReady(for: request)
            }
        }
        // Engines that decode subtitles themselves (Plozzigen) push their active
        // cues here; the live overlay model draws them on the same SDR renderer as
        // native. Guarded by live-feed mode inside the model, so it's inert unless
        // a Plozzigen subtitle is actually selected.
        engine.onSubtitleCues = { [weak self] cues in
            guard let self else { return }
            self.liveSubtitles.updateLiveCues(cues)
            #if DEBUG
            if self.selectedSubtitleTrackID != nil {
                self.setPrimarySubtitleDiagnostic(route: "live-feed", cues: cues.count)
            }
            #endif
        }
        // Same as above but for the engine's SECONDARY (dual) subtitle stream. This
        // is the dual-subtitle path for embedded tracks that have no fetchable
        // sidecar URL (e.g. Plex direct-play MKV): AetherEngine/Plozzigen decodes
        // the second track itself and pushes its cues here. Inert unless
        // `beginSecondaryLiveFeed()` has been called (guarded inside the model).
        engine.onSecondarySubtitleCues = { [weak self] cues in
            guard let self else { return }
            self.liveSubtitles.updateSecondaryLiveCues(cues)
            if self.selectedSecondarySubtitleTrackID != nil {
                self.controls.secondarySubtitleStatus = .loaded(cueCount: cues.count)
            }
        }
    }

    /// Called when the active engine reports a clean playthrough to the end of the
    /// stream. Auto-advances to the next episode when one is queued, otherwise
    /// dismisses so the player never freezes on the final frame: trailers/movies
    /// return to detail, a season finale returns to the series page.
    private func handlePlaybackEnded() {
        PlaybackTrace.note("handlePlaybackEnded curr=\(String(format: "%.2f", engine.currentTime)) furthest=\(String(format: "%.2f", engine.furthestObservedPosition)) dur=\(String(format: "%.2f", engine.duration)) hasNext=\(nextEpisode != nil) isSeeking=\(controls.isSeeking) isScrubbing=\(controls.isScrubbing) intendsPlayback=\(intendsPlayback)")
        if let next = nextEpisode {
            pendingNextEpisode = next
        } else {
            shouldDismiss = true
        }
    }

    /// Requests a swap to another episode mid-playback (or at end). The
    /// ``PlayerPresentation`` observes ``pendingNextEpisode`` and handles the
    /// actual VM swap so the full-screen cover stays up.
    public func playEpisode(_ episode: MediaItem) {
        pendingNextEpisode = episode
    }

    /// Loads the surrounding episodes so controls can offer next/previous and a
    /// clean end auto-advances. Best-effort; silent on failure.
    private func resolveNeighbors() async {
        guard let neighborResolver else { return }
        let (prev, next) = await neighborResolver()
        previousEpisode = prev
        nextEpisode = next
        controls.hasPreviousEpisode = prev != nil
        controls.hasNextEpisode = next != nil
        updateUpNextCard()
        // Eagerly prefetch the next episode's resolved stream when the provider's
        // `playbackInfo` is idempotent (Plex, SMB share) — safe to resolve the
        // moment it's known, for a near-instant hand-off. Jellyfin (a
        // session-minting POST) defers to the hand-off window instead; see
        // ``maybeStartWindowedNextPrefetch``.
        if next != nil, provider.kind.playbackInfoIsIdempotent {
            startNextEpisodePrefetch(trigger: "eager")
        }
    }

    // MARK: - Next-episode prefetch (fast hand-off)

    /// Resolves the NEXT episode's stream + engine ahead of the hand-off and
    /// caches it in ``prefetchedNext``. Fires at most once. Best-effort: a failure
    /// just means the hand-off resolves normally (no regression). The eager path
    /// (idempotent providers) calls this from ``resolveNeighbors``; the windowed
    /// path (Jellyfin) calls it from ``maybeStartWindowedNextPrefetch``.
    private func startNextEpisodePrefetch(trigger: String) {
        guard let next = nextEpisode, !didStartNextEpisodePrefetch, prefetchedNext == nil,
              nextEpisodePrefetchTask == nil else { return }
        didStartNextEpisodePrefetch = true
        HandoffDiagnostics.emit("prefetch START trigger=\(trigger) next=\(next.id) provider=\(provider.kind.rawValue) idempotent=\(provider.kind.playbackInfoIsIdempotent)")
        let prefetchStart = Date()
        nextEpisodePrefetchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let resolved = try await self.resolveAndRoute(
                    itemID: next.id, mediaSourceID: next.selectedVersionID, forceTranscode: false)
                // A stop()/back-out cancelled us after the resolve opened a
                // (Jellyfin) session — release it rather than orphan it.
                if Task.isCancelled {
                    await self.releasePrefetchedSession(resolved.request)
                    self.nextEpisodePrefetchTask = nil
                    return
                }
                self.prefetchedNext = resolved
                HandoffDiagnostics.emit("prefetch READY next=\(next.id) engine=\(resolved.engineKind.rawValue) took=\(HandoffDiagnostics.ms(prefetchStart))")
                PlozzLog.playback.info("Prefetched next-episode playback (engine=\(resolved.engineKind.rawValue))")
            } catch is CancellationError {
                // Nothing resolved yet — nothing to release.
            } catch {
                // One-shot: a failed prefetch does NOT re-arm. Re-arming would let
                // maybeStartWindowedNextPrefetch re-POST every progress tick and
                // orphan a Jellyfin session that was minted just before the
                // failure. The hand-off then resolves normally (no regression).
                HandoffDiagnostics.emit("prefetch FAILED next=\(next.id) took=\(HandoffDiagnostics.ms(prefetchStart)) (hand-off will resolve normally)")
                PlozzLog.playback.debug("Next-episode prefetch failed (non-fatal)")
            }
            self.nextEpisodePrefetchTask = nil
        }
    }

    /// Starts the next-episode prefetch for a NON-idempotent provider (Jellyfin)
    /// once the hand-off window has opened — the closing-credits marker (Up Next
    /// active) or, as a fallback for marker-less servers, the last
    /// ``windowedNextPrefetchLeadTime`` seconds. Keeps the minted session fresh.
    /// Called on the progress cadence. Idempotent providers use the eager path.
    private func maybeStartWindowedNextPrefetch() {
        guard nextEpisode != nil, prefetchedNext == nil, !didStartNextEpisodePrefetch,
              nextEpisodePrefetchTask == nil else { return }
        guard !provider.kind.playbackInfoIsIdempotent else { return }
        let duration = engine.duration
        let remaining = duration - engine.currentTime
        let windowOpen = controls.upNextActive
            || (duration > 0 && remaining > 0 && remaining <= Self.windowedNextPrefetchLeadTime)
        guard windowOpen else { return }
        startNextEpisodePrefetch(trigger: "windowed")
    }

    /// Emits the Up Next card decision state on the progress cadence when we're
    /// near the end (or the duration is unknown, which itself blocks the
    /// time-based card). Diagnostic only (gated + throttled) — pinpoints why the
    /// card does/doesn't appear on device (e.g. an SMB stream with duration 0).
    private var lastUpNextDiagAt = Date.distantPast
    private func logUpNextStateIfNearEnd() {
        guard HandoffDiagnostics.isEnabled, nextEpisode != nil else { return }
        let cDur = controls.duration
        let cCur = controls.currentSeconds
        let remaining = cDur - cCur
        let durUnknown = !(cDur.isFinite && cDur > 0)
        guard durUnknown || (remaining > 0 && remaining <= 60) else { return }
        guard Date().timeIntervalSince(lastUpNextDiagAt) >= 8 else { return }
        lastUpNextDiagAt = Date()
        let creditsStart = controls.skippableSegments.first { $0.kind == .credits }?.start
        HandoffDiagnostics.emit("upnext-state cDur=\(Int(cDur)) cCur=\(Int(cCur)) eDur=\(Int(engine.duration)) remaining=\(Int(remaining)) creditsStart=\(creditsStart.map { Int($0) }.map(String.init) ?? "none") card=\(controls.upNext != nil) show=\(playbackSettings.showUpNextCard) marker=\(controls.hasCreditsMarker) nearEndByTime=\(controls.isNearEndByTime) active=\(controls.upNextActive) presenting=\(controls.isPresentingUpNext) lead=\(Int(controls.upNextLeadSeconds))")
    }

    /// Hands the prefetched next-episode resolution to the incoming player and
    /// clears it locally so ``stop()`` won't release the session being adopted.
    /// Returns `nil` when there's no prefetch or it doesn't match `itemID` (the
    /// hand-off then resolves normally). Call this synchronously BEFORE `stop()`.
    public func consumePrefetchedNext(matching itemID: String) -> PrefetchedPlayback? {
        guard let prefetched = prefetchedNext, prefetched.itemID == itemID else {
            HandoffDiagnostics.emit("handoff advance next=\(itemID) prefetch=MISS (not ready — incoming player will resolve)")
            return nil
        }
        HandoffDiagnostics.emit("handoff advance next=\(itemID) prefetch=HIT engine=\(prefetched.engineKind.rawValue)")
        prefetchedNext = nil
        // The producing task already completed; drop the handle so stop()'s
        // cancel-and-release can't touch the session the incoming player now owns.
        nextEpisodePrefetchTask = nil
        return prefetched
    }

    /// Whether the panel's HDR/Dolby-Vision mode should be kept across this
    /// hand-off — i.e. stop the outgoing engine WITHOUT resetting the display, so
    /// the TV doesn't flap DV→SDR→DV between episodes. True only when both this
    /// and the next episode play on the on-device engine in the SAME HDR/DV mode:
    /// the incoming engine then re-applies identical criteria, so tvOS re-syncs
    /// nothing. Any mismatch (different range, SDR, or a native-engine side) keeps
    /// the normal full reset so a genuine mode change still happens.
    public func shouldPreserveDisplayMode(forNext next: PrefetchedPlayback?) -> Bool {
        let curMode = contentDisplayMode
        let nextMode = next.map { HDRDisplayMode($0.request.sourceMetadata) }
        let bothPlozzigen = currentEngineKind == .plozzigen && next?.engineKind == .plozzigen
        let preserve = bothPlozzigen && (nextMode?.isHDR ?? false) && nextMode == curMode
        HandoffDiagnostics.emit("handoff display cur=\(curMode) next=\(nextMode.map { "\($0)" } ?? "none") bothPlozzigen=\(bothPlozzigen) preserve=\(preserve)")
        return preserve
    }

    /// Releases a prefetched-but-unadopted server session so a back-out doesn't
    /// orphan a Jellyfin play/transcode session. A no-op for idempotent providers
    /// (Plex/SMB create no server-side state). Best-effort.
    private func releasePrefetchedSession(_ request: PlaybackRequest) async {
        guard !provider.kind.playbackInfoIsIdempotent else { return }
        guard let sessionID = request.playSessionID, !sessionID.isEmpty else { return }
        let progress = PlaybackProgress(
            itemID: request.item.id, playSessionID: sessionID, positionSeconds: 0, isPaused: true)
        try? await provider.reportPlayback(progress, event: .stop)
        PlozzLog.playback.info("Released orphaned prefetched next-episode session")
    }

    // MARK: - First-frame gate (single bring-up spinner)

    /// Holds the bring-up spinner (``showBringUpSpinner``) until the engine is
    /// genuinely presenting moving frames, so tap → first frame shows ONE
    /// continuous indicator. Called from ``playResolved`` after `engine.load()`.
    /// If the engine is already presenting (e.g. a mid-play cross-engine swap),
    /// clears immediately.
    private func beginAwaitingFirstFrame() {
        firstFrameTask?.cancel()
        if engine.preventsDisplaySleep {
            awaitingFirstFrame = false
            if let start = bringUpStartedAt {
                HandoffDiagnostics.emit("first-frame (already presenting) total=\(HandoffDiagnostics.ms(start)) engine=\(currentEngineKind.rawValue)")
            }
            return
        }
        awaitingFirstFrame = true
        firstFrameTask = Task { @MainActor [weak self] in
            // Poll the engine's "frames genuinely advancing" signal
            // (`preventsDisplaySleep`: native `timeControlStatus == .playing`,
            // Plozzigen `state == .playing`) — finer than the ~report-cadence
            // `onProgress`, so the spinner drops the instant the picture is up.
            // A true hang is handled by the existing playback watchdog, not here.
            while !Task.isCancelled {
                guard let self, self.awaitingFirstFrame else { return }
                if self.engine.preventsDisplaySleep {
                    self.awaitingFirstFrame = false
                    if let start = self.bringUpStartedAt {
                        HandoffDiagnostics.emit("first-frame PRESENTED total=\(HandoffDiagnostics.ms(start)) engine=\(self.currentEngineKind.rawValue)")
                    }
                    return
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    /// Tears down the first-frame gate on any terminal path (stop / failure) so
    /// the poll never lingers and the spinner never sticks.
    private func clearFirstFrameWait() {
        firstFrameTask?.cancel()
        firstFrameTask = nil
        awaitingFirstFrame = false
    }

    /// Builds the spoiler-aware Up Next presentation for the resolved next episode
    /// and publishes it to the controls model — or clears it when there's no next
    /// episode or the card is disabled. The container only ever shows the card
    /// during the closing-credits window (see ``PlayerControlsModel/upNextActive``).
    private func updateUpNextCard() {
        guard playbackSettings.showUpNextCard, let next = nextEpisode else {
            controls.upNext = nil
            return
        }
        let hideThumb = spoilerSettings.shouldHideThumbnail(for: next)
        let hideText = spoilerSettings.shouldHideText(for: next)

        // The show/series name leads the card — never a spoiler (you're watching
        // it) and reliably readable. Fall back to the (spoiler-aware) episode title
        // only when the series title is unknown.
        let showName = next.parentTitle
            ?? (hideText ? spoilerSettings.maskedTitle(for: next) : next.title)
        let metaLine = Self.upNextMeta(for: next)

        // Placeholder mode never loads the real still: fall back to spoiler-safe
        // series art. Blur mode shows the real still but blurred. When not hidden,
        // use the episode's own backdrop (16:9 still), then its safe fallbacks.
        let thumbnailURLs: [URL]
        let blur: Bool
        if hideThumb, spoilerSettings.mode == .placeholder {
            thumbnailURLs = [next.fallbackArtworkURL, next.seriesPosterURL].compactMap { $0 }
            blur = false
        } else {
            thumbnailURLs = [next.backdropURL, next.fallbackArtworkURL].compactMap { $0 }
            blur = hideThumb // blur mode (the only remaining hidden case)
        }

        controls.upNext = UpNextInfo(
            episode: next,
            showName: showName,
            metaLine: metaLine,
            thumbnailURLs: thumbnailURLs,
            blurThumbnail: blur
        )
    }

    /// The Up Next card's secondary line, e.g. "S2 · E3 · 48m" — season/episode
    /// plus runtime. Season/episode numbers and runtime are never spoilers, so
    /// this is always shown even under a masked thumbnail.
    private static func upNextMeta(for item: MediaItem) -> String? {
        var parts: [String] = []
        if let season = item.seasonNumber, let episode = item.episodeNumber {
            parts.append("S\(season) · E\(episode)")
        } else if let episode = item.episodeNumber {
            parts.append("Episode \(episode)")
        }
        if let runtime = item.runtime, runtime > 0 {
            parts.append(Self.upNextRuntimeLabel(runtime))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Compact runtime label for the Up Next meta line, e.g. `48m` or `1h 2m`.
    private static func upNextRuntimeLabel(_ seconds: TimeInterval) -> String {
        let totalMinutes = max(0, Int(seconds / 60))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        return "\(minutes)m"
    }

    /// Advances to the resolved next episode (Up Next card Play / auto-advance).
    /// Routes through ``playEpisode`` so the full-screen cover stays up (no flash).
    public func playNextEpisode() {
        guard let next = nextEpisode else { return }
        playEpisode(next)
    }

    /// Dismisses the Up Next card for the current episode without advancing
    /// (card Menu / swipe-up), so it won't keep grabbing focus during credits.
    public func dismissUpNextCard() {
        controls.dismissedUpNext = true
    }

    /// Fetches the playing episode's series-level ids and folds them into the
    /// item's `providerIDs` under the `Series*` namespace, so scrobblers that
    /// need the show's id (Simkl) can match an episode that only carried
    /// episode-level ids. Best-effort: a miss leaves scrobble behavior unchanged.
    private func enrichSeriesIDs() async {
        if let seriesIDResolver, var current = request,
           let raw = await seriesIDResolver(), !raw.isEmpty {
            let map: [(ProviderIDNamespace, String)] = [
                (.imdb, "SeriesImdb"), (.tmdb, "SeriesTmdb"), (.tvdb, "SeriesTvdb"),
                (.myAnimeList, "SeriesMal"), (.aniList, "SeriesAniList"),
                (.aniDB, "SeriesAniDB")
            ]
            var merged = current.item.providerIDs
            for (namespace, key) in map {
                guard let value = raw.providerID(namespace) else { continue }
                if merged[key] == nil { merged[key] = value }
            }
            current.item.providerIDs = merged
            request = current
        }
        // Now that the series' cross-server ids are resolved (or were already
        // present), reconcile per-series memory so a choice made on another
        // server transfers to this episode.
        reconcileSeriesMemoryAcrossServers()
    }

    // MARK: - Engine selection / swapping

    /// Instantiates the engine for `kind`, falling back to native if the
    /// Plozzigen engine was requested but isn't wired in (defensive — the router
    /// never asks for on-device decode unless it's available).
    private func makeEngine(_ kind: PlaybackEngineKind) -> any VideoEngine {
        switch kind {
        case .hybrid, .plozzigen:
            // Plozzigen is the sole on-device decode engine. `.hybrid` is the
            // router's abstract "needs on-device decode" signal; it resolves here
            // to Plozzigen (the former backing engine is retired).
            if let makePlozzigen = engineFactory.makePlozzigen, let engine = makePlozzigen() {
                return engine
            }
            return engineFactory.makeNative(style)
        case .native:
            return engineFactory.makeNative(style)
        }
    }

    /// Swaps the active engine when the routed kind differs from the current one,
    /// tearing the old engine down and re-pointing the UI at the new surface.
    private func switchEngine(to kind: PlaybackEngineKind) {
        guard kind != currentEngineKind else {
            return
        }
        engine.stop()
        engine = makeEngine(kind)
        currentEngineKind = kind
        configureEngineCallbacks()
        engineToken = UUID()
    }

    /// Commits the first routed engine without forcing a host `.id` rebuild.
    /// Subsequent swaps use the normal token-bumping `switchEngine` path.
    private func commitEngineForPlayback(_ kind: PlaybackEngineKind) {
        guard hasCommittedInitialEngine else {
            hasCommittedInitialEngine = true
            guard kind != currentEngineKind else {
                return
            }
            engine.stop()
            engine = makeEngine(kind)
            currentEngineKind = kind
            configureEngineCallbacks()
            return
        }
        switchEngine(to: kind)
    }

    /// The engine to try when the current one fails: the opposite engine, but
    /// only if it's actually available (no Plozzigen → nothing to swap to).
    private var alternateEngineKind: PlaybackEngineKind? {
        switch currentEngineKind {
        case .native:
            // AVPlayer failed (e.g. the runtime `hev1` black-screen catch). Try
            // Plozzigen (AetherEngine): it fetches the source itself and remuxes
            // on-device. If it isn't wired in, there's nothing to swap to → fall
            // through to the server-transcode safety net.
            return engineFactory.plozzigenAvailable ? .plozzigen : nil
        case .hybrid, .plozzigen:
            // On-device decode failed — fall back to native (server-transcode
            // safety net). (`.hybrid` is a legacy routing value; treated as
            // Plozzigen, which is what it resolves to.)
            return .native
        }
    }

    /// Yields one main-runloop turn so SwiftUI can reconcile engine-swap state
    /// (including the loading-phase video surface host) before `engine.load()`.
    private static func yieldToRunLoop() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    /// Loads stream info, configures the player, and seeks to resume.
    public func load() async {
        // Adopt the eager bring-up started in `init` (so we never resolve/bring up
        // twice). If it already ran (or was cancelled), fall through to a normal
        // load on a later, explicit call.
        if let task = prefetchTask {
            prefetchTask = nil
            await task.value
            return
        }
        await startPlayback(forceTranscode: false, resumeOverride: nil)
    }

    /// Resolves a stream and brings up the player. `forceTranscode` asks the
    /// provider to bypass direct play (used by the automatic fallback); when set,
    /// `resumeOverride` carries the position the failed attempt reached so the
    /// retry resumes there instead of the provider's stale resume point.
    private func startPlayback(forceTranscode: Bool, resumeOverride: TimeInterval?) async {
        phase = .loading
        let bringUpStart = Date()
        bringUpStartedAt = bringUpStart
        do {
            let resolved: PrefetchedPlayback
            if !forceTranscode, let adopted = adoptedResolved, adopted.itemID == itemID {
                // Adopt the request the previous episode prefetched for us. Skips
                // the network `playbackInfo` resolve entirely (near-instant
                // hand-off) and REUSES its already-open session (Jellyfin) so
                // exactly one server session ever exists. The engine is already
                // routed, so it commits correctly on the first commit — no
                // native→Plozzigen swap, one continuous loading spinner.
                adoptedResolved = nil
                resolved = adopted
                HandoffDiagnostics.emit("bringup ADOPTED prefetch item=\(itemID) engine=\(resolved.engineKind.rawValue) (skipped network resolve)")
                PlozzLog.playback.info("Adopted prefetched playback; skipping playbackInfo resolve")
            } else {
                let resolveStart = Date()
                resolved = try await resolveAndRoute(
                    itemID: itemID, mediaSourceID: mediaSourceID, forceTranscode: forceTranscode)
                HandoffDiagnostics.emit("bringup RESOLVED on-demand item=\(itemID) engine=\(resolved.engineKind.rawValue) playbackInfo=\(HandoffDiagnostics.ms(resolveStart)) provider=\(provider.kind.rawValue) transcode=\(forceTranscode)")
            }
            // A user-initiated Back during playbackInfo resolution should NOT
            // proceed to bring up an engine that will immediately be torn down —
            // short-circuit cleanly without going through the failure path.
            try Task.checkCancellation()

            let request = resolved.request
            self.request = request
            configureControls(for: request)

            // Enrich the episode with its series-level ids in the background so the
            // first scrobble can identify the show on trackers that require it, then
            // reconcile cross-server per-series memory. Runs for any episode: even
            // without a resolver the item may already carry series ids to reconcile.
            if request.item.kind == .episode {
                enrichTask = Task { @MainActor [weak self] in await self?.enrichSeriesIDs() }
            }

            // An explicit override wins over the provider's resume point so the
            // caller can force "start over" (0) or resume from a chosen second.
            // Apply the profile's "resume rewind" nudge so returning to a
            // partially-watched title starts a few seconds earlier — but only for
            // a genuine resume (base > 0; "start over" stays 0) and never on the
            // engine/transcode fallback retry (`resumeOverride`), which must land
            // exactly where the failed attempt was so the nudge can't compound
            // across retries.
            let startPosition: TimeInterval
            if let resumeOverride {
                startPosition = resumeOverride
            } else {
                let base = startPositionOverride ?? request.startPosition
                startPosition = playbackSettings.resumeRewindInterval.applied(to: base)
            }

            try Task.checkCancellation()
            await playResolved(request, engineKind: resolved.engineKind, startPosition: startPosition)

            // Best-effort, never blocking play(): (if enabled) fetch a missing
            // subtitle in the preferred language.
            startAutoSubtitleDownloadIfNeeded(request: request)
        } catch is CancellationError {
            // Leave `phase` as `.loading`; the view is dismissing.
            return
        } catch let error as AppError {
            clearFirstFrameWait()
            phase = .failed(error)
        } catch {
            clearFirstFrameWait()
            phase = .failed(.unknown(""))
        }
    }

    /// Resolves a stream via the provider and picks its engine — the pure,
    /// network half of bring-up, with NO engine mutation or side effects on
    /// `self`. Shared by the current-item load (``startPlayback``) and the
    /// next-episode prefetch (``startNextEpisodePrefetch``) so both route
    /// identically. The returned ``PrefetchedPlayback`` carries everything the
    /// engine commit needs, so a prefetched result can be adopted verbatim.
    private func resolveAndRoute(
        itemID: String,
        mediaSourceID: String?,
        forceTranscode: Bool
    ) async throws -> PrefetchedPlayback {
        var request = try await provider.playbackInfo(
            for: itemID, mediaSourceID: mediaSourceID, forceTranscode: forceTranscode)
        // Steer the engine's INITIAL active audio track by language (no reload)
        // from the prefer-original-language policy. Computed here so every
        // playResolved entry (initial, adopted prefetch, and cross-engine
        // fallback, which reuse self.request) inherits it. Subtitle language
        // steering is intentionally left empty — Plozz owns subtitle selection
        // via the SDR overlay, so the engine must not activate its own track.
        request.preferredAudioLanguages = preferredAudioLanguages(for: request.item)
        let kind = routeEngine(for: request, forceTranscode: forceTranscode)
        return PrefetchedPlayback(itemID: itemID, request: request, engineKind: kind)
    }

    /// Picks the engine for a resolved request — the pure routing decision, no
    /// engine mutation or network. Extracted so the current-item load and the
    /// next-episode prefetch pick the engine the same way.
    private func routeEngine(for request: PlaybackRequest, forceTranscode: Bool) -> PlaybackEngineKind {
        var kind: PlaybackEngineKind
        if !forceTranscode, engineFactory.plozzigenAvailable,
                  let descriptor = request.localRemuxSource,
                  case .eligible = descriptor.plozzigenEligibility {
            // Plozzigen handles the full pipeline: FFmpeg demux → HLS-fMP4 →
            // localhost → AVPlayer. Covers HEVC/H.264/VP9/AV1 video with any
            // audio (stream-copy or lossless bridge). The engine reads
            // localRemuxSource.originalURL directly.
            kind = .plozzigen
        } else {
            kind = EngineRouter.selectEngine(
                source: request.sourceMetadata,
                capabilities: capabilities,
                isTranscoding: request.isTranscoding,
                // Plozzigen is the on-device decode engine, so "hybrid available"
                // (needs-on-device-decode is routable) == Plozzigen available.
                // When it isn't wired in, the router stays native.
                hybridAvailable: engineFactory.plozzigenAvailable
            )
            // The router's `.hybrid` return is its abstract "needs on-device
            // decode" signal; Plozzigen (AetherEngine) is that engine. Resolve
            // `.hybrid` to it. (The former backing engine is retired.)
            if kind == .hybrid, engineFactory.plozzigenAvailable {
                kind = .plozzigen
            }
        }

        // If the subtitle that would be shown by default is image-based
        // (PGS/DVB/DVD/VOBSUB), AVPlayer can't render it — route to Plozzigen,
        // which decodes bitmap subtitle packets into image cues that Plozz's
        // overlay draws (no server burn-in). Only when direct-playing and
        // Plozzigen is wired in; a no-op when already routed to Plozzigen.
        let subtitleRule = effectiveSubtitleRule(for: request.item)
        if kind == .native, !request.isTranscoding, engineFactory.plozzigenAvailable,
           request.subtitleTracks.defaultSubtitleNeedsHybridEngine(
               mode: subtitleRule.mode,
               preferredLanguage: subtitleRule.preferredLanguage) {
            PlozzLog.playback.info("Default subtitle is image-based; routing to Plozzigen so it can be rendered on-device")
            kind = .plozzigen
        }

        // A raw SMB share stream can ONLY be opened by the on-device engine —
        // AVPlayer/AVFoundation cannot demux or even open an `smb://` URL. Force
        // Plozzigen for any smb:// source regardless of container/codec facts
        // (which a share provider doesn't report).
        let resolvedURL = request.localRemuxSource?.originalURL ?? request.streamURL
        if kind != .plozzigen, engineFactory.plozzigenAvailable,
           resolvedURL.scheme?.lowercased() == "smb" {
            PlozzLog.playback.info("SMB share source; routing to Plozzigen (AVPlayer can't open smb://)")
            kind = .plozzigen
        }
        return kind
    }

    /// Resolves the ordered audio-language preference for a load from per-series
    /// memory (when enabled) and the per-content-type audio policy. A remembered
    /// per-series language takes precedence ahead of the policy preference.
    private func preferredAudioLanguages(for item: MediaItem) -> [String] {
        AudioLanguagePolicy.preferredAudioLanguages(
            remembered: rememberedAudioLanguage(for: item),
            preference: effectiveAudioPreference(for: item),
            originalLanguage: ContentClassifier.originalAudioLanguage(for: item),
            deviceLanguage: LanguageMatch.deviceLanguageCode
        )
    }

    /// The audio-language preference that applies to `item`: the profile's
    /// per-content-type override for the item's category if set, else the profile
    /// base preference.
    private func effectiveAudioPreference(for item: MediaItem) -> AudioLanguagePreference {
        audioPolicy.effectivePreference(for: ContentClassifier.audioCategory(for: item))
    }

    /// The subtitle rule that applies to `item` (design §5.0): the profile's
    /// per-content-type override for the item's category if set, else the profile
    /// base. Feeds the on-load default selection, the image-sub engine-routing
    /// prediction, and the auto-download decision so all three agree.
    private func effectiveSubtitleRule(for item: MediaItem) -> SubtitlePolicy.Rule {
        subtitlePolicy.effectiveRule(for: ContentClassifier.subtitleCategory(for: item))
    }

    // MARK: - Per-series remembered track selections

    /// The per-server fallback key for an item, or `nil` when the item isn't an
    /// episode of a series (movies/trailers use the default policy) — used only
    /// when no cross-server identity is available.
    private func seriesLocalKey(for item: MediaItem) -> String? {
        guard item.kind == .episode, let seriesID = item.seriesID else { return nil }
        return SeriesTrackPreferenceKey.make(
            sourceAccountID: item.sourceAccountID ?? seriesAccountFallbackID,
            seriesID: seriesID
        )
    }

    /// Cross-server show identity keys for an item (episodes only). May be empty
    /// at first load and become non-empty once `enrichSeriesIDs` folds the
    /// series-level external ids onto the item.
    private func seriesCrossServerKeys(for item: MediaItem) -> [String] {
        guard item.kind == .episode else { return [] }
        return SeriesTrackPreferenceKey.crossServerKeys(providerIDs: item.providerIDs)
    }

    /// Ordered keys to read/write remembered preferences: cross-server identity
    /// first (so a choice transfers between servers) then the per-server fallback.
    private func seriesPreferenceKeys(for item: MediaItem) -> [String] {
        seriesCrossServerKeys(for: item) + [seriesLocalKey(for: item)].compactMap { $0 }
    }

    /// First remembered audio language across `keys`, in order. Resolved per
    /// field (not per stored object): a show whose external-id coverage differs
    /// across servers can hold audio under one cross-server key and subtitle under
    /// another, so we must scan every key for the field rather than return the
    /// first non-empty object wholesale.
    private func firstSeriesAudioLanguage(_ keys: [String]) -> String? {
        guard let store = seriesTrackStore else { return nil }
        for key in keys {
            if let language = store.preference(forKey: key)?.audioLanguage { return language }
        }
        return nil
    }

    /// First remembered subtitle decision across `keys`, in order. Resolved per
    /// field for the same reason as ``firstSeriesAudioLanguage``.
    private func firstSeriesSubtitle(_ keys: [String]) -> RememberedSubtitleSelection? {
        guard let store = seriesTrackStore else { return nil }
        for key in keys {
            if let subtitle = store.preference(forKey: key)?.subtitle { return subtitle }
        }
        return nil
    }

    /// The remembered audio language for this item's series, gated on the toggle.
    private func rememberedAudioLanguage(for item: MediaItem) -> String? {
        guard playbackSettings.rememberAudioTrackPerSeries else { return nil }
        return firstSeriesAudioLanguage(seriesPreferenceKeys(for: item))
    }

    /// The remembered subtitle decision for this item's series, gated on the toggle.
    private func rememberedSubtitle(for item: MediaItem) -> RememberedSubtitleSelection? {
        guard playbackSettings.rememberSubtitleTrackPerSeries else { return nil }
        return firstSeriesSubtitle(seriesPreferenceKeys(for: item))
    }

    /// Records the viewer's manual audio-language pick for the current series
    /// (gated on the toggle), fanned out to every key (cross-server + per-server)
    /// so the choice follows the show to any server. Only a language-tagged track
    /// is remembered — an untagged track can't be re-resolved on the next episode.
    /// The language is normalized (`eng` → `en`) so a code that differs in form
    /// between servers still matches.
    private func recordSeriesAudioSelection(language: String?) {
        guard playbackSettings.rememberAudioTrackPerSeries,
              let store = seriesTrackStore,
              let item = request?.item,
              let language, !language.isEmpty else { return }
        let normalized = LanguageMatch.normalized(language) ?? language
        for key in seriesPreferenceKeys(for: item) {
            store.setAudioLanguage(normalized, forKey: key)
        }
    }

    /// Records the viewer's manual subtitle pick (a language, or Off) for the
    /// current series, gated on the toggle and fanned out to every key. A selected
    /// track with no language is not remembered (it can't be re-matched next
    /// episode); Off always is. A language is normalized so it matches cross-server.
    private func recordSeriesSubtitleSelection(_ selection: RememberedSubtitleSelection?) {
        guard playbackSettings.rememberSubtitleTrackPerSeries,
              let store = seriesTrackStore,
              let item = request?.item,
              let selection else { return }
        let normalized: RememberedSubtitleSelection
        switch selection {
        case .off:
            normalized = .off
        case .language(let code):
            normalized = .language(LanguageMatch.normalized(code) ?? code)
        }
        for key in seriesPreferenceKeys(for: item) {
            store.setSubtitle(normalized, forKey: key)
        }
    }

    /// Reconciles per-series memory across servers once `enrichSeriesIDs` has
    /// folded the series' external ids onto the item (making the cross-server keys
    /// resolvable). Audio and subtitle are reconciled **independently** — the
    /// viewer may have changed only one this session, and the two fields can live
    /// under different keys when servers expose different external-id subsets:
    /// - **Viewer changed this dimension this session** → their pick is the newest
    ///   truth; mirror it onto every key (a switch made before enrich resolved the
    ///   cross-server keys would have written only the per-server key).
    /// - **Otherwise** → if a cross-server key carries a value that differs from
    ///   the per-server key (the show was watched on another server, possibly more
    ///   recently), import it: apply it to this playback and backfill the
    ///   per-server key so later same-server episodes resolve it synchronously.
    private func reconcileSeriesMemoryAcrossServers() {
        guard let store = seriesTrackStore,
              let item = request?.item,
              item.kind == .episode else { return }
        let crossKeys = seriesCrossServerKeys(for: item)
        guard !crossKeys.isEmpty else { return }
        let localKeys = [seriesLocalKey(for: item)].compactMap { $0 }
        let allKeys = crossKeys + localKeys

        if playbackSettings.rememberAudioTrackPerSeries {
            if viewerChangedAudioThisSession {
                if let language = firstSeriesAudioLanguage(localKeys) {
                    for key in allKeys { store.setAudioLanguage(language, forKey: key) }
                }
            } else {
                let localLanguage = firstSeriesAudioLanguage(localKeys)
                if let crossLanguage = firstSeriesAudioLanguage(crossKeys),
                   crossLanguage != localLanguage {
                    for key in localKeys { store.setAudioLanguage(crossLanguage, forKey: key) }
                    crossServerAudioImportLanguage = crossLanguage
                    applyImportedAudioIfPossible()
                }
            }
        }

        if playbackSettings.rememberSubtitleTrackPerSeries {
            if viewerChangedSubtitleThisSession {
                if let subtitle = firstSeriesSubtitle(localKeys) {
                    for key in allKeys { store.setSubtitle(subtitle, forKey: key) }
                }
            } else {
                let localSubtitle = firstSeriesSubtitle(localKeys)
                if let crossSubtitle = firstSeriesSubtitle(crossKeys),
                   crossSubtitle != localSubtitle {
                    for key in localKeys { store.setSubtitle(crossSubtitle, forKey: key) }
                    // Re-route the load-time subtitle now that the remembered value
                    // resolves. Works for native (tracks present → applies now) and
                    // Plozzigen (tracks arrive later → onTracksChanged re-applies).
                    initialSubtitleApplied = false
                    if let request { applyInitialSubtitleSelectionIfReady(for: request) }
                }
            }
        }
    }

    /// Applies a pending cross-server audio import once the engine's audio tracks
    /// are known. Retried from `onTracksChanged` (Plozzigen's async arrival) and at
    /// the end of `playResolved` (native, which never fires `onTracksChanged` and
    /// only populates `audioTracks` after `engine.load`). No-ops when the matching
    /// track is already active or no pending import is set.
    private func applyImportedAudioIfPossible() {
        guard let language = crossServerAudioImportLanguage else { return }
        guard let track = engine.audioTracks.first(where: {
            LanguageMatch.matches($0.language, language)
        }) else { return }
        crossServerAudioImportLanguage = nil
        guard track.id != engine.currentAudioTrackID, track.id != pendingAudioTrackID else { return }
        engine.selectAudioTrack(track)
        pendingAudioTrackID = track.id
        selectedAudioTrackID = track.id
        loadTrackOptions()
    }

    /// Loads an already-resolved request on the routed engine and finishes the
    /// bring-up (ready state, start report, track menu). Shared by the initial
    /// load and the cross-engine fallback (which re-uses the same request on the
    /// other engine without re-resolving).
    private func playResolved(
        _ request: PlaybackRequest,
        engineKind: PlaybackEngineKind,
        startPosition: TimeInterval
    ) async {
        commitEngineForPlayback(engineKind)
        // Publish the dynamic range the display is being driven to *before*
        // engine.load() requests the actual HDMI mode switch, so the view can
        // fade to black ahead of it. Only the native engine drives the panel's
        // display-mode switch; the Plozzigen engine plays HDR without one, so
        // it stays `.sdr` and no veil is raised. On a cross-engine fallback this
        // re-evaluates correctly: native→hybrid drops to `.sdr` (the native
        // engine's teardown restores SDR — a real switch the view should veil),
        // and hybrid→native rises to HDR (the new switch the view should veil).
        displayMode = engineKind == .native ? HDRDisplayMode(request.sourceMetadata) : .sdr
        // Engine-independent: tracks the *content's* range so the exit veil can
        // cover a panel HDR/DV → SDR switch even when a match-content engine
        // (Plozzigen) — which keeps `displayMode` `.sdr` above —
        // drove the panel into HDR on this TV.
        contentDisplayMode = HDRDisplayMode(request.sourceMetadata)
        // The overlay clamps its white point on HDR frames; mirror whether the
        // panel is actually being driven to HDR by ANY engine (Plozzigen also
        // match-content-switches the display), not just the native display-mode
        // transition above — otherwise HDR subtitle brightness is dead on the
        // Plozzigen HDR path. Neutral by default (scale 1.0 = no change); this
        // just unlocks the HDR Brightness row so it can actually take effect.
        liveSubtitles.isHDR = contentDisplayMode.isHDR
        // Mirror to the controls model so the style menu can show the HDR
        // Brightness row only while it actually affects the picture.
        controls.subtitlesRenderHDR = liveSubtitles.isHDR
        // Arm the stall watchdog around load() so a hang that never reports an
        // error still triggers the fallback chain instead of spinning forever.
        armPlaybackWatchdog(startPosition: startPosition)
        await Self.yieldToRunLoop()
        let loadStart = Date()
        await engine.load(request: request, startPosition: startPosition)
        HandoffDiagnostics.emit("engine.load returned engine=\(engineKind.rawValue) took=\(HandoffDiagnostics.ms(loadStart))")
        phase = .ready
        // Hold the bring-up spinner until the engine actually presents its first
        // frame, so `.loading` → `.ready` is one continuous indicator rather than
        // a spinner that vanishes here (before the picture is up) and then a black
        // gap / second in-player spinner while frames arrive.
        beginAwaitingFirstFrame()
        // Publish diagnostics after the engine load attempt returns, so the
        // diagnostics sampler doesn't churn SwiftUI layout during Plozzigen init.
        diagnosticsToken = UUID()
        // Report the *resolved* start position explicitly (not engine.currentTime,
        // which can still read 0 before the seek settles). When best-source routing
        // resumed a position learned from another server, this converges the chosen
        // server to that unified furthest-progress point on entry.
        await report(event: .start, isPaused: false, positionOverride: startPosition > 0 ? startPosition : nil)
        // Register the live session (idempotent) now that the server has a real
        // now-playing session, so convergence writes against this server defer
        // until stop() ends it.
        onPlaybackStarted()
        // Begin periodic mid-play convergence checkpoints from the resumed point so
        // progress fans out to other servers without waiting for Back. Seeded so the
        // first checkpoint only fires after real forward progress past the resume.
        startCheckpointLoop(seedPosition: startPosition)

        // Seed the in-player track menu from the engine's track lists (the
        // engine has already applied the user's default subtitle selection).
        loadTrackOptions()

        // Reflect what the new engine supports + apply persisted/initial tunable
        // state through it, so the options menu opens with accurate rows and the
        // user's last playback speed is honoured from frame 1.
        controls.engineCapabilities = engine.capabilities
        if engine.capabilities.contains(.playbackSpeed) {
            engine.setPlaybackSpeed(controls.playbackSpeed)
        } else {
            controls.playbackSpeed = 1.0
        }
        // Delays + dialog enhance reset on every load: they're per-stream and
        // carrying a previous file's −500ms offset onto a fresh one is awful.
        controls.audioDelaySeconds = 0
        controls.subtitleDelaySeconds = 0
        controls.dialogEnhanceEnabled = false
        engine.setAudioDelay(0)
        engine.setSubtitleDelay(0)
        engine.setDialogEnhanceEnabled(false)
        // Drop any overlay cues from a previous stream/engine and reset the sync
        // offset; a fresh selection re-seeds them. This is a full reset (new media
        // or engine), so the dual-subtitle selection is dropped too.
        subtitleCueLoadTask?.cancel()
        subtitleCueLoadTask = nil
        secondaryCueLoadTask?.cancel()
        secondaryCueLoadTask = nil
        selectedSecondarySubtitleTrackID = nil
        controls.secondarySubtitleStatus = .idle
        #if DEBUG
        controls.primarySubtitleDiagnostic = ""
        #endif
        liveSubtitles.offset = 0
        liveSubtitles.clear()
        refreshSubtitleDelayAvailability()

        // Route the load-time DEFAULT subtitle through Plozz's own overlay (same
        // as a manual pick) instead of letting AVPlayer / the engine draw it, so
        // the default lane gets identical HDR-safe styling + live offset. Native
        // tracks are ready now; Plozzigen's arrive later via `onTracksChanged`,
        // which calls this again. The per-load flag makes it fire exactly once.
        // (selectedSubtitleTrackID is intentionally NOT reset here: the image-sub
        // resolve path seeds it before playResolved so the menu reflects the
        // bitmap track Plozzigen draws; the routing below sets it for native/Plozzigen.)
        initialSubtitleApplied = false
        applyInitialSubtitleSelectionIfReady(for: request)

        // Apply any cross-server audio import that reconcile queued before the
        // engine's audio tracks were known. Native populates `audioTracks` only
        // after `engine.load` (here) and never fires `onTracksChanged`, so this is
        // its retry point; a no-op when nothing is pending or already correct.
        applyImportedAudioIfPossible()

        // Load skip markers once playback is live (opt-in, best-effort).
        loadSkipSegmentsIfEnabled()
    }

    // MARK: - Skip intros/credits

    /// Fetches server-detected skip segments when the per-profile Skip Intros
    /// setting is on, **or** when the Up Next card is enabled (the card triggers
    /// off the closing-credits marker, so we need the markers even with skip off).
    /// Publishes them to the controls model. No-op when neither needs them;
    /// failures degrade silently to no markers (older/marker-less servers). Runs
    /// once per load.
    private func loadSkipSegmentsIfEnabled() {
        let wantsMarkers = playbackSettings.skipIntros.fetchesMarkers || playbackSettings.showUpNextCard
        guard wantsMarkers else { return }
        controls.skipMode = playbackSettings.skipIntros
        segmentsTask?.cancel()
        let provider = provider
        let itemID = itemID
        segmentsTask = Task { @MainActor [weak self] in
            let segments = (try? await provider.mediaSegments(for: itemID)) ?? []
            guard let self, !Task.isCancelled else { return }
            self.controls.skippableSegments = segments.filter(\.isSkippable)
        }
    }

    /// Seeks past the currently-active skip segment (intro/credits) to its end,
    /// then clears it so the button dismisses. Invoked by the in-player Skip
    /// button. No-op when no segment is active.
    public func skipActiveSegment() {
        guard let segment = controls.activeSkipSegment else { return }
        controls.dismissedSegmentID = segment.id
        requestSeek(to: segment.end)
    }

    /// Dismisses the skip button for the active segment without seeking (Menu /
    /// swipe-away), so it won't keep stealing focus for the rest of the window.
    public func dismissActiveSkipSegment() {
        controls.dismissedSegmentID = controls.activeSkipSegment?.id
    }

    /// Auto-skips the active segment when the per-profile Auto-skip setting is on:
    /// seeks past it (like the Skip button) and flashes a brief "Skipping…"
    /// notice so the jump isn't jarring. Marks the segment dismissed first so the
    /// per-tick evaluation fires this exactly once per segment.
    public func autoSkipActiveSegment() {
        guard let segment = controls.activeSkipSegment else { return }
        controls.dismissedSegmentID = segment.id
        controls.autoSkipNotice = AutoSkipNotice(label: segment.kind.autoSkippedLabel)
        requestSeek(to: segment.end)
        autoSkipNoticeTask?.cancel()
        autoSkipNoticeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            guard let self, !Task.isCancelled else { return }
            self.controls.autoSkipNotice = nil
        }
    }

    // MARK: - Stall watchdog

    /// Starts (or restarts) the playback watchdog for the current engine. Polls
    /// the engine's `currentTime`; if it never advances past `startPosition`
    /// within ``watchdogTimeout``, the engine is treated as stalled and the
    /// failure chain runs. Cancelled/replaced on every `playResolved`, on pause,
    /// and on `stop()`. The once-only fallback guards keep this from looping.
    private func armPlaybackWatchdog(startPosition: TimeInterval) {
        watchdogTask?.cancel()
        let timeout = watchdogTimeout
        let threshold = startPosition + 0.5
        watchdogTask = Task { [weak self] in
            let pollNanos: UInt64 = 2_000_000_000
            var waited: TimeInterval = 0
            while waited < timeout {
                try? await Task.sleep(nanoseconds: pollNanos)
                if Task.isCancelled { return }
                guard let self else { return }
                // Real progress → healthy, stop watching.
                if self.engine.currentTime > threshold { return }
                // User paused (or playback hasn't been asked to play) → not a
                // stall; stop watching rather than fire a false positive.
                if self.engine.isPaused { return }
                waited += 2
            }
            if Task.isCancelled { return }
            guard let self else { return }
            // Still no progress after the deadline → treat as a stalled stream.
            if self.engine.currentTime <= threshold, !self.engine.isPaused {
                PlozzLog.playback.info("Playback watchdog: no progress before deadline; triggering fallback")
                await self.handleEngineFailure(.invalidResponse)
            }
        }
    }

    private func cancelWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = nil
    }

    // MARK: - Cross-engine fallback policy

    /// Decides what to do when the active engine reports a playback failure,
    /// following the fallback chain: the chosen engine's failure swaps to the
    /// *other* engine (once) at the last known position; if that also fails, force
    /// a server transcode (once); if even that fails, surface the error. Each step
    /// fires at most once so the chain can never loop.
    private func handleEngineFailure(_ error: AppError) async {
        guard let request else {
            phase = .failed(error)
            return
        }
        let resumeFrom = max(engine.furthestObservedPosition, engine.currentTime)
        let resume = resumeFrom > 1 ? resumeFrom : (startPositionOverride ?? request.startPosition)

        // 1) Direct play failed on the chosen engine → try the other engine once,
        //    re-using the same raw stream (no re-resolve needed). Skipped for an
        //    adaptive source (separate audio track): only the hybrid engine can
        //    mux it, so swapping to native would play silent video — go straight
        //    to the re-resolved safe (muxed) fallback below instead. Also skipped
        //    when the only alternate is native AVPlayer and the source is an
        //    `smb://` share: AVPlayer can't open an SMB URL at all, so a swap is a
        //    guaranteed-fail wasted attempt — fall through to the (re-resolving)
        //    transcode step, which re-routes back to Plozzigen for the share.
        let resolvedURL = request.localRemuxSource?.originalURL ?? request.streamURL
        let isSMBSource = resolvedURL.scheme?.lowercased() == "smb"
        if !request.isTranscoding, !hasTriedAlternateEngine, request.externalAudioURL == nil,
           let alternate = alternateEngineKind,
           !(alternate == .native && isSMBSource) {
            hasTriedAlternateEngine = true
            PlozzLog.playback.info("Engine failed; swapping to the alternate engine")
            await playResolved(request, engineKind: alternate, startPosition: resume)
            return
        }

        // 2) Both engines exhausted (or none to swap to) → force a server
        //    transcode once, resuming where the failed attempt left off.
        if !request.isTranscoding, !hasAttemptedTranscodeFallback {
            hasAttemptedTranscodeFallback = true
            PlozzLog.playback.info("Direct play failed; retrying with server transcode")
            await startPlayback(forceTranscode: true, resumeOverride: resume > 1 ? resume : nil)
            return
        }

        // 3) Already transcoding (or out of options): surface the error.
        clearFirstFrameWait()
        phase = .failed(error)
    }

    // MARK: - Progress reporting

    /// Reports the current position. Best-effort: a failed report must never
    /// interrupt playback, so errors are swallowed (and never logged with data).
    /// The same lifecycle is forwarded to Trakt so watches sync to the user's
    /// Trakt history.
    private func report(event: PlaybackEvent, isPaused: Bool, positionOverride: TimeInterval? = nil) async {
        guard let request else { return }
        let position = positionOverride ?? engine.currentTime
        let engineDuration = engine.duration
        let knownDuration: TimeInterval? = (engineDuration.isFinite && engineDuration > 0)
            ? engineDuration
            : request.item.runtime
        let progress = PlaybackProgress(
            itemID: itemID,
            playSessionID: request.playSessionID,
            positionSeconds: position,
            isPaused: isPaused,
            durationSeconds: knownDuration
        )
        do {
            try await provider.reportPlayback(progress, event: event)
        } catch {
            PlozzLog.playback.debug("Progress report failed (non-fatal)")
        }
        // Compute the scrobble percent from the SAME position the report used. At
        // stop() the engine is already torn down, so `engine.currentTime` reads 0 —
        // honoring `positionOverride` keeps the live stop-scrobble's percent honest
        // (otherwise Trakt would see 0% and never mark the title watched).
        let scrobblePercent = positionOverride.map { watchedPercent(at: $0) } ?? watchedPercent()
        await scrobbler.scrobble(item: request.item, progress: scrobblePercent, event: event)
    }

    /// Watched percentage (0...100) from the engine's current position over the
    /// item's duration, preferring the engine's known duration and falling back
    /// to the item runtime. `0` when neither is known.
    private func watchedPercent() -> Double {
        watchedPercent(at: engine.currentTime)
    }

    /// Watched percentage (0...100) for an explicit `position` over the item's
    /// duration, preferring the engine's known duration and falling back to the
    /// item runtime. `0` when neither is known. Used at `stop()` so the percentage
    /// is computed from the captured final position (the engine is torn down there).
    private func watchedPercent(at position: TimeInterval) -> Double {
        guard position.isFinite, position >= 0 else { return 0 }
        let engineDuration = engine.duration
        let duration = (engineDuration.isFinite && engineDuration > 0)
            ? engineDuration
            : request?.item.runtime
        guard let duration, duration > 0 else { return 0 }
        return min(max(position / duration * 100, 0), 100)
    }

    // MARK: - Convergence checkpoints

    /// Starts the periodic mid-play convergence loop. Each tick fires a checkpoint
    /// (see ``emitCheckpoint``) so progress fans out to other servers roughly every
    /// ``checkpointInterval`` seconds without the user pressing Back. Cancelled and
    /// restarted defensively; `stop()` tears it down. A non-positive interval (or a
    /// default no-op hook) leaves the loop off so standalone/test players are
    /// unaffected.
    private func startCheckpointLoop(seedPosition: TimeInterval) {
        lastCheckpointPosition = max(0, seedPosition)
        checkpointTask?.cancel()
        guard checkpointInterval > 0 else { return }
        let interval = checkpointInterval
        checkpointTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { return }
                self?.emitCheckpoint()
            }
        }
    }

    /// Enqueues a convergence checkpoint for the current position **iff** the player
    /// has made real forward progress since the last one and isn't paused/stalled —
    /// so a paused or stuck player never re-writes the same position to N servers.
    /// Pure enqueue (no network on this path); safe to call from the timer or, on
    /// app background, from `checkpointNow()`.
    private func emitCheckpoint() {
        guard request != nil, !engine.isPaused else { return }
        let position = max(engine.furthestObservedPosition, engine.currentTime)
        guard position > 1, position - lastCheckpointPosition >= 1 else { return }
        lastCheckpointPosition = position
        onPlaybackCheckpoint(position, watchedPercent(at: position))
    }

    /// Forces an immediate convergence checkpoint regardless of the timer — used
    /// when the app is about to be backgrounded/suspended (the TV Home button or
    /// sleep path, which never fires the view's `onDisappear`/`stop()`), so the
    /// latest position is durably captured before the process can be killed.
    public func checkpointNow() {
        emitCheckpoint()
    }

    /// Handles the app leaving the foreground (TV Home button, sleep, or app
    /// switcher) — a path that never fires the view's `onDisappear`/`stop()`. It
    /// first takes a durable checkpoint at the **live** position (while still
    /// playing, so the checkpoint guard passes), then **pauses** the engine so audio
    /// doesn't keep decoding/playing in the background until the OS suspends the
    /// process. Deliberately one-way: returning to the foreground leaves playback
    /// paused so the user resumes intentionally, rather than audio springing back
    /// to life on its own.
    public func suspendForBackground() {
        emitCheckpoint()
        // Key off intent, not `engine.isPaused`: if we mean to be playing (even
        // while the engine is mid post-seek settle), pause for real — this also
        // routes through `cancelResumeConfirm()` so a recovery loop can't wake the
        // engine back up as the app suspends.
        if intendsPlayback {
            setPaused(true)
        }
    }

    // MARK: - Transport

    /// Requests a committed seek. Coalesces rapid presses: while one seek is
    /// in flight, additional calls just update the *latest target*; the
    /// scheduler loop then jumps directly to that latest target (skipping the
    /// intermediate values entirely) using `.fast` for any intermediate hop
    /// and `.exact` for the final settle. The `pendingSeekTarget` flag pins
    /// the on-screen position so the refresh loop can't snap the bar backward
    /// to a stale `engine.currentTime` while the seek resolves.
    public func requestSeek(to seconds: TimeInterval) {
        let target = max(0, seconds)
        PlaybackTrace.note("requestSeek to=\(String(format: "%.2f", target)) from=\(String(format: "%.2f", controls.currentSeconds)) dir=\(target < controls.currentSeconds ? "BACK" : "fwd") engineState curr=\(String(format: "%.2f", engine.currentTime)) dur=\(String(format: "%.2f", engine.duration))")
        controls.currentSeconds = target
        controls.pendingSeekTarget = target
        controls.isSeeking = true
        latestSeekTarget = target
        // Classify where this seek lands relative to any skippable segment so the
        // overlay can respect a deliberate seek: deep landings suppress the Skip
        // affordance, grace-window landings offer a manual button only (Option B).
        updateSeekLanding(for: target)
        // A fresh seek supersedes any in-flight resume confirmation; the new
        // seek will start its own once it lands. Keep the mirror suppressed for
        // the new in-flight seek when we still intend to play, so a transient
        // engine pause between back-to-back committed seeks can't surface.
        cancelResumeConfirm()
        if intendsPlayback { controls.isResumeConfirming = true }
        // Coalesce rapid presses: defer the actual engine seek by a short window
        // so a burst of skips collapses into ONE seek (one re-buffer) to the final
        // target. The on-screen position + skip hint already moved above, so the
        // delay is invisible. A loop already draining picks up the new target on
        // its own, so `scheduleSeekCommit` only starts one when idle.
        scheduleSeekCommit()
    }

    /// Classifies a committed seek's landing relative to the skippable segments so
    /// the overlay can honor a deliberate seek (Option B). A landing *inside* a
    /// skippable segment records a ``SkipSeekLanding``: within the opening grace
    /// window → a manual Skip button is still offered; deeper → the affordance is
    /// suppressed (the seek is respected). A landing outside every segment clears
    /// it. The container clears a stale landing once the live position leaves the
    /// segment, so a later natural re-entry behaves normally.
    private func updateSeekLanding(for target: TimeInterval) {
        guard let segment = controls.skippableSegments.activeSkippable(at: target) else {
            controls.seekLanding = nil
            return
        }
        let offset = target - segment.start
        controls.seekLanding = SkipSeekLanding(
            segmentID: segment.id,
            isWithinGrace: offset <= MediaSegment.seekGraceWindow
        )
    }

    /// Schedules the deferred engine commit for `requestSeek`. Resets on each call
    /// so consecutive presses keep pushing the commit out until they stop, then a
    /// single seek fires to the accumulated `latestSeekTarget`. If a seek loop is
    /// already draining we don't start another — it will pick up the new target
    /// itself — so this is a no-op mid-drain.
    private func scheduleSeekCommit() {
        seekCommitTask?.cancel()
        guard seekTask == nil else { return }
        seekCommitTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: self?.seekCommitDebounce ?? 200_000_000)
            guard let self, !Task.isCancelled else { return }
            self.seekCommitTask = nil
            if self.seekTask == nil, self.latestSeekTarget != nil {
                self.startSeekLoop()
            }
        }
    }

    private func cancelSeekCommit() {
        seekCommitTask?.cancel()
        seekCommitTask = nil
    }

    private func startSeekLoop() {
        seekTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // If we intend to keep playing across this committed seek, suppress
            // the engine→model pause mirror for the WHOLE window up front — the
            // engine can settle to a transient paused state mid-seek, and letting
            // that reach the model is what flashed the pause icon and (worse) made
            // the resume gate below mis-read intent. Cleared on every exit path.
            if self.intendsPlayback { self.controls.isResumeConfirming = true }
            // Drain: process the latest pending target until none remains.
            while let next = self.takeLatestSeekTarget() {
                // If a newer target arrives while this one is in flight, we
                // can be cheap here — only the LAST one needs to be precise.
                let isFinal = (self.latestSeekTarget == nil)
                let kind: VideoSeekKind = isFinal ? .exact : .fast
                await self.engine.seek(to: next, kind: kind)
                // A teardown (stop) or supersede can land while we were suspended
                // in the seek above — bail before touching a torn-down engine.
                // NOTE: only stop() currently cancels seekTask, so clearing the
                // suppression flag here is safe. If superseding seeks ever cancel
                // and restart seekTask, this clear could clobber a newer seek's
                // flag — re-evaluate then.
                if Task.isCancelled || self.didStop {
                    self.controls.isResumeConfirming = false
                    self.seekTask = nil
                    return
                }
            }
            self.seekTask = nil
            self.controls.isSeeking = false
            // The seek has landed. AVPlayer / AEEngine can settle at rate 0 once a
            // seek resolves on a buffering edge — the data is ready but playback
            // never resumes on its own (a manual pause→play would start it
            // instantly). Re-assert play AND confirm it actually took, so a
            // committed seek always resumes without the viewer nudging it.
            // Gate on `intendsPlayback` (NOT `controls.isPaused`, which the engine
            // mirror can have flipped to a transient paused during the drain): so
            // scrubbing while paused — or a user pause mid-seek — stays paused.
            if !Task.isCancelled, !self.didStop, self.intendsPlayback {
                self.confirmResumeAfterSeek()
            } else {
                self.controls.isResumeConfirming = false
                // We do NOT intend playback (pause-to-seek mode, or a user pause
                // mid-seek). A committed seek can leave the engine auto-resumed,
                // or settled at rate-0-while-still-reporting-"playing" — either
                // way the overlay would wrongly read "playing" and the picture
                // would sit frozen. Re-assert the pause so playback genuinely
                // stops AND the overlay reads paused; we stay paused on the
                // landed frame until the user explicitly resumes.
                if !self.didStop {
                    self.engine.pause()
                    self.controls.isPaused = true
                    // This branch is reached only when we do NOT intend playback
                    // (pause-to-seek, or a user pause mid-seek), so the pause here
                    // is genuine intent — keep the glyph's intent gate honest.
                    self.controls.intendsPause = true
                }
            }
            // `pendingSeekTarget` is cleared by the refresh poll once the
            // engine's `currentTime` arrives within tolerance of the target —
            // that's the moment it's safe to resume mirroring engine time.
        }
    }

    /// Re-issues `play()` after a committed seek and verifies the engine clock
    /// actually advances, retrying for a short window. Fixes the intermittent
    /// "landed but frozen" state where playback settles at rate 0 post-seek and a
    /// single `play()` is swallowed. Self-cancels the moment the clock advances,
    /// the user pauses, or a new seek supersedes it.
    private func confirmResumeAfterSeek() {
        resumeConfirmTask?.cancel()
        // We intend to play from here on; mark it so the container stops
        // mirroring the engine's transient post-seek paused state into the model
        // (which would flash the pause icon and make this loop think the user
        // paused).
        controls.isResumeConfirming = true
        resumeConfirmTask = Task { @MainActor [weak self] in
            guard let self else { return }
            ScrubDiagnostics.note("resume-confirm: start t=\(String(format: "%.2f", self.engine.currentTime)) enginePaused=\(self.engine.isPaused)")
            // After a committed seek the engine should already be playing (the
            // commit path re-issued play()). But AEEngine/AVPlayer can land at
            // rate 0 on a buffering edge while still reporting "playing", so a
            // plain play() is a no-op and the picture sits frozen. Verify the
            // clock actually advances; if it doesn't, escalate to a pause→play
            // "kick" — the same transition a manual pause/play does, which is the
            // only thing that reliably re-primes a stalled AEEngine.
            //
            // We deliberately do NOT consult `controls.isPaused` inside this loop.
            // The container mirrors `engine.isPaused` into `controls.isPaused`
            // every refresh tick, and the engine's transient post-seek pause is
            // exactly the freeze we're here to fix — treating it as "the user
            // paused" is what made the previous version bail before it ever
            // kicked. A genuine user pause goes through setPaused(true), which
            // cancels this task; Task cancellation (user pause / superseding seek /
            // teardown) is our only stop signal.
            var lastTime = self.engine.currentTime
            var kicks = 0
            // Require the clock to advance on TWO consecutive checks before
            // declaring success — a single tick can be a post-seek keyframe snap
            // or a one-frame buffer dribble that then re-freezes, which would
            // otherwise leave us stuck (the very bug we're fixing). We only kick
            // when actually stalled, so an engine that's genuinely recovering is
            // observed, not disrupted.
            var advancingStreak = 0
            // ~4s of coverage: 12 attempts × ~300ms (plus 60ms per kick).
            for attempt in 0..<12 {
                if Task.isCancelled { return }
                let stalled = (advancingStreak == 0)
                if attempt == 0 {
                    // Cheap, blip-free first try — handles the common healthy
                    // landing where play() just needs re-asserting.
                    self.engine.play()
                } else if stalled {
                    // Still no forward motion → kick it (pause→play), the same
                    // transition a manual pause/play does.
                    self.engine.pause()
                    try? await Task.sleep(nanoseconds: 60_000_000)
                    if Task.isCancelled { return }
                    self.engine.play()
                    kicks += 1
                }
                // else: clock is moving — just observe again, don't disrupt it.
                try? await Task.sleep(nanoseconds: 300_000_000)
                if Task.isCancelled { return }
                let now = self.engine.currentTime
                if now > lastTime + 0.05 {
                    advancingStreak += 1
                    lastTime = now
                    // Two clean advances in a row → genuinely playing.
                    if advancingStreak >= 2 {
                        ScrubDiagnostics.note("resume-confirm: resumed after \(kicks) kick(s)")
                        self.controls.isResumeConfirming = false
                        self.resumeConfirmTask = nil
                        return
                    }
                } else {
                    advancingStreak = 0
                    lastTime = now
                }
            }
            ScrubDiagnostics.note("resume-confirm: gave up still-stalled after \(kicks) kick(s)")
            // We exhausted the kicks and the engine is genuinely sitting at
            // rate 0 (a real stall, not the transient settle we can recover).
            // Reconcile intent with reality instead of leaving `intendsPlayback`
            // stuck "playing": mark it paused so the pause indicator is honest and
            // the viewer's next Play press cleanly retries playback (rather than
            // being read as a pause). `setPaused(true)` also clears
            // `isResumeConfirming`, nils this task, and reports the pause.
            // (Two-consecutive-advance success gating means a false give-up here
            // would require the engine to be effectively frozen anyway, so pausing
            // it is safe.)
            self.setPaused(true)
        }
    }

    /// Cancels any in-flight post-seek resume confirmation and clears the
    /// suppression flag. Called from every site that supersedes or ends a resume
    /// (a fresh seek, a user pause, teardown). The cancelled task itself does NOT
    /// touch `isResumeConfirming` on its cancellation path, so a brand-new
    /// confirmation started right after a cancel can't be clobbered by the old
    /// task waking up.
    private func cancelResumeConfirm() {
        resumeConfirmTask?.cancel()
        resumeConfirmTask = nil
        controls.isResumeConfirming = false
    }

    private func takeLatestSeekTarget() -> TimeInterval? {
        guard let target = latestSeekTarget else { return nil }
        latestSeekTarget = nil
        return target
    }

    /// Legacy direct-seek path retained for callers (e.g. resume on load) that
    /// want a one-shot await. New transport input goes through `requestSeek`.
    public func seek(to seconds: TimeInterval) async {
        controls.isSeeking = true
        controls.currentSeconds = max(0, seconds)
        controls.pendingSeekTarget = max(0, seconds)
        await engine.seek(to: seconds, kind: .exact)
        controls.isSeeking = false
    }

    // MARK: Live tunables (engine fan-out)

    public func setPlaybackSpeed(_ rate: Double) {
        let clamped = max(0.25, min(4.0, rate))
        controls.playbackSpeed = clamped
        engine.setPlaybackSpeed(clamped)
        preferencesStore.savePlaybackSpeed(clamped)
    }

    public func setAudioDelay(_ seconds: TimeInterval) {
        let clamped = max(-10, min(10, seconds))
        controls.audioDelaySeconds = clamped
        engine.setAudioDelay(clamped)
    }

    public func setSubtitleDelay(_ seconds: TimeInterval) {
        let clamped = max(-10, min(10, seconds))
        controls.subtitleDelaySeconds = clamped
        engine.setSubtitleDelay(clamped)
        // The overlay applies the same offset to its cue timeline. AVPlayer can't
        // shift an injected sidecar, so when our overlay owns the track this is
        // what actually makes "Subtitle delay" work for text subtitles.
        liveSubtitles.offset = clamped
    }

    /// Mirrors whether the overlay owns the active *primary* subtitle into the
    /// controls model. The in-player "Sync" control is gated on this: app-side
    /// ``LiveSubtitleModel/offset`` only shifts the on-screen track when the
    /// overlay drives it (sidecar timeline or engine live-feed), so the chip is
    /// hidden for subtitles-off and player-drawn embedded text. Call after any
    /// change to the primary overlay stream.
    private func refreshSubtitleDelayAvailability() {
        controls.subtitleDelayAdjustable = liveSubtitles.rendersPrimary
    }

    public func setDialogEnhanceEnabled(_ enabled: Bool) {
        controls.dialogEnhanceEnabled = enabled
        engine.setDialogEnhanceEnabled(enabled)
    }

    /// Applies a subtitle **appearance** edit from the in-player Style screen.
    /// Updates the live overlay for instant preview, keeps the controls mirror
    /// (which the editor binds) in sync, pushes the look to the engine so a
    /// natively-drawn embedded track (AVPlayer `textStyleRules`) restyles live too,
    /// and notifies the host so the new look is persisted to the profile's
    /// appearance store. Kept as the single funnel so live preview and persistence
    /// can never drift apart.
    public func applySubtitleStyle(_ newStyle: SubtitleStyle) {
        style = newStyle
        liveSubtitles.style = newStyle
        controls.subtitleStyle = newStyle
        engine.updateSubtitleStyle(newStyle)
        onSubtitleStyleChanged(newStyle)
    }

    /// Toggles play/pause from the custom transport, keeping `controls` and the
    /// server report in sync.
    public func togglePlayPause() {
        // Toggle from our own intent, NOT `engine.isPaused`: during the post-seek
        // recovery window the engine can transiently report paused while we're
        // actively driving it back to playing. Reading the engine here would make
        // a user's "pause" press compute `setPaused(false)` and re-play instead.
        setPaused(intendsPlayback)
    }

    public func setPaused(_ paused: Bool) {
        // This is the one funnel for genuine play/pause intent — record it before
        // anything else so every resume/transport decision has a truthful signal
        // that the engine's transient post-seek pause can't corrupt.
        intendsPlayback = !paused
        controls.intendsPause = paused
        if paused { engine.pause() } else { engine.play() }
        // A user pause means "no progress" is expected — don't let the stall
        // watchdog misfire, and stop any post-seek resume nudging so we don't
        // race the pause back to playing.
        if paused {
            cancelWatchdog()
            cancelResumeConfirm()
        }
        controls.isPaused = paused
        Task { await report(event: paused ? .pause : .unpause, isPaused: paused) }
    }

    /// Guards against a double teardown: `PlayerView` may call `stop()` itself on
    /// an HDR-aware dismiss (to start the SDR switch behind the veil) and then the
    /// view's `onDisappear` fires a second `stop()` once it's torn down. Without
    /// this the server would get two `.stop` reports for one playback.
    private var didStop = false

    /// Call when leaving playback: report a final stop so the server records the
    /// resume point, then tear the engine down.
    public func stop(preserveDisplayMode: Bool = false) async {
        guard !didStop else { return }
        HandoffDiagnostics.emit("stop preserveDisplayMode=\(preserveDisplayMode) contentMode=\(contentDisplayMode) (false ⇒ panel should reset to SDR)")
        PlaybackTrace.note("stop() teardown curr=\(String(format: "%.2f", engine.currentTime)) shouldDismiss=\(shouldDismiss) pendingNext=\(pendingNextEpisode != nil) isSeeking=\(controls.isSeeking)")
        didStop = true
        prefetchTask?.cancel()
        prefetchTask = nil
        // Cancel the next-episode prefetch; its session (if any) is released
        // below, after the current engine is silenced, so cleanup never delays
        // stopping playback.
        nextEpisodePrefetchTask?.cancel()
        nextEpisodePrefetchTask = nil
        clearFirstFrameWait()
        checkpointTask?.cancel()
        checkpointTask = nil
        segmentsTask?.cancel()
        segmentsTask = nil
        autoSkipNoticeTask?.cancel()
        autoSkipNoticeTask = nil
        cancelWatchdog()
        cancelSeekCommit()
        seekTask?.cancel()
        seekTask = nil
        cancelResumeConfirm()
        subtitleDownloadTask?.cancel()
        subtitleDownloadTask = nil
        subtitleCueLoadTask?.cancel()
        subtitleCueLoadTask = nil
        secondaryCueLoadTask?.cancel()
        secondaryCueLoadTask = nil
        // Silence the engine *before* the final server report. The report is a
        // network round-trip that can take a second or two; stopping first means
        // leaving the player never keeps playing audio while it completes. Grab
        // the resume position up front since the engine is torn down here.
        let finalPosition = max(engine.furthestObservedPosition, engine.currentTime)
        let percent = watchedPercent(at: finalPosition)
        engine.stop(preserveDisplayMode: preserveDisplayMode)
        // Release any prefetched next-episode session that was never adopted, and
        // an adopted-but-never-committed session (a hand-off torn down before the
        // incoming player took ownership), so a Jellyfin session isn't orphaned.
        // A no-op for idempotent providers. Done AFTER engine.stop() so it never
        // keeps audio playing while the cleanup round-trips.
        if let orphan = prefetchedNext {
            prefetchedNext = nil
            await releasePrefetchedSession(orphan.request)
        }
        if let unadopted = adoptedResolved {
            adoptedResolved = nil
            await releasePrefetchedSession(unadopted.request)
        }
        // Let in-flight series-id enrichment finish so a fast playthrough still
        // scrobbles with the show's ids (anime tagged only AniDB resolve mal/
        // anilist here). Capped at 2s so a slow server never blocks teardown.
        if let enrichTask {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await enrichTask.value }
                group.addTask { try? await Task.sleep(nanoseconds: 2_000_000_000) }
                _ = await group.next()
                group.cancelAll()
            }
        }
        await report(event: .stop, isPaused: true, positionOverride: finalPosition)
        onPlaybackStopped(finalPosition, percent)
    }

    // MARK: - View / diagnostics access

    /// The live `AVPlayer` backing the active (native) engine, exposed for the
    /// AVFoundation-specific diagnostics sampler and the system player view.
    /// Returns `nil` for a non-AVFoundation engine (diagnostics is best-effort).
    public var player: AVPlayer? { (engine as? NativeVideoEngine)?.underlyingPlayer }

    /// Live engine telemetry (dropped frames / FPS / bitrate) for diagnostics.
    /// `nil` on the native engine (the sampler uses the AVPlayer access log); the
    /// Plozzigen engines vend it so those fields aren't blank.
    public var engineLiveTelemetry: EngineLiveTelemetry? { engine.liveTelemetry }

    /// A stable identity for the active player instance, so views can restart
    /// player-bound work (e.g. the diagnostics sampler) when the transcode
    /// fallback swaps in a new player.
    public var playerInstanceID: ObjectIdentifier? {
        player.map(ObjectIdentifier.init)
    }

    public var availableSubtitleTracks: [MediaTrack] { request?.subtitleTracks ?? [] }
    public var availableAudioTracks: [MediaTrack] { request?.audioTracks ?? [] }

    /// Whether the active stream is being transcoded by the server (vs direct
    /// play). Read by the playback diagnostics overlay.
    public var isTranscoding: Bool { request?.isTranscoding ?? false }

    /// How the server is delivering the active stream (direct play / remux /
    /// transcode). When Plozzigen is the active engine, it overrides the provider's
    /// mode since Plozzigen reads original bytes directly (not a server transcode).
    public var deliveryMode: PlaybackDiagnostics.PlaybackMode {
        if currentEngineKind == .plozzigen { return .plozzigen }
        return request?.deliveryMode ?? .unknown
    }

    /// Provider source facts (codec/HDR/channels/…) for the playing item, used
    /// to populate the playback diagnostics overlay.
    public var sourceMetadata: MediaSourceMetadata? { request?.sourceMetadata }

    /// Which backend (Plex / Jellyfin) resolved the active playback.
    public var sourceProvider: ProviderKind? { request?.sourceProvider }
    public var serverName: String? { request?.serverName }

    /// The URL AVPlayer is actually playing, used for the diagnostics "Stream"
    /// transport row.
    public var diagnosticsStreamURL: URL? { request?.streamURL }

    /// Device/display/audio capabilities used for routing and diagnostics.
    public var mediaCapabilities: MediaCapabilities { capabilities }

    /// Scrubbing-preview source for the playing item, if the server has previews.
    public var scrubPreview: ScrubPreviewSource? { request?.scrubPreview }

    /// The active engine, exposed so the shared transport overlay can drive
    /// playback (play/pause/seek/state/tracks) and host the engine's bare video
    /// surface — without knowing the concrete engine type.
    public var videoEngine: any VideoEngine { engine }

    /// A short, human-readable name for the active engine (e.g. `AVPlayer`,
    /// `VLCKit`), surfaced in the diagnostics overlay.
    public var engineDisplayName: String { engine.displayName }

    // MARK: - Custom transport configuration

    /// Seeds the transport overlay with title/subtitle/duration facts when a
    /// stream resolves, so the controls are correct from the first frame.
    private func configureControls(for request: PlaybackRequest) {
        let lines = Self.titleLines(for: request.item)
        controls.title = lines.primary
        controls.subtitle = lines.secondary
        controls.overview = request.item.overview ?? ""
        controls.infoHeadline = request.item.title
        controls.infoEpisodeTag = Self.episodeTag(for: request.item)
        controls.infoBadges = request.item.technicalBadges
        controls.artworkURLs = [request.item.backdropURL, request.item.heroBackdropURL, request.item.fallbackArtworkURL, request.item.posterURL].compactMap { $0 }
        controls.infoRuntimeLabel = request.item.runtime?.runtimeBadgeText ?? ""
        controls.hasTrickplay = request.scrubPreview?.isUsable ?? false
        controls.duration = request.item.runtime ?? 0
        controls.currentSeconds = 0
        controls.bufferedSeconds = 0
        controls.isScrubbing = false
        controls.previewImage = nil
        controls.isPaused = false
        controls.intendsPause = false
    }

    /// The transport's two title lines, Apple-TV style. For episodes the SERIES
    /// is the prominent (primary) line and the episode rides above it as the
    /// secondary line "S1, E2 • Episode Title". For movies (and anything without
    /// a parent series) the item's own title is primary with no secondary line.
    private static func titleLines(for item: MediaItem) -> (primary: String, secondary: String) {
        guard let series = item.parentTitle, !series.isEmpty else {
            return (item.title, "")
        }
        var prefix = ""
        if let season = item.seasonNumber, let episode = item.episodeNumber {
            prefix = "S\(season), E\(episode)"
        } else if let episode = item.episodeNumber {
            prefix = "E\(episode)"
        }
        let episodeTitle = item.title
        let secondary: String
        if prefix.isEmpty {
            secondary = episodeTitle
        } else if episodeTitle.isEmpty {
            secondary = prefix
        } else {
            secondary = "\(prefix) • \(episodeTitle)"
        }
        return (series, secondary)
    }

    /// Compact season/episode tag for the Info card metadata row (e.g. "S2 · E7").
    /// Empty for movies and anything without episode numbering.
    private static func episodeTag(for item: MediaItem) -> String {
        if let season = item.seasonNumber, let episode = item.episodeNumber {
            return "S\(season) · E\(episode)"
        }
        if let episode = item.episodeNumber {
            return "E\(episode)"
        }
        return ""
    }

    // MARK: - Track selection (custom player menu)

    /// Publishes the engine's audio/subtitle track lists into `controls` for the
    /// in-player track menu. Switching is routed back through the engine so the
    /// menu behaves identically across engines.
    private func loadTrackOptions() {
        // Enrich the engine's demuxed tracks with the provider's probe of the
        // same file (matched by stream id), filling in any language/codec/title
        // the demuxer dropped. For the native engine the two lists are identical,
        // so this is a no-op there; it only adds data on the advanced engine.
        let providerAudio = request?.audioTracks ?? []
        let providerSubs = request?.subtitleTracks ?? []

        let audio = engine.audioTracks.map { track in
            track.enriched(withProvider: providerAudio.first { $0.id == track.id })
        }
        // The "selected audio" indicator must reflect the track the engine is
        // *actually* decoding, not a re-derived default-flag guess (those can
        // disagree: e.g. a dual-audio anime whose container defaults to Japanese
        // while the engine starts the English track per the viewer's audio-language
        // preference — the menu was highlighting Japanese while English played).
        // Priority: an in-flight pick (optimistic) → the engine's resolved active
        // track (ground truth) → the default-flag heuristic only before either is
        // known.
        if let pending = pendingAudioTrackID, audio.contains(where: { $0.id == pending }) {
            selectedAudioTrackID = pending
            if engine.currentAudioTrackID == pending { pendingAudioTrackID = nil }
        } else if let active = engine.currentAudioTrackID,
                  audio.contains(where: { $0.id == active }) {
            selectedAudioTrackID = active
            pendingAudioTrackID = nil
        } else if selectedAudioTrackID == nil {
            selectedAudioTrackID = audio.first(where: { $0.isDefault })?.id ?? audio.first?.id
        }
        // Preferred languages, highest priority first: the viewer's explicit
        // choice (or device language) leads, the device language backs it up.
        let preferred: [String?] = [
            behavior.resolvedPreferredLanguage,
            LanguageMatch.deviceLanguageCode
        ]
        controls.audioOptions = audio
            .sortedByPreferredLanguage(preferred)
            .map { track in
                PlayerTrackOption(
                    id: track.id,
                    title: TrackLabeling.audioLabel(
                        displayTitle: track.displayTitle,
                        language: track.language,
                        codec: track.codec,
                        channels: track.channels,
                        isAtmos: track.isAtmos,
                        isCommentary: track.isCommentary,
                        trackID: track.id
                    ),
                    isSelected: track.id == selectedAudioTrackID
                )
            }

        let subtitles = engine.subtitleTracks.map { track in
            track.enriched(withProvider: providerSubs.first { $0.id == track.id })
        }
        #if DEBUG
        // One-line ground truth for untagged-track triage: how many subtitle
        // tracks still lack a language after enrichment, and whether the provider
        // had any languages to lend. If both are zero/empty the file is genuinely
        // untagged (only OCR could do better); a gap here means an id-space miss.
        let unresolved = subtitles.filter { $0.language == nil }.count
        let providerWithLang = providerSubs.filter { $0.language != nil }.count
        PlozzLog.playback.debug(
            "Track labels: \(subtitles.count) subs, \(unresolved) still no language; provider probe had \(providerSubs.count) subs (\(providerWithLang) with a language)"
        )
        #endif
        if subtitles.isEmpty {
            controls.subtitleOptions = []
        } else {
            // "Off" stays pinned first; real tracks sort preferred-language-first.
            var options = [PlayerTrackOption(id: PlayerTrackOption.offID, title: "Off", isSelected: selectedSubtitleTrackID == nil)]
            options.append(contentsOf: subtitles.sortedByPreferredLanguage(preferred).map { track in
                PlayerTrackOption(
                    id: track.id,
                    title: TrackLabeling.subtitleLabel(
                        displayTitle: track.displayTitle,
                        language: track.language,
                        codec: track.codec,
                        isForced: track.isForced,
                        isImageBased: track.isImageBasedSubtitle,
                        isHearingImpaired: track.isHearingImpaired,
                        isCommentary: track.isCommentary,
                        detectedLanguage: detectedSubtitleLanguages[track.id],
                        trackID: track.id
                    ),
                    isSelected: track.id == selectedSubtitleTrackID
                )
            })
            controls.subtitleOptions = options
        }

        // Dual/second-line picker: any text track resolved to a sidecar the
        // overlay can parse (embedded text falls back to the provider's VTT URL),
        // excluding the primary. If the current secondary is no longer eligible
        // (e.g. it just became the primary, or the media changed), reconcile by
        // dropping it — clearing both its cues and its styling.
        let secondaryEligible = eligibleSecondarySubtitleTracks()
        // Distinguish an empty dual picker caused by a bitmap PRIMARY (dual is
        // disallowed — a PGS/DVD line can't be positioned) from one that's empty
        // because the media simply has no other text track, so the row can explain
        // the former ("Unavailable with PGS subtitles") rather than "None available".
        if let primaryID = selectedSubtitleTrackID,
           let primary = engine.subtitleTracks.first(where: { $0.id == primaryID })
            ?? providerSubs.first(where: { $0.id == primaryID }),
           primary.isBitmapSubtitle {
            controls.secondarySubtitleImagePrimaryFormat =
                TrackLabeling.subtitleFormatHint(codec: primary.codec, isImageBased: true) ?? "Image"
        } else {
            controls.secondarySubtitleImagePrimaryFormat = nil
        }
        if let sec = selectedSecondarySubtitleTrackID,
           !secondaryEligible.contains(where: { $0.id == sec }) {
            selectedSecondarySubtitleTrackID = nil
            secondaryCueLoadTask?.cancel()
            secondaryCueLoadTask = nil
            if engine.capabilities.contains(.dualSubtitleDecode) {
                engine.selectSecondarySubtitleTrack(nil)
            }
            liveSubtitles.loadSecondary(nil)
            controls.secondarySubtitleStatus = .idle
            if style.secondary != nil {
                var cleared = style
                cleared.secondary = nil
                applySubtitleStyle(cleared)
            }
        }
        if secondaryEligible.isEmpty {
            controls.secondarySubtitleOptions = []
        } else {
            var secOptions = [PlayerTrackOption(id: PlayerTrackOption.offID, title: "Off", isSelected: selectedSecondarySubtitleTrackID == nil)]
            secOptions.append(contentsOf: secondaryEligible.sortedByPreferredLanguage(preferred).map { track in
                PlayerTrackOption(
                    id: track.id,
                    title: TrackLabeling.subtitleLabel(
                        displayTitle: track.displayTitle,
                        language: track.language,
                        codec: track.codec,
                        isForced: track.isForced,
                        isImageBased: track.isImageBasedSubtitle,
                        isHearingImpaired: track.isHearingImpaired,
                        isCommentary: track.isCommentary,
                        detectedLanguage: detectedSubtitleLanguages[track.id],
                        trackID: track.id
                    ),
                    isSelected: track.id == selectedSecondarySubtitleTrackID
                )
            })
            controls.secondarySubtitleOptions = secOptions
        }
    }

    /// Selects an audio track from the menu, routed through the engine.
    public func selectAudioOption(id: Int) {
        guard let track = engine.audioTracks.first(where: { $0.id == id }) else { return }
        viewerChangedAudioThisSession = true
        engine.selectAudioTrack(track)
        // Remember this language for the series so later episodes start here.
        recordSeriesAudioSelection(language: track.language)
        // Show the target immediately; the engine's reload-to-switch lags, so we
        // hold this optimistic pick until `currentAudioTrackID` confirms it (see
        // loadTrackOptions) to avoid the indicator snapping back to the old track.
        pendingAudioTrackID = id
        selectedAudioTrackID = id
        loadTrackOptions()
    }

    /// Routes the load-time **default** subtitle through Plozz's owned overlay so
    /// it renders identically to a manual menu pick (HDR-safe SDR overlay, full
    /// styling, live offset) instead of being drawn by AVPlayer's legible group
    /// or the engine. Runs once per `playResolved`:
    /// - **native** — provider tracks are known synchronously, so it applies
    ///   immediately from `playResolved`.
    /// - **Plozzigen** — the engine demuxes its track list asynchronously, so
    ///   this no-ops until the tracks arrive via `onTracksChanged`, then applies.
    ///   When a native→Plozzigen swap was triggered by a manual image-subtitle
    ///   pick, the picked provider track is attribute-matched to the equivalent
    ///   engine track here instead of applying the load-time default.
    private func applyInitialSubtitleSelectionIfReady(for request: PlaybackRequest) {
        guard !initialSubtitleApplied else { return }
        switch currentEngineKind {
        case .native:
            // engine.subtitleTracks == request.subtitleTracks for the native
            // engine; both share the provider id space selectSubtitleOption uses.
            initialSubtitleApplied = true
            applyDefaultSubtitleThroughOverlay(from: request.subtitleTracks)
        case .plozzigen:
            // AetherEngine reports tracks (with its own index id space) only after
            // demux; wait for them rather than applying against an empty list.
            let tracks = engine.subtitleTracks
            guard !tracks.isEmpty else { return }
            initialSubtitleApplied = true
            // A native→Plozzigen swap for a manually-picked image subtitle carries
            // the chosen provider track here; select its engine-side equivalent
            // (matched by language/forced/SDH) instead of the load-time default.
            if let picked = pendingImageSubtitleMatch {
                pendingImageSubtitleMatch = nil
                if let match = bestEngineSubtitleMatch(for: picked, in: tracks) {
                    selectSubtitleOption(id: match.id, userInitiated: false)
                    return
                }
                // No confident match — fall through to the default rule rather
                // than selecting a wrong-language track.
            }
            applyDefaultSubtitleThroughOverlay(from: tracks)
        default:
            initialSubtitleApplied = true
        }
    }

    /// Finds the engine subtitle track that best corresponds to a provider track
    /// the viewer picked, across the two disjoint id-spaces (provider stream index
    /// vs Plozzigen FFmpeg AVStream index). Requires a language match (when the
    /// provider track has a language) so a mismatch never silently swaps in the
    /// wrong subtitle; breaks ties on forced / hearing-impaired / image-based
    /// agreement. Returns `nil` when nothing confidently matches.
    private func bestEngineSubtitleMatch(for provider: MediaTrack, in engineTracks: [MediaTrack]) -> MediaTrack? {
        let candidates: [MediaTrack]
        if provider.language != nil {
            candidates = engineTracks.filter { LanguageMatch.matches($0.language, provider.language) }
        } else {
            candidates = engineTracks
        }
        guard !candidates.isEmpty else { return nil }
        func score(_ track: MediaTrack) -> Int {
            var s = 0
            if track.isForced == provider.isForced { s += 2 }
            if track.isHearingImpaired == provider.isHearingImpaired { s += 1 }
            if track.isBitmapSubtitle == provider.isBitmapSubtitle { s += 1 }
            return s
        }
        guard let best = candidates.max(by: { score($0) < score($1) }) else { return nil }
        // Require an unambiguous winner: if two or more candidates tie on the top
        // score we can't tell which subtitle the viewer meant, so decline rather
        // than swap in an arbitrary one.
        let topScore = score(best)
        guard candidates.filter({ score($0) == topScore }).count == 1 else { return nil }
        return best
    }

    /// Picks the default subtitle for the user's mode + preferred language from
    /// `tracks` and routes it through the overlay via `selectSubtitleOption`, or
    /// clears subtitles when there is no default text track. Image-based defaults
    /// are skipped here (they were routed to the hybrid engine at resolve time and
    /// that engine draws them); routing them through the overlay arrives with the
    /// bitmap-cue work.
    private func applyDefaultSubtitleThroughOverlay(from tracks: [MediaTrack]) {
        // A remembered per-series subtitle decision overrides the default rule.
        if let remembered = request.map({ rememberedSubtitle(for: $0.item) }) ?? nil {
            switch remembered {
            case .off:
                engine.selectSubtitleTrack(nil)
                clearOverlaySubtitle()
                selectedSubtitleTrackID = nil
                loadTrackOptions()
                return
            case .language(let language):
                // Honor the remembered language explicitly (mode `.all`, since the
                // viewer chose to see this language for the show), but only when a
                // matching, renderable text track exists; otherwise fall through to
                // the default rule.
                if tracks.hasSuitableSubtitle(forLanguage: language),
                   let chosen = tracks.defaultSubtitleSelection(mode: .all, preferredLanguage: language),
                   !chosen.isImageBasedSubtitle {
                    selectSubtitleOption(id: chosen.id, userInitiated: false)
                    return
                }
            }
        }

        let rule = request.map { effectiveSubtitleRule(for: $0.item) }
        let chosen = tracks.defaultSubtitleSelection(
            mode: rule?.mode ?? behavior.subtitleMode,
            preferredLanguage: rule?.preferredLanguage ?? behavior.resolvedPreferredLanguage
        )
        guard let chosen, !chosen.isImageBasedSubtitle else {
            engine.selectSubtitleTrack(nil)
            clearOverlaySubtitle()
            selectedSubtitleTrackID = nil
            loadTrackOptions()
            return
        }
        selectSubtitleOption(id: chosen.id, userInitiated: false)
    }

    /// Selects a subtitle track, or turns subtitles off (`PlayerTrackOption.offID`).
    /// `userInitiated` is `true` for a real menu pick (which is remembered for the
    /// series) and `false` for the programmatic load-time default.
    #if DEBUG
    /// Composes the DEBUG primary-subtitle route readout shown at the bottom of
    /// the Subtitles list: active engine, the routing path taken, and (when known)
    /// the cue count. Lets us classify a non-drawing Plex track without device logs.
    private func setPrimarySubtitleDiagnostic(route: String, cues: Int? = nil) {
        var text = "eng \(currentEngineKind) · \(route)"
        if let cues { text += " · \(cues) cues" }
        controls.primarySubtitleDiagnostic = text
    }
    #endif

    public func selectSubtitleOption(id: Int, userInitiated: Bool = true) {
        if userInitiated { viewerChangedSubtitleThisSession = true }
        if id == PlayerTrackOption.offID {
            if userInitiated { recordSeriesSubtitleSelection(.off) }
            engine.selectSubtitleTrack(nil)
            clearOverlaySubtitle()
            selectedSubtitleTrackID = nil
            #if DEBUG
            controls.primarySubtitleDiagnostic = ""
            #endif
            loadTrackOptions()
            return
        }
        guard let track = engine.subtitleTracks.first(where: { $0.id == id }) else { return }
        if userInitiated { recordSeriesSubtitleSelection(track.language.map(RememberedSubtitleSelection.language)) }

        // Image-based subtitles (PGS/DVB/DVD/VOBSUB) can't be rendered by AVPlayer.
        // If the user picks one while on the native engine, swap to Plozzigen
        // (AetherEngine) at the current position: it decodes the bitmap subtitle
        // packets into image cues that Plozz's overlay draws at their authored
        // position — no server burn-in. Key off `isImageBasedSubtitle` — NOT
        // `deliveryURL == nil` — so an embedded text SRT (no sidecar URL, but
        // renderable) stays on the native engine.
        if track.isImageBasedSubtitle, currentEngineKind == .native,
           let request, !request.isTranscoding, engineFactory.plozzigenAvailable {
            clearOverlaySubtitle()
            selectedSubtitleTrackID = id
            Task { await swapEngineForImageSubtitle(track) }
            return
        }

        // Text subtitle on the native engine. With a sidecar URL we render it
        // through Plozz's own overlay (styling, HDR luminance, live offset all
        // apply), suppressing AVPlayer's legible draw. WITHOUT a sidecar URL
        // (embedded text track, e.g. an MKV SRT on Plex direct-play) the overlay
        // has no cue source, so we let AVPlayer draw the track natively rather
        // than suppressing it and showing nothing — routing embedded text through
        // the overlay is a later Plozzigen-extraction task.
        if !track.isImageBasedSubtitle, currentEngineKind == .native {
            selectedSubtitleTrackID = id
            if track.deliveryURL != nil {
                engine.selectSubtitleTrack(nil)
                #if DEBUG
                setPrimarySubtitleDiagnostic(route: "overlay")
                #endif
                loadOverlaySubtitle(track)
            } else {
                clearOverlaySubtitle()
                engine.selectSubtitleTrack(track)
                #if DEBUG
                setPrimarySubtitleDiagnostic(route: "avplayer-draw")
                #endif
            }
            loadTrackOptions()
            return
        }

        // Plozzigen (AetherEngine) decodes the selected subtitle and publishes its
        // active cues; route them through Plozz's owned overlay (live-feed mode)
        // so text *and* bitmap subs draw on the same SDR renderer as native. The
        // `onSubtitleCues` callback (wired in configureEngineCallbacks) does the
        // feeding. Other engines that draw their own subs (Plozzigen) get an empty live
        // feed and keep drawing themselves — harmless.
        subtitleCueLoadTask?.cancel()
        subtitleCueLoadTask = nil
        liveSubtitles.beginLiveFeed()
        refreshSubtitleDelayAvailability()
        engine.selectSubtitleTrack(track)
        selectedSubtitleTrackID = id
        #if DEBUG
        setPrimarySubtitleDiagnostic(route: "live-feed")
        #endif
        loadTrackOptions()
    }

    /// Cancels any in-flight cue fetch and clears the **primary** overlay
    /// (subtitles off, or switching to an engine that draws its own). Leaves the
    /// secondary/dual line untouched — it's an independent overlay stream.
    private func clearOverlaySubtitle() {
        subtitleCueLoadTask?.cancel()
        subtitleCueLoadTask = nil
        liveSubtitles.loadPrimary(nil)
        refreshSubtitleDelayAvailability()
    }

    /// Fetches the selected text sidecar, parses it to cues off the main actor,
    /// and loads it into the overlay — unless the selection changed mid-fetch.
    /// Best-effort: a failure simply leaves no overlay cues rather than wedging.
    private func loadOverlaySubtitle(_ track: MediaTrack) {
        subtitleCueLoadTask?.cancel()
        // Clear only the primary stream; a selected dual/secondary line survives a
        // primary track change.
        liveSubtitles.loadPrimary(nil)
        refreshSubtitleDelayAvailability()
        guard let url = track.deliveryURL else {
            // Embedded text without a sidecar URL: container extraction arrives
            // with the Plozzigen cue path; leave nothing showing until then.
            PlozzLog.playback.debug("Selected subtitle has no sidecar URL; overlay not loaded")
            return
        }
        let id = track.id
        let language = track.language
        let title = track.displayTitle
        let forced = track.isForced
        // Only spend a detection pass when the provider gave us no language tag
        // and we haven't already guessed one for this track this session.
        let needsDetection = (language == nil) && detectedSubtitleLanguages[id] == nil
        subtitleCueLoadTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                try Task.checkCancellation()
                guard let text = SubtitleCueParser.decodeText(data) else {
                    PlozzLog.playback.error("Subtitle sidecar decode failed (\(data.count) bytes); unknown text encoding")
                    await MainActor.run { [weak self] in
                        guard let self, self.selectedSubtitleTrackID == id else { return }
                        #if DEBUG
                        self.setPrimarySubtitleDiagnostic(route: "overlay · decode-fail")
                        #endif
                    }
                    return
                }
                let stream = SubtitleCueParser.parse(
                    text, id: id, language: language, title: title,
                    sourceTrackID: id, isForced: forced
                )
                try Task.checkCancellation()
                let detected = needsDetection ? Self.detectLanguage(in: stream.cues) : nil
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    let storedNew = detected != nil && self.detectedSubtitleLanguages[id] == nil
                    if let detected, storedNew { self.detectedSubtitleLanguages[id] = detected }
                    if self.selectedSubtitleTrackID == id {
                        self.liveSubtitles.loadPrimary(stream)
                        self.refreshSubtitleDelayAvailability()
                        #if DEBUG
                        self.setPrimarySubtitleDiagnostic(route: "overlay", cues: stream.cues.count)
                        #endif
                    }
                    // A fresh guess changes a track's menu label, so rebuild.
                    if storedNew { self.loadTrackOptions() }
                }
            } catch is CancellationError {
                // Selection changed; the newer selection owns the overlay.
            } catch {
                PlozzLog.playback.debug("Overlay subtitle fetch failed (non-fatal)")
                await MainActor.run { [weak self] in
                    guard let self, self.selectedSubtitleTrackID == id else { return }
                    #if DEBUG
                    self.setPrimarySubtitleDiagnostic(route: "overlay · fetch-fail")
                    #endif
                }
            }
        }
    }

    // MARK: - Dual (secondary) subtitle

    /// The tracks a second subtitle line can show. Sourced from the PROVIDER's
    /// subtitle probe (`request.subtitleTracks`), not the engine's demuxed tracks,
    /// because the overlay fetches + parses the sidecar itself and only the provider
    /// reliably carries a text sub's VTT `deliveryURL` — the advanced engine's
    /// embedded-text tracks have none, and their ids may not even line up with the
    /// provider's (which is why matching by id showed "None available"). Every
    /// non-image text track Jellyfin exposes is therefore eligible; the current
    /// primary is dropped when its id matches.
    ///
    /// Bitmap (PGS/DVD/DVB/VOBSUB) tracks are **never** eligible as a second line:
    /// the dual layout stacks two *repositionable text* lines (the secondary has an
    /// Above/Below placement), but a bitmap cue is drawn at its own authored
    /// on-frame position that we can't move — a PGS "second line" would collide
    /// with the primary instead of stacking. And when the **primary** itself is a
    /// bitmap subtitle, dual mode is disabled entirely (no eligible seconds), since
    /// the overlay can't know where the primary bitmap will land to place a line
    /// clear of it.
    private func eligibleSecondarySubtitleTracks() -> [MediaTrack] {
        // Dual mode needs a positionable primary to stack a second line against; a
        // bitmap primary (PGS/DVD/DVB) has an uncontrollable authored position, so
        // offer no seconds at all — the picker reads "None available".
        if let primaryID = selectedSubtitleTrackID,
           let primary = engine.subtitleTracks.first(where: { $0.id == primaryID })
            ?? request?.subtitleTracks.first(where: { $0.id == primaryID }),
           primary.isBitmapSubtitle {
            #if DEBUG
            PlozzLog.playback.debug("Secondary disabled: primary subtitle is bitmap (\(primary.codec ?? "?"))")
            #endif
            return []
        }
        // Engines that decode a second subtitle stream themselves (Plozzigen)
        // source the dual picker from the ENGINE's own tracks (FFmpeg AVStream
        // ids), so embedded tracks with no fetchable sidecar URL are selectable —
        // the engine demuxes them. Include every subtitle track except the current
        // primary (the viewer asked to be able to pick "all of them") and any
        // bitmap track (can't be positioned as a second line); the exclude keys off
        // the same engine id-space as `selectedSubtitleTrackID`.
        if engine.capabilities.contains(.dualSubtitleDecode) {
            let engineSubs = engine.subtitleTracks
            let eligible = engineSubs.filter { $0.id != selectedSubtitleTrackID && !$0.isBitmapSubtitle }
            #if DEBUG
            PlozzLog.playback.debug(
                "Secondary eligible (engine-dual): \(eligible.count) of \(engineSubs.count) engine subs (primary id \(self.selectedSubtitleTrackID.map(String.init) ?? "off"))"
            )
            #endif
            return eligible
        }
        // Sidecar path (native): the second line renders through Plozz's overlay
        // from a parsed VTT, so only text tracks with a fetchable URL, excluding the
        // primary, qualify. (`isBitmapSubtitle` is redundant with the text-URL
        // requirement here but kept for symmetry / defence in depth.)
        let providerSubs = request?.subtitleTracks ?? []
        let eligible = providerSubs.filter {
            !$0.isBitmapSubtitle && $0.deliveryURL != nil && $0.id != selectedSubtitleTrackID
        }
        #if DEBUG
        PlozzLog.playback.debug(
            "Secondary eligible: \(eligible.count) of \(providerSubs.count) provider subs (primary id \(self.selectedSubtitleTrackID.map(String.init) ?? "off"))"
        )
        #endif
        return eligible
    }

    /// Selects the second (dual) subtitle track, or turns the second line off
    /// (`PlayerTrackOption.offID`). The secondary always renders through Plozz's
    /// overlay, so only text tracks with a sidecar URL are eligible. Picking a
    /// track also enables the secondary *styling* (`style.secondary`) so the
    /// overlay actually draws the line; turning it off clears both.
    public func selectSecondarySubtitleOption(id: Int) {
        let engineDual = engine.capabilities.contains(.dualSubtitleDecode)
        if id == PlayerTrackOption.offID {
            secondaryCueLoadTask?.cancel()
            secondaryCueLoadTask = nil
            selectedSecondarySubtitleTrackID = nil
            if engineDual {
                // Tell the engine to stop decoding the second stream, then drop the
                // live-fed cues. `loadSecondary(nil)` also flips the model out of
                // secondary-live mode and empties the second line.
                engine.selectSecondarySubtitleTrack(nil)
            }
            liveSubtitles.loadSecondary(nil)
            controls.secondarySubtitleStatus = .idle
            if style.secondary != nil {
                var cleared = style
                cleared.secondary = nil
                applySubtitleStyle(cleared)
            }
            loadTrackOptions()
            return
        }
        guard let track = eligibleSecondarySubtitleTracks().first(where: { $0.id == id }) else { return }
        selectedSecondarySubtitleTrackID = id
        controls.secondarySubtitleStatus = .loading
        // The overlay only draws the second line when `style.secondary` exists;
        // seed a default (which inherits the primary look) if the viewer hasn't
        // styled one yet.
        if style.secondary == nil {
            var enabled = style
            enabled.secondary = SubtitleStyle.Secondary()
            applySubtitleStyle(enabled)
        }
        if engineDual {
            // Engine decodes the embedded second track itself and publishes its
            // cues via `onSecondarySubtitleCues` (wired in configureEngineCallbacks),
            // which the model draws through secondary-live mode. This is what makes
            // dual subtitles work for tracks with no fetchable sidecar URL (Plex
            // direct-play MKV). Status flips to `.loaded` when the first cues land.
            secondaryCueLoadTask?.cancel()
            secondaryCueLoadTask = nil
            liveSubtitles.beginSecondaryLiveFeed()
            engine.selectSecondarySubtitleTrack(track)
        } else {
            loadSecondaryOverlaySubtitle(track)
        }
        loadTrackOptions()
    }

    /// Fetches + parses the secondary sidecar off the main actor and loads it into
    /// the overlay's secondary stream, unless the secondary selection changed
    /// mid-fetch. Mirrors ``loadOverlaySubtitle(_:)`` but never touches the
    /// primary. Publishes a load status (`controls.secondarySubtitleStatus`) so the
    /// picker row can show loading / cue count / unavailable. Best-effort: a
    /// failure just leaves the second line empty.
    private func loadSecondaryOverlaySubtitle(_ track: MediaTrack) {
        secondaryCueLoadTask?.cancel()
        liveSubtitles.loadSecondary(nil)
        guard let url = track.deliveryURL else {
            controls.secondarySubtitleStatus = .unavailable
            return
        }
        controls.secondarySubtitleStatus = .loading
        let id = track.id
        let language = track.language
        let title = track.displayTitle
        let forced = track.isForced
        secondaryCueLoadTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                try Task.checkCancellation()
                guard let text = SubtitleCueParser.decodeText(data) else {
                    PlozzLog.playback.error("Secondary subtitle sidecar decode failed (\(data.count) bytes)")
                    await MainActor.run { [weak self] in
                        guard let self, self.selectedSecondarySubtitleTrackID == id else { return }
                        self.controls.secondarySubtitleStatus = .unavailable
                    }
                    return
                }
                let stream = SubtitleCueParser.parse(
                    text, id: id, language: language, title: title,
                    sourceTrackID: id, isForced: forced
                )
                try Task.checkCancellation()
                #if DEBUG
                let range = stream.cues.isEmpty
                    ? "none"
                    : "\(Int(stream.cues.first!.start))s–\(Int(stream.cues.last!.end))s"
                PlozzLog.playback.debug(
                    "Secondary track \(id): fetched \(data.count) bytes → \(stream.cues.count) cues (\(range))"
                )
                #endif
                await MainActor.run { [weak self] in
                    guard let self, self.selectedSecondarySubtitleTrackID == id else { return }
                    self.liveSubtitles.loadSecondary(stream)
                    self.controls.secondarySubtitleStatus = .loaded(cueCount: stream.cues.count)
                }
            } catch is CancellationError {
                // Selection changed; the newer secondary owns the stream.
            } catch {
                PlozzLog.playback.debug("Secondary track \(id) sidecar fetch failed (non-fatal): \(error.localizedDescription)")
                await MainActor.run { [weak self] in
                    guard let self, self.selectedSecondarySubtitleTrackID == id else { return }
                    self.controls.secondarySubtitleStatus = .unavailable
                }
            }
        }
    }

    /// Best-effort on-device language guess for an untagged text subtitle, from a
    /// sample of its parsed cue text. Runs off the main actor (`nonisolated`).
    /// Returns a BCP-47-ish code (e.g. `en`, `es`, `zh-Hans`) or `nil` when there
    /// isn't enough text to be confident. Bitmap cues have no `text`, so they
    /// naturally yield `nil` (they need OCR, out of scope here).
    private nonisolated static func detectLanguage(in cues: [SubtitleCue]) -> String? {
        #if canImport(NaturalLanguage)
        var sample = ""
        for cue in cues {
            guard let line = cue.text, !line.isEmpty else { continue }
            sample += line
            sample += "\n"
            if sample.count > 4000 { break }
        }
        let trimmed = sample.trimmingCharacters(in: .whitespacesAndNewlines)
        // Too little text to classify reliably — don't risk a wrong label.
        guard trimmed.count >= 24 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        guard let language = recognizer.dominantLanguage, language != .undetermined else { return nil }
        return language.rawValue
        #else
        return nil
        #endif
    }

    /// Swaps from the native engine to Plozzigen (preserving position) so an
    /// image-based subtitle the user manually selected can be decoded and drawn
    /// on-device. Plozzigen demuxes its tracks asynchronously with its own
    /// id-space, so the actual selection is deferred: `pendingImageSubtitleMatch`
    /// carries the picked provider track and `applyInitialSubtitleSelectionIfReady`
    /// attribute-matches it once the engine's track list arrives.
    private func swapEngineForImageSubtitle(_ track: MediaTrack) async {
        guard let request else { return }
        let resume = max(engine.furthestObservedPosition, engine.currentTime)
        pendingImageSubtitleMatch = track
        await playResolved(request, engineKind: .plozzigen, startPosition: resume > 1 ? resume : 0)
        loadTrackOptions()
    }

    // MARK: - Auto subtitle download

    /// If auto-download is enabled and the item lacks a suitable subtitle in the
    /// preferred language, kicks off a detached background search+download so the
    /// server fetches one. Never blocks or affects the current playback session.
    private func startAutoSubtitleDownloadIfNeeded(request: PlaybackRequest) {
        // Per-content-type rule decides whether to auto-download, the language to
        // fetch, and forced-vs-full preference — so "auto-download a missing match
        // for anime only" works. For un-overridden categories the rule already
        // mirrors the caption base (`autoDownloadSubtitles`), so gate solely on the
        // resolved rule: ORing the global flag back in would make a category
        // override that sets `autoDownloadIfMissing: false` (e.g. movies) unable to
        // turn the behaviour off while the profile-wide toggle is on.
        let rule = effectiveSubtitleRule(for: request.item)
        // No point fetching a subtitle the viewer won't see: "Off" suppresses the
        // background download just as it suppresses the on-load selection.
        guard rule.mode != .off, rule.autoDownloadIfMissing else { return }
        let language = rule.preferredLanguage ?? behavior.resolvedPreferredLanguage
        guard !request.subtitleTracks.hasSuitableSubtitle(forLanguage: language) else { return }
        guard let language, !language.isEmpty else { return }

        let provider = self.provider
        let itemID = self.itemID
        let mode = rule.mode
        subtitleDownloadTask = Task.detached(priority: .background) {
            do {
                let results = try await provider.remoteSubtitleSearch(itemID: itemID, language: language)
                guard let best = results.bestMatch(forLanguage: language, mode: mode), !best.id.isEmpty else {
                    return
                }
                try await provider.downloadRemoteSubtitle(itemID: itemID, subtitleID: best.id)
                PlozzLog.playback.info("Auto-downloaded subtitle for item")
            } catch {
                PlozzLog.playback.debug("Auto subtitle download failed (non-fatal)")
            }
        }
    }
}

#endif
