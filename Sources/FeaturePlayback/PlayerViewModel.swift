#if canImport(AVFoundation)
import Foundation
import AVFoundation
import Observation
import CoreModels
import CoreNetworking
import TraktService
import MetadataKit
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
        /// Authoritative header-probed range for an upcoming direct file. Used
        /// only to decide whether identical criteria can survive the handoff.
        public let prefetchedDynamicRange: SourceDynamicRange?
        public let inheritedPreservedDynamicRange: SourceDynamicRange?
        public init(
            itemID: String,
            request: PlaybackRequest,
            engineKind: PlaybackEngineKind,
            prefetchedDynamicRange: SourceDynamicRange? = nil,
            inheritedPreservedDynamicRange: SourceDynamicRange? = nil
        ) {
            self.itemID = itemID
            self.request = request
            self.engineKind = engineKind
            self.prefetchedDynamicRange = prefetchedDynamicRange
            self.inheritedPreservedDynamicRange = inheritedPreservedDynamicRange
        }

        public func withPrefetchedDynamicRange(
            _ range: SourceDynamicRange?
        ) -> Self {
            Self(
                itemID: itemID,
                request: request,
                engineKind: engineKind,
                prefetchedDynamicRange: range,
                inheritedPreservedDynamicRange: inheritedPreservedDynamicRange
            )
        }

        public func inheritingPreservedDisplayMode(_ inherits: Bool) -> Self {
            Self(
                itemID: itemID,
                request: request,
                engineKind: engineKind,
                prefetchedDynamicRange: prefetchedDynamicRange,
                inheritedPreservedDynamicRange: inherits ? handoffRange : nil
            )
        }

        public var handoffRange: SourceDynamicRange? {
            prefetchedDynamicRange
                ?? SourceDynamicRange.providerHint(from: request.sourceMetadata)
        }
    }

    /// True from bring-up until the engine is genuinely presenting moving frames.
    /// While it's set (and we're not in `.failed`), the bring-up spinner stays up,
    /// so the viewer sees ONE continuous loading indicator from tap → first frame
    /// instead of a spinner that vanishes the instant `engine.load()` returns and
    /// then a black gap / second in-player spinner while the picture actually
    /// Driven by ``NextEpisodeCoordinator/beginAwaitingFirstFrame(resumeClock:)``.
    public var awaitingFirstFrame: Bool { nextEpisodeCoordinator.awaitingFirstFrame }

    /// Whether the full-screen bring-up spinner should be shown: while resolving/
    /// loading, and while `.ready` but the first frame hasn't been presented yet.
    /// Off once frames advance (or on failure). Lets the view keep a single
    /// spinner across the `.loading` → `.ready` boundary.
    public var showBringUpSpinner: Bool {
        switch phase {
        case .loading: return true
        case .ready: return awaitingFirstFrame || isRecoveringAfterForeground
        case .failed: return false
        }
    }

    /// Set to `true` when playback reaches its natural end *and* this player was
    /// configured to auto-dismiss on completion (currently trailers). The view
    /// observes this and dismisses itself. Ignored for regular library playback,
    /// which keeps the finished frame on screen as before.
    public private(set) var shouldDismiss = false

    /// Best available source range for this playback. Provider metadata is only
    /// an early hint for Plozzigen; its demux probe replaces it authoritatively.
    /// Native AVPlayer keeps its historical metadata-or-SDR behavior.
    public private(set) var effectiveDynamicRange: EffectiveDynamicRange =
        .native(metadata: nil)

    /// Range whose Plozzigen criteria intentionally remain applied across this
    /// probe (same-range handoff or fresh-engine retry). A matching probe needs no
    /// settle callback; a correction still waits behind black for the real switch.
    public private(set) var inheritedPreservedDynamicRange: SourceDynamicRange?
    public var inheritsPreservedDisplayMode: Bool {
        inheritedPreservedDynamicRange != nil
    }

    /// Changes for every load even when two consecutive loads have the same
    /// pending-range value, allowing the view to restart its pre-probe veil.
    public private(set) var dynamicRangeTransitionToken = UUID()

    /// A pending Plozzigen probe is conservatively veiled on exit because the
    /// engine may already have begun a display switch before publishing facts.
    var requiresHDRExitVeil: Bool {
        effectiveDynamicRange.isAwaitingEngineProbe
            || (effectiveDynamicRange.bestAvailable?.isHDR ?? false)
    }

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
    /// Owns the subtitle-overlay cue-load pipeline (primary + secondary sidecar
    /// fetch/parse/apply and their one-at-a-time task lifecycle). Set at the end of
    /// `init`; the view model keeps ownership of subtitle *selection* and drives
    /// this collaborator to (re)load or clear the overlay streams.
    @ObservationIgnored private var subtitleOverlay: SubtitleOverlayLoader!

    private let provider: any MediaProvider
    /// Optional offline-download seam. When it reports a completed local copy for
    /// the item, `resolveAndRoute` rewrites the request to play that `file://`
    /// asset. `nil` (the default) makes offline resolution a strict no-op.
    private let offlinePlaybackResolver: (any OfflinePlaybackResolving)?
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
    /// Owns per-profile per-series audio/subtitle memory (key derivation, gated
    /// reads/writes, cross-server reconciliation). Constructed from the injected
    /// store, fallback account id, and the profile toggles; a `nil` store disables
    /// the feature (tests, previews).
    private let seriesMemory: SeriesTrackMemory
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
    let authenticatedHTTPResolver:
        (any AuthenticatedHTTPResourceResolving)?
    /// Device/display/audio policy the router uses to pick an engine.
    private let capabilities: MediaCapabilities

    /// Owns the active engine instance and everything about swapping it:
    /// construction, the re-host token, the stall watchdog, and the cross-engine
    /// failure fallback chain. Built at the end of `init` (needs `self` as host).
    @ObservationIgnored private var engineHandoff: EngineHandoffCoordinator!

    /// The active engine. Owned by ``engineHandoff``; read here through a thin
    /// forwarder so the rest of the view model is unchanged.
    private var engine: any VideoEngine { engineHandoff.engine }
    /// Which engine ``engine`` currently is, so swaps know the alternate. Owned by
    /// ``engineHandoff``; read here through a thin forwarder.
    private var currentEngineKind: PlaybackEngineKind { engineHandoff.currentEngineKind }
    /// Bumped whenever ``engine`` is swapped, so the SwiftUI player re-hosts the
    /// new engine's bare video surface (`.id(engineToken)`). Owned by
    /// ``engineHandoff``; read here through a thin forwarder.
    public var engineToken: UUID { engineHandoff.engineToken }
    /// Fences probe updates when the same engine instance is asked to load a new
    /// request. Engine swaps are additionally fenced by `engineToken`.
    private var dynamicRangeLoadGeneration: UInt = 0
    /// Run-loop yield that lets SwiftUI paint the pre-probe veil before an engine
    /// swap. Internal so lifecycle tests can suspend this exact race window.
    @ObservationIgnored var preEngineCommitYield:
        @MainActor @Sendable () async -> Void = {
            await PlayerViewModel.yieldToRunLoop()
        }

    /// Bumped the moment a request resolves and the engine is committed (before
    /// the engine's `load()` is even awaited), so the diagnostics overlay can
    /// populate its Engine / Source / codec rows during loading and on failure —
    /// not just once playback reaches `.ready`. Lets the user see *why* a file is
    /// stuck instead of an opaque spinner.
    public private(set) var diagnosticsToken = UUID()

    private var request: PlaybackRequest?
    /// Owns manual + automatic remote-subtitle acquisition (search / download /
    /// post-download poll). Set at the end of `init` (needs `self` as its host).
    private var subtitleAcquisition: RemoteSubtitleAcquisition!
    /// Owns the in-player audio/subtitle **track selection** state machine (menu
    /// building, per-pick routing across engines/id-spaces, load-time default,
    /// dual line, hot-loaded downloads). Built at the end of `init`.
    @ObservationIgnored private var subtitleController: SubtitleTrackController!

    /// Seek pipeline (request coalescing, deferred commit debounce, drain loop,
    /// post-seek resume confirmation). Owned by a dedicated collaborator so the
    /// fragile `isSeeking` clear-on-return and `intendsPause` phantom-`.playing`
    /// gate live in one testable place. The view model forwards `requestSeek` /
    /// `seek(to:)` to it and drives its teardown from `stop()`.
    private var seekCoordinator: SeekScrubCoordinator!

    /// The single source of truth for "should the video be playing right now",
    /// driven ONLY by genuine play/pause commands via `setPaused`. Unlike
    /// `engine.isPaused` / `controls.isPaused`, it is never written by the engine
    /// state mirror, so it stays correct even while the engine transiently
    /// settles to rate-0 after a seek. All post-seek resume and transport
    /// decisions key off this, not the (mirror-polluted) paused flags. Defaults
    /// true because load auto-plays.
    private var intendsPlayback = true

    /// Keeps the existing full-screen loading indicator visible while a suspended
    /// engine rebuilds its media pipeline at the preserved position. Owned by
    /// ``ForegroundReloadCoordinator``; forwarded so `showBringUpSpinner` reads it.
    public var isRecoveringAfterForeground: Bool { foregroundReload.isRecovering }

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
    /// this episode so the hand-off is near-instant. Owned by
    /// ``nextEpisodeCoordinator``; surfaced here for the hand-off callers.
    public var prefetchedNext: PrefetchedPlayback? { nextEpisodeCoordinator.prefetchedNext }

    /// A prefetched playback injected at init by the OUTGOING episode's player, to
    /// be adopted by ``startPlayback`` instead of re-resolving over the network.
    private var adoptedResolved: PrefetchedPlayback?
    private var pendingPreservedDynamicRange: SourceDynamicRange?

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

    /// Owns progress reporting (provider + Trakt lifecycle fan-out) and the
    /// periodic convergence-checkpoint loop. Set at the end of `init` (needs
    /// `self` as its host). Driven from playback start / setPaused / stop / the
    /// engine progress callback / background lifecycle.
    private var progressReporter: WatchProgressReporter!

    /// Owns the fast-hand-off next-episode machinery: the one-shot next-episode
    /// prefetch (eager for idempotent providers, windowed for Jellyfin), the
    /// spoiler-aware Up Next card, and the single bring-up first-frame gate. Set
    /// at the end of `init` (needs `self` as its host).
    private var nextEpisodeCoordinator: NextEpisodeCoordinator!

    /// Owns the background → foreground lifecycle reconciliation (generation
    /// bookkeeping + engine rebuild + paused-state restore). Set at the end of
    /// `init` (needs `self` as its host). Not `@ObservationIgnored` so
    /// `isRecoveringAfterForeground` observes its `isRecovering` for the spinner.
    private var foregroundReload: ForegroundReloadCoordinator!

    /// Optional playback bring-up started eagerly in `init` so the (network-bound)
    /// `playbackInfo` resolution and engine warm-up overlap the SwiftUI fullscreen
    /// navigation transition instead of starting only once the view appears. The
    /// view's `load()` adopts (awaits) this task rather than starting a second
    /// bring-up; `stop()` cancels it so a Back during the transition tears down
    /// cleanly via the cancellation checks in `startPlayback`.
    private var prefetchTask: Task<Void, Never>?
    /// When the current bring-up began, for hand-off latency telemetry
    /// (``HandoffDiagnostics``). `nil` until ``startPlayback`` runs.
    private var bringUpStartedAt: Date?
    private var enrichTask: Task<Void, Never>?

    public init(
        provider: any MediaProvider,
        itemID: String,
        mediaSourceID: String? = nil,
        offlinePlaybackResolver: (any OfflinePlaybackResolving)? = nil,
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
        authenticatedHTTPResolver:
            (any AuthenticatedHTTPResourceResolving)? = nil,
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
        self.offlinePlaybackResolver = offlinePlaybackResolver
        self.itemID = itemID
        self.mediaSourceID = mediaSourceID
        self.behavior = behavior
        self.style = style
        self.subtitlePolicy = subtitlePolicy ?? .inheriting(from: behavior)
        self.audioPolicy = audioPolicy ?? .inheriting(from: playbackSettings)
        self.playbackSettings = playbackSettings
        self.spoilerSettings = spoilerSettings
        self.seriesMemory = SeriesTrackMemory(
            store: seriesTrackStore,
            accountFallbackID: seriesAccountFallbackID,
            rememberAudio: playbackSettings.rememberAudioTrackPerSeries,
            rememberSubtitle: playbackSettings.rememberSubtitleTrackPerSeries
        )
        self.startPositionOverride = startPosition
        self.scrobbler = scrobbler
        self.engineFactory = engineFactory
        self.authenticatedHTTPResolver = authenticatedHTTPResolver
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
        self.pendingPreservedDynamicRange =
            adoptedResolved?.inheritedPreservedDynamicRange
        // The adopted-prefetch engine boot (skip the native→Plozzigen swap) lives
        // in ``EngineHandoffCoordinator``'s init, built at the end of this init.
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
        // Gate the "Search for subtitles…" row on server-proxied support.
        self.controls.canSearchRemoteSubtitles = (provider as? CapabilityReporting)?.capabilities.contains(.remoteSubtitles) ?? false
        self.subtitleAcquisition = RemoteSubtitleAcquisition(provider: provider, itemID: itemID, host: self)
        self.subtitleOverlay = SubtitleOverlayLoader(host: self)
        self.subtitleController = SubtitleTrackController(host: self)
        self.seekCoordinator = SeekScrubCoordinator(host: self, controls: controls)
        self.progressReporter = WatchProgressReporter(
            host: self,
            provider: provider,
            itemID: itemID,
            scrobbler: scrobbler,
            checkpointInterval: checkpointInterval,
            onCheckpoint: onPlaybackCheckpoint
        )
        self.nextEpisodeCoordinator = NextEpisodeCoordinator(
            host: self,
            controls: controls,
            playbackSettings: playbackSettings,
            spoilerSettings: spoilerSettings,
            engineFactory: engineFactory
        )
        self.foregroundReload = ForegroundReloadCoordinator(host: self)
        // Boot the engine the hand-off already resolved (adopted prefetch) or a
        // fresh native engine. Owning this in the coordinator keeps the "know the
        // engine before it even starts" path — no mid-bring-up native→Plozzigen
        // swap, one loading indicator — alongside the swap/watchdog/fallback it
        // drives later.
        self.engineHandoff = EngineHandoffCoordinator(
            host: self,
            engineFactory: engineFactory,
            adopted: adoptedResolved,
            initialStyle: style
        )
        configureEngineCallbacks()

        // Kick off bring-up now so playbackInfo + engine warm-up run *during* the
        // navigation transition. `load()` (from the view's `.task`) adopts this
        // task; `stop()` cancels it on an early Back.
        HandoffDiagnostics.emit(
            "viewModel INIT item=\(itemID) provider=\(provider.kind.rawValue)"
        )
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
        let callbackEngineToken = engineToken
        engine.onProgress = { [weak self] in
            guard let self, self.engineToken == callbackEngineToken else { return }
            // Jellyfin (non-idempotent) next-episode prefetch fires once the
            // hand-off window opens; idempotent providers prefetch eagerly instead.
            self.nextEpisodeCoordinator.maybeStartWindowedNextPrefetch()
            self.nextEpisodeCoordinator.logUpNextStateIfNearEnd()
            self.progressReporter.reportProgress()
        }
        engine.onFailure = { [weak self] error in
            guard let self, self.engineToken == callbackEngineToken else { return }
            Task {
                await self.engineHandoff.handleEngineFailure(
                    error,
                    sourceEngineToken: callbackEngineToken
                )
            }
        }
        engine.onEnded = { [weak self] in
            guard let self, self.engineToken == callbackEngineToken else { return }
            self.handlePlaybackEnded()
        }
        // Engines that discover tracks asynchronously (Plozzigen) tell us to
        // rebuild the options menu once their lists arrive — otherwise the menu,
        // built once at playResolved, stays empty for the whole session. This is
        // also the moment Plozzigen's tracks first become known, so it's where we
        // route its load-time default subtitle through the overlay.
        engine.onTracksChanged = { [weak self] in
            guard let self, self.engineToken == callbackEngineToken else { return }
            self.subtitleController.loadTrackOptions()
            self.subtitleController.applyImportedAudioIfPossible()
            if let request = self.request {
                self.subtitleController.applyInitialSubtitleSelectionIfReady(for: request)
            }
        }
        // Engines that decode subtitles themselves (Plozzigen) push their active
        // cues here; the live overlay model draws them on the same SDR renderer as
        // native. Guarded by live-feed mode inside the model, so it's inert unless
        // a Plozzigen subtitle is actually selected.
        engine.onSubtitleCues = { [weak self] cues in
            guard let self, self.engineToken == callbackEngineToken else { return }
            self.liveSubtitles.updateLiveCues(cues)
            #if DEBUG
            if self.subtitleController.selectedSubtitleTrackID != nil {
                self.subtitleController.setPrimarySubtitleDiagnostic(route: "live-feed", cues: cues.count)
            }
            #endif
        }
        // Same as above but for the engine's SECONDARY (dual) subtitle stream. This
        // is the dual-subtitle path for embedded tracks that have no fetchable
        // sidecar URL (e.g. Plex direct-play MKV): AetherEngine/Plozzigen decodes
        // the second track itself and pushes its cues here. Inert unless
        // `beginSecondaryLiveFeed()` has been called (guarded inside the model).
        engine.onSecondarySubtitleCues = { [weak self] cues in
            guard let self, self.engineToken == callbackEngineToken else { return }
            self.liveSubtitles.updateSecondaryLiveCues(cues)
            if self.subtitleController.selectedSecondarySubtitleTrackID != nil {
                self.controls.secondarySubtitleStatus = .loaded(cueCount: cues.count)
            }
        }
    }

    private func configureSourceFactsCallback(loadGeneration: UInt) {
        let callbackEngineToken = engineToken
        engine.onProbedSourceFactsChanged = { [weak self] facts in
            guard let self,
                  self.engineToken == callbackEngineToken,
                  self.dynamicRangeLoadGeneration == loadGeneration,
                  !self.didStop else { return }
            self.applyEngineProbedSourceFacts(facts)
        }
    }

    private func applyEngineProbedSourceFacts(_ facts: EngineProbedSourceFacts) {
        effectiveDynamicRange = effectiveDynamicRange.applyingEngineProbe(facts)
        let isHDR = effectiveDynamicRange.bestAvailable?.isHDR ?? false
        liveSubtitles.isHDR = isHDR
        controls.subtitlesRenderHDR = isHDR
        HandoffDiagnostics.emit(
            "range AUTHORITATIVE value=\(effectiveDynamicRange.authoritativeRange?.rawValue ?? "unknown") "
                + "generation=\(dynamicRangeLoadGeneration) subtitlesHDR=\(isHDR)"
        )
        diagnosticsToken = UUID()
    }

    /// Called when the active engine reports a clean playthrough to the end of the
    /// stream. Auto-advances to the next episode when one is queued, otherwise
    /// dismisses so the player never freezes on the final frame: trailers/movies
    /// return to detail, a season finale returns to the series page.
    private func handlePlaybackEnded() {
        PlaybackTrace.note("handlePlaybackEnded curr=\(String(format: "%.2f", engine.currentTime)) furthest=\(String(format: "%.2f", engine.furthestObservedPosition)) dur=\(String(format: "%.2f", engine.duration)) hasNext=\(nextEpisode != nil) isSeeking=\(controls.isSeeking) isScrubbing=\(controls.isScrubbing) intendsPlayback=\(intendsPlayback)")
        didReachNaturalEnd = true
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
        guard !didStop else { return }
        previousEpisode = prev
        nextEpisode = next
        controls.hasPreviousEpisode = prev != nil
        controls.hasNextEpisode = next != nil
        nextEpisodeCoordinator.updateUpNextCard()
        // Eagerly prefetch the next episode's resolved stream when the provider's
        // `playbackInfo` is idempotent (Plex, SMB share) — safe to resolve the
        // moment it's known, for a near-instant hand-off. Jellyfin (a
        // session-minting POST) defers to the hand-off window instead; see
        // ``NextEpisodeCoordinator/maybeStartWindowedNextPrefetch(trigger:)``.
        if next != nil {
            if provider.kind.playbackInfoIsIdempotent {
                nextEpisodeCoordinator.startNextEpisodePrefetch(trigger: "eager")
            } else {
                // Playback may already be inside the hand-off window if neighbor
                // resolution completed after a seek/progress tick. Re-evaluate
                // here so that ordering cannot strand the prefetch until EOF.
                nextEpisodeCoordinator.maybeStartWindowedNextPrefetch(
                    trigger: "neighbor-windowed")
            }
        }
    }

    // MARK: - Next-episode hand-off (forwarders to NextEpisodeCoordinator)

    /// Hands the prefetched next-episode resolution to the incoming player.
    /// Returns `nil` when there's no prefetch or it doesn't match `itemID` (the
    /// hand-off then resolves normally). Call this synchronously BEFORE `stop()`.
    /// Public: the ``PlayerPresentation`` advance path (AppShell) drives it.
    public func consumePrefetchedNext(matching itemID: String) -> PrefetchedPlayback? {
        nextEpisodeCoordinator.consumePrefetchedNext(matching: itemID)
    }

    /// Whether the panel's HDR/Dolby-Vision mode should be kept across this
    /// hand-off. Public: the advance path (AppShell) reads it to decide whether to
    /// preserve the display mode across the VM swap.
    public func shouldPreserveDisplayMode(forNext next: PrefetchedPlayback?) -> Bool {
        nextEpisodeCoordinator.shouldPreserveDisplayMode(forNext: next)
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
    //
    // Engine construction, swapping, the re-host token, the stall watchdog, and
    // the cross-engine failure fallback chain all live in `EngineHandoffCoordinator`
    // (`engineHandoff`). The view model keeps the bring-up orchestration
    // (`playResolved` / `startPlayback`) and hands the mechanics there.

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
        HandoffDiagnostics.emit(
            "bringup START item=\(itemID) provider=\(provider.kind.rawValue) "
                + "transcode=\(forceTranscode)"
        )
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
            HandoffDiagnostics.emit(
                "bringup FAILED item=\(itemID) provider=\(provider.kind.rawValue) "
                    + "error=\(HandoffDiagnostics.errorCode(error))"
            )
            nextEpisodeCoordinator.clearFirstFrameWait()
            phase = .failed(error)
        } catch {
            HandoffDiagnostics.emit(
                "bringup FAILED item=\(itemID) provider=\(provider.kind.rawValue) "
                    + "error=nonAppError"
            )
            nextEpisodeCoordinator.clearFirstFrameWait()
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
        // Offline choke point: if a completed download exists for this item,
        // rewrite the request to play the local `file://` asset so BOTH engines
        // play it with zero engine changes. Strictly additive — a no-op when no
        // resolver is injected or no local copy exists (proven byte-identical by
        // `OfflineRequestRewriteTests`).
        let localURL = await offlinePlaybackResolver?.localPlaybackURL(for: request.item)
        request = Self.applyingOfflineRewrite(to: request, localURL: localURL)
        // Steer the engine's INITIAL active audio track by language (no reload)
        // from the prefer-original-language policy. Computed here so every
        // playResolved entry (initial, adopted prefetch, and cross-engine
        // fallback, which reuse self.request) inherits it. Subtitle language
        // steering is intentionally left empty — Plozz owns subtitle selection
        // via the SDR overlay, so the engine must not activate its own track.
        await fillOriginalLanguageIfNeeded(for: &request)
        request.preferredAudioLanguages = preferredAudioLanguages(for: request.item)
        let kind = routeEngine(for: request, forceTranscode: forceTranscode)
        return PrefetchedPlayback(itemID: itemID, request: request, engineKind: kind)
    }

    /// Rewrites a resolved request to play a local `file://` asset when a completed
    /// offline download exists (`localURL != nil`), otherwise returns the request
    /// UNCHANGED (byte-identical) so default behavior is preserved.
    ///
    /// The rewrite swaps only the *source*: it moves the local file into the legacy
    /// `streamURL` field — the direct-play field BOTH engines already consume —
    /// clears every network/managed source (`playbackSource`, `externalAudioURL`,
    /// `localRemuxSource`), and marks it a non-manifest direct play. All other
    /// resolved facts (item, tracks, start position, source metadata used for
    /// engine routing) are preserved, so engine selection stays consistent with a
    /// direct-played copy of the same media.
    nonisolated static func applyingOfflineRewrite(
        to request: PlaybackRequest,
        localURL: URL?
    ) -> PlaybackRequest {
        guard let localURL else { return request }
        var rewritten = request
        rewritten.streamURL = localURL
        rewritten.playbackSource = nil
        rewritten.externalAudioURL = nil
        rewritten.localRemuxSource = nil
        rewritten.isManifestStream = false
        rewritten.isTranscoding = false
        rewritten.deliveryMode = .directPlay
        return rewritten
    }

    /// Picks the engine for a resolved request — the pure routing decision, no
    /// engine mutation or network. Extracted so the current-item load and the
    /// next-episode prefetch pick the engine the same way.
    private func routeEngine(for request: PlaybackRequest, forceTranscode: Bool) -> PlaybackEngineKind {
        EngineSelection.route(
            request: request,
            forceTranscode: forceTranscode,
            plozzigenAvailable: engineFactory.plozzigenAvailable,
            capabilities: capabilities,
            subtitleRule: effectiveSubtitleRule(for: request.item)
        )
    }

    /// Fills `request.item.originalLanguage` for a SERVER-backed item that lacks it
    /// (Plex/Jellyfin/Emby never provide `original_language`) so the "prefer
    /// original language" audio policy can steer to the real spoken language
    /// instead of the server/container default. Resolved once (cached in the shared
    /// ``ArtworkRouter``) from an exact-ID TMDB lookup keyed on the item's external
    /// ids — the same provider-id-keyed seam artwork already uses for server items.
    ///
    /// Deliberately gated so it's a no-op (and issues NO network call) unless the
    /// effective preference is `.original` with no remembered per-series language
    /// and the value is still unknown: `.device`/`.language(code)` are unchanged,
    /// and direct-share items (which arrive already enriched) never re-resolve.
    ///
    /// The bring-up wait is bounded (``originalLanguageFillTimeout``) so a first
    /// uncached play on a degraded network never stalls playback START for the full
    /// request timeout: on timeout this play proceeds with the container default
    /// while the lookup finishes in the background and warms the cache, so the next
    /// play/episode gets the resolved language.
    private func fillOriginalLanguageIfNeeded(for request: inout PlaybackRequest) async {
        guard request.item.originalLanguage == nil,
              rememberedAudioLanguage(for: request.item) == nil,
              case .original = effectiveAudioPreference(for: request.item)
        else { return }
        let item = request.item
        let resolved = await ArtworkRouter.boundedValue(within: Self.originalLanguageFillTimeout) {
            await ArtworkRouter.shared.originalLanguage(for: item)
        }
        if let resolved { request.item.originalLanguage = resolved }
    }

    /// Upper bound on how long a first uncached original-language fill may delay
    /// playback bring-up; the lookup keeps running past this to warm the cache.
    private static let originalLanguageFillTimeout: Duration = .seconds(2)

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

    /// The remembered audio language for this item's series (gated on the toggle).
    private func rememberedAudioLanguage(for item: MediaItem) -> String? {
        seriesMemory.rememberedAudioLanguage(for: item)
    }

    /// The remembered subtitle decision for this item's series (gated on the toggle).
    private func rememberedSubtitle(for item: MediaItem) -> RememberedSubtitleSelection? {
        seriesMemory.rememberedSubtitle(for: item)
    }

    /// Records the viewer's manual audio-language pick for the current series.
    private func recordSeriesAudioSelection(language: String?) {
        guard let item = request?.item else { return }
        seriesMemory.recordAudioSelection(language: language, for: item)
    }

    /// Records the viewer's manual subtitle pick (a language, or Off) for the series.
    private func recordSeriesSubtitleSelection(_ selection: RememberedSubtitleSelection?) {
        guard let item = request?.item else { return }
        seriesMemory.recordSubtitleSelection(selection, for: item)
    }

    /// Reconciles per-series memory across servers once `enrichSeriesIDs` has folded
    /// the series' external ids onto the item, then applies any imported choice to
    /// live playback (the engine/subtitle side effects the memory can't do itself).
    private func reconcileSeriesMemoryAcrossServers() {
        guard let item = request?.item else { return }
        let outcome = seriesMemory.reconcile(
            item: item,
            viewerChangedAudio: subtitleController.viewerChangedAudioThisSession,
            viewerChangedSubtitle: subtitleController.viewerChangedSubtitleThisSession
        )
        if let language = outcome.importedAudioLanguage {
            subtitleController.queueImportedAudio(language: language)
        }
        if outcome.shouldReapplyInitialSubtitle {
            // Re-route the load-time subtitle now that the remembered value
            // resolves. Works for native (tracks present → applies now) and
            // Plozzigen (tracks arrive later → onTracksChanged re-applies).
            if let request { subtitleController.applyInitialSubtitleForNewLoad(for: request) }
        }
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
        dynamicRangeLoadGeneration &+= 1
        let rangeLoadGeneration = dynamicRangeLoadGeneration
        inheritedPreservedDynamicRange =
            engineKind != .native ? pendingPreservedDynamicRange : nil
        pendingPreservedDynamicRange = nil
        effectiveDynamicRange = engineKind == .native
            ? .native(metadata: request.sourceMetadata)
            : .awaitingEngineProbe(metadata: request.sourceMetadata)
        dynamicRangeTransitionToken = UUID()
        let hintedHDR = effectiveDynamicRange.bestAvailable?.isHDR ?? false
        liveSubtitles.isHDR = hintedHDR
        controls.subtitlesRenderHDR = hintedHDR
        HandoffDiagnostics.emit(
            "range AWAITING engine=\(engineKind.rawValue) "
                + "hint=\(effectiveDynamicRange.bestAvailable?.rawValue ?? "unknown") "
                + "generation=\(rangeLoadGeneration) subtitlesHDR=\(hintedHDR)"
        )
        // Publish the transition state before replacing/stopping the old engine.
        // SwiftUI gets one run-loop turn to raise black before either criteria
        // owner clears or applies its display mode.
        await preEngineCommitYield()
        guard !didStop,
              dynamicRangeLoadGeneration == rangeLoadGeneration else {
            return
        }
        let actualEngineKind = engineHandoff.commitEngineForPlayback(engineKind)
        if actualEngineKind != engineKind {
            inheritedPreservedDynamicRange = nil
            effectiveDynamicRange = .native(metadata: request.sourceMetadata)
            dynamicRangeTransitionToken = UUID()
        }
        configureSourceFactsCallback(loadGeneration: rangeLoadGeneration)
        // Arm the stall watchdog around load() so a hang that never reports an
        // error still triggers the fallback chain instead of spinning forever.
        engineHandoff.armPlaybackWatchdog(startPosition: startPosition)
        let loadStart = Date()
        await engine.load(request: request, startPosition: startPosition)
        guard dynamicRangeLoadGeneration == rangeLoadGeneration, !didStop else {
            return
        }
        if engineKind != .native, let facts = engine.probedSourceFacts {
            applyEngineProbedSourceFacts(facts)
        }
        HandoffDiagnostics.emit("engine.load returned engine=\(engineKind.rawValue) took=\(HandoffDiagnostics.ms(loadStart))")
        // A background transition or user transport command can arrive while
        // load() is suspended. Reconcile that current intent before publishing
        // ready or reporting start so the engine and provider agree.
        if intendsPlayback {
            engine.play()
        } else {
            engine.pause()
        }
        controls.isPaused = !intendsPlayback
        controls.intendsPause = !intendsPlayback
        phase = .ready
        // Hold the bring-up spinner until the engine actually presents its first
        // frame, so `.loading` → `.ready` is one continuous indicator rather than
        // a spinner that vanishes here (before the picture is up) and then a black
        // gap / second in-player spinner while frames arrive.
        nextEpisodeCoordinator.beginAwaitingFirstFrame(resumeClock: startPosition)
        // Publish diagnostics after the engine load attempt returns, so the
        // diagnostics sampler doesn't churn SwiftUI layout during Plozzigen init.
        diagnosticsToken = UUID()
        // Report the *resolved* start position explicitly (not engine.currentTime,
        // which can still read 0 before the seek settles). When best-source routing
        // resumed a position learned from another server, this converges the chosen
        // server to that unified furthest-progress point on entry.
        let startWasPaused = !intendsPlayback
        await progressReporter.reportStart(
            isPaused: startWasPaused,
            positionOverride: startPosition > 0 ? startPosition : nil
        )
        // Register the live session (idempotent) now that the server has a real
        // now-playing session, so convergence writes against this server defer
        // until stop() ends it.
        onPlaybackStarted()
        // Begin periodic mid-play convergence checkpoints from the resumed point so
        // progress fans out to other servers without waiting for Back. Seeded so the
        // first checkpoint only fires after real forward progress past the resume.
        progressReporter.startCheckpointLoop(seedPosition: startPosition)

        // Seed the in-player track menu from the engine's track lists (the
        // engine has already applied the user's default subtitle selection).
        subtitleController.loadTrackOptions()

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
        subtitleOverlay.cancelAll()
        subtitleController.resetForNewLoad()
        liveSubtitles.offset = 0
        liveSubtitles.clear()
        refreshSubtitleDelayAvailability()

        // Route the load-time DEFAULT subtitle through Plozz's own overlay (same
        // as a manual pick) instead of letting AVPlayer / the engine draw it, so
        // the default lane gets identical HDR-safe styling + live offset. Native
        // tracks are ready now; Plozzigen's arrive later via `onTracksChanged`,
        // which calls this again. The per-load flag makes it fire exactly once.
        // (the primary selection id is intentionally NOT reset in the controller:
        // the image-sub resolve path seeds it before playResolved so the menu
        // reflects the bitmap track Plozzigen draws; routing sets it otherwise.)
        subtitleController.applyInitialSubtitleForNewLoad(for: request)

        // Apply any cross-server audio import that reconcile queued before the
        // engine's audio tracks were known. Native populates `audioTracks` only
        // after `engine.load` (here) and never fires `onTracksChanged`, so this is
        // its retry point; a no-op when nothing is pending or already correct.
        subtitleController.applyImportedAudioIfPossible()

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

    // MARK: - Stall watchdog / cross-engine fallback
    //
    // The stall watchdog and the cross-engine failure fallback chain live in
    // `EngineHandoffCoordinator` (`engineHandoff`), with the fallback *decision*
    // pinned by `EngineFailurePolicy`. `playResolved` arms the watchdog via
    // `engineHandoff.armPlaybackWatchdog`; `stop()`/pause cancel it via
    // `engineHandoff.cancelWatchdog()`.

    // MARK: - Progress reporting / convergence checkpoints
    //
    // Progress reporting (provider + Trakt lifecycle) and the periodic
    // convergence-checkpoint loop live in `WatchProgressReporter`. The view model
    // keeps only the public `checkpointNow()` entry point (used by the background
    // lifecycle path below) as a thin forwarder.

    /// Forces an immediate convergence checkpoint regardless of the timer — used
    /// when the app is about to be backgrounded/suspended (the TV Home button or
    /// sleep path, which never fires the view's `onDisappear`/`stop()`), so the
    /// latest position is durably captured before the process can be killed.
    public func checkpointNow() {
        progressReporter.checkpointNow()
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
        progressReporter.emitCheckpoint(includingPaused: true)
        // Key off intent, not `engine.isPaused`: if we mean to be playing (even
        // while the engine is mid post-seek settle), pause for real — this also
        // routes through `cancelResumeConfirm()` so a recovery loop can't wake the
        // engine back up as the app suspends.
        if intendsPlayback {
            setPaused(true)
        }
    }

    /// Marks a genuine tvOS background entry. AetherEngine intentionally tears
    /// down its AVPlayer item, loopback HLS server, demuxer, and decode session on
    /// this transition, so a later `.active` phase must rebuild rather than call
    /// `play()` on the empty player shell.
    public func didEnterBackground() {
        suspendForBackground()
        foregroundReload.markEnteredBackground()
    }

    /// Restores an engine after a real background round-trip while preserving the
    /// user's paused state. No provider re-resolve or playback lifecycle report is
    /// emitted: Plex, Jellyfin, and file-share sources all recover through the same
    /// engine seam at their existing position and session URL. Driven by
    /// ``ForegroundReloadCoordinator``.
    public func resumeAfterBackground() async {
        await foregroundReload.resume()
    }

    // MARK: - Transport

    /// Requests a committed seek. Coalesces rapid presses and defers the engine
    /// commit; owned by ``SeekScrubCoordinator``. See that type for the full
    /// coalescing / resume-confirm semantics.
    public func requestSeek(to seconds: TimeInterval) {
        seekCoordinator.requestSeek(to: seconds)
    }

    /// Legacy direct-seek path retained for callers (e.g. resume on load) that
    /// want a one-shot await. New transport input goes through `requestSeek`.
    public func seek(to seconds: TimeInterval) async {
        await seekCoordinator.seek(to: seconds)
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
            engineHandoff.cancelWatchdog()
            seekCoordinator.cancelResumeConfirm()
        }
        controls.isPaused = paused
        progressReporter.reportStateChange(paused: paused)
    }

    /// Guards against a double teardown: `PlayerView` may call `stop()` itself on
    /// an HDR-aware dismiss (to start the SDR switch behind the veil) and then the
    /// view's `onDisappear` fires a second `stop()` once it's torn down. Without
    /// this the server would get two `.stop` reports for one playback.
    private var didStop = false
    /// Natural EOF can zero an engine's current time before dismissal. Only that
    /// path falls back to the furthest observed point; manual exits save the actual
    /// current position so rewinding intentionally moves the resume point backward.
    private var didReachNaturalEnd = false

    private func currentResumePosition() -> TimeInterval {
        let current = engine.currentTime
        if current.isFinite, current >= 0 {
            return current
        }
        return max(0, engine.furthestObservedPosition)
    }

    /// Call when leaving playback: report a final stop so the server records the
    /// resume point, then tear the engine down.
    public func stop(preserveDisplayMode: Bool = false) async {
        guard !didStop else { return }
        HandoffDiagnostics.emit("stop preserveDisplayMode=\(preserveDisplayMode) contentRange=\(String(describing: effectiveDynamicRange.bestAvailable)) (false ⇒ panel should reset to SDR)")
        PlaybackTrace.note("stop() teardown curr=\(String(format: "%.2f", engine.currentTime)) shouldDismiss=\(shouldDismiss) pendingNext=\(pendingNextEpisode != nil) isSeeking=\(controls.isSeeking)")
        didStop = true
        dynamicRangeLoadGeneration &+= 1
        engine.onProbedSourceFactsChanged = nil
        prefetchTask?.cancel()
        prefetchTask = nil
        // Cancel the next-episode prefetch; its session (if any) is released
        // below, after the current engine is silenced, so cleanup never delays
        // stopping playback.
        nextEpisodeCoordinator.cancelPrefetch()
        nextEpisodeCoordinator.clearFirstFrameWait()
        progressReporter.cancel()
        segmentsTask?.cancel()
        segmentsTask = nil
        autoSkipNoticeTask?.cancel()
        autoSkipNoticeTask = nil
        engineHandoff.cancelWatchdogAndRecovery()
        seekCoordinator.cancelAll()
        subtitleAcquisition.cancelAll()
        subtitleOverlay.cancelAll()
        // Silence the engine *before* the final server report. The report is a
        // network round-trip that can take a second or two; stopping first means
        // leaving the player never keeps playing audio while it completes. Grab
        // the resume position up front since the engine is torn down here.
        let finalPosition = didReachNaturalEnd
            ? max(engine.furthestObservedPosition, engine.currentTime)
            : currentResumePosition()
        let finalDuration = progressReporter.knownPlaybackDuration()
        let percent = progressReporter.watchedPercent(at: finalPosition)
        engine.stop(preserveDisplayMode: preserveDisplayMode)
        // Release any prefetched next-episode session that was never adopted, and
        // an adopted-but-never-committed session (a hand-off torn down before the
        // incoming player took ownership), so a Jellyfin session isn't orphaned.
        // A no-op for idempotent providers. Done AFTER engine.stop() so it never
        // keeps audio playing while the cleanup round-trips.
        await nextEpisodeCoordinator.releaseOrphanedPrefetchIfNeeded()
        if let unadopted = adoptedResolved {
            adoptedResolved = nil
            await nextEpisodeCoordinator.releaseSession(unadopted.request)
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
        await progressReporter.report(
            event: .stop,
            isPaused: true,
            positionOverride: finalPosition,
            durationOverride: finalDuration
        )
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

    /// Engine-probed source facts (real dynamic range / audio / dimensions),
    /// authoritative for sources with no provider metadata (SMB). `nil` on the
    /// native engine and until the engine has probed.
    public var engineProbedFacts: EngineProbedSourceFacts? { engine.probedSourceFacts }

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
    /// Provider-supplied basename of the selected source media file.
    public var diagnosticsSourceFileName: String? { request?.sourceFileName }

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

    /// Selects an audio track from the menu. Owned by ``SubtitleTrackController``.
    public func selectAudioOption(id: Int) {
        subtitleController.selectAudioOption(id: id)
    }

    /// Selects a subtitle track, or turns subtitles off (`PlayerTrackOption.offID`).
    /// `userInitiated` is `true` for a real menu pick (remembered for the series)
    /// and `false` for the programmatic load-time default. Owned by
    /// ``SubtitleTrackController``.
    public func selectSubtitleOption(id: Int, userInitiated: Bool = true) {
        subtitleController.selectSubtitleOption(id: id, userInitiated: userInitiated)
    }

    // MARK: - Dual (secondary) subtitle

    /// Selects the second (dual) subtitle track, or turns the second line off
    /// (`PlayerTrackOption.offID`). Owned by ``SubtitleTrackController``.
    public func selectSecondarySubtitleOption(id: Int) {
        subtitleController.selectSecondarySubtitleOption(id: id)
    }

    // MARK: - Subtitle search & download (manual + auto)

    /// Manually search the server's subtitle source for the given language (or the
    /// profile's preferred language when `nil`), honouring the SDH/Forced
    /// preference. Publishes results to `controls.subtitleDownloadState`.
    public func searchRemoteSubtitles(language: String? = nil) {
        subtitleAcquisition.search(
            requestedLanguage: language,
            defaultLanguage: behavior.resolvedPreferredLanguage,
            preference: behavior.searchPreference
        )
    }

    /// Re-runs the last manual search (used after the viewer flips the per-search
    /// SDH/Forced toggle so the results reflect the new preference).
    public func refreshRemoteSubtitleSearch() {
        subtitleAcquisition.refreshSearch(
            defaultLanguage: behavior.resolvedPreferredLanguage,
            preference: behavior.searchPreference
        )
    }

    /// Downloads the chosen remote subtitle onto the server, then hot-loads it into
    /// the running player so it appears immediately (no replay needed).
    public func downloadAndLoadRemoteSubtitle(_ subtitle: RemoteSubtitle) {
        subtitleAcquisition.download(subtitle, preference: behavior.searchPreference)
    }

    /// If auto-download is enabled and the item lacks a suitable subtitle in the
    /// preferred language, kicks off a detached background search+download so the
    /// server fetches one — then hot-loads it into the running session if it
    /// arrives in time. Best-effort; never blocks play.
    private func startAutoSubtitleDownloadIfNeeded(request: PlaybackRequest) {
        // Only providers with a server-side subtitle source can auto-download.
        guard subtitleAcquisition.providerSupportsRemoteSubtitles else { return }
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
        // The SDH/Forced accessibility preference applies to auto-download too, with
        // the content-type mode as the source of truth for the forced-only gate.
        subtitleAcquisition.autoDownload(
            language: language, mode: rule.mode, preference: behavior.searchPreference
        )
    }
}

// MARK: - RemoteSubtitleAcquisitionHost

extension PlayerViewModel: SeekScrubCoordinatorHost {
    var seekEngine: any VideoEngine { engine }
    var seekIntendsPlayback: Bool { intendsPlayback }
    var seekDidStop: Bool { didStop }
    func seekApplyPaused(_ paused: Bool) { setPaused(paused) }
}

extension PlayerViewModel: WatchProgressReporterHost {
    var reporterEngineCurrentTime: TimeInterval { engine.currentTime }
    var reporterEngineDuration: TimeInterval { engine.duration }
    var reporterEngineIsPaused: Bool { engine.isPaused }
    var reporterControlsDuration: TimeInterval { controls.duration }
    var reporterRequest: PlaybackRequest? { request }
    var reporterResumePosition: TimeInterval { currentResumePosition() }
}

extension PlayerViewModel: NextEpisodeCoordinatorHost {
    var nextEpisodeCandidate: MediaItem? { nextEpisode }
    var upNextEngine: any VideoEngine { engine }
    var upNextProvider: any MediaProvider { provider }
    var upNextAuthoritativeRange: SourceDynamicRange? {
        effectiveDynamicRange.authoritativeRange
    }
    var upNextCurrentEngineKind: PlaybackEngineKind { currentEngineKind }
    var upNextBringUpStartedAt: Date? { bringUpStartedAt }
    func upNextResolveAndRoute(
        itemID: String, mediaSourceID: String?, forceTranscode: Bool
    ) async throws -> PrefetchedPlayback {
        try await resolveAndRoute(
            itemID: itemID, mediaSourceID: mediaSourceID, forceTranscode: forceTranscode)
    }
}

extension PlayerViewModel: RemoteSubtitleAcquisitionHost {
    func setSubtitleDownloadState(_ state: SubtitleDownloadState) {
        controls.subtitleDownloadState = state
    }

    func hotLoadDownloadedSubtitle(_ track: MediaTrack, preferredLanguage: String?, forced: Bool) -> Int {
        subtitleController.hotLoadSubtitleTrack(track, preferredLanguage: preferredLanguage, forced: forced)
    }

    func selectDownloadedSubtitle(id: Int, userInitiated: Bool) {
        subtitleController.selectSubtitleOption(id: id, userInitiated: userInitiated)
    }

    var isPrimarySubtitleOff: Bool { subtitleController.selectedSubtitleTrackID == nil }
}

// MARK: - SubtitleOverlayLoaderHost

extension PlayerViewModel: SubtitleOverlayLoaderHost {
    var primarySubtitleSelectionID: Int? { subtitleController.selectedSubtitleTrackID }
    var secondarySubtitleSelectionID: Int? { subtitleController.selectedSecondarySubtitleTrackID }

    func overlayResolveDeliveryURL(_ track: MediaTrack) async throws -> URL? {
        try await subtitleController.resolveSubtitleDeliveryURL(track)
    }

    func overlayApplyPrimaryCues(_ stream: SubtitleCueStream?) {
        liveSubtitles.loadPrimary(stream)
        refreshSubtitleDelayAvailability()
    }

    func overlayApplySecondaryCues(_ stream: SubtitleCueStream?) {
        liveSubtitles.loadSecondary(stream)
    }

    func overlayDetectedLanguage(for id: Int) -> String? {
        subtitleController.detectedLanguage(for: id)
    }

    func overlayRecordDetectedLanguage(_ language: String, for id: Int) {
        subtitleController.recordDetectedLanguage(language, for: id)
    }

    func overlayReloadTrackOptions() {
        subtitleController.loadTrackOptions()
    }

    func overlaySetSecondaryStatus(_ status: SecondarySubtitleStatus) {
        controls.secondarySubtitleStatus = status
    }

    #if DEBUG
    func overlaySetPrimaryDiagnostic(route: String, cues: Int?) {
        subtitleController.setPrimarySubtitleDiagnostic(route: route, cues: cues)
    }
    #endif
}

// MARK: - SubtitleTrackControllerHost

extension PlayerViewModel: SubtitleTrackControllerHost {
    var trackEngine: any VideoEngine { engine }
    var trackEngineKind: PlaybackEngineKind { currentEngineKind }
    var trackRequest: PlaybackRequest? { request }
    var trackBehavior: SubtitleBehavior { behavior }
    var trackControls: PlayerControlsModel { controls }
    var trackLiveSubtitles: LiveSubtitleModel { liveSubtitles }
    var trackSubtitleOverlay: SubtitleOverlayLoader { subtitleOverlay }
    var trackStyle: SubtitleStyle { style }
    var trackPlozzigenAvailable: Bool { engineFactory.plozzigenAvailable }
    var trackAuthenticatedHTTPResolver: (any AuthenticatedHTTPResourceResolving)? {
        authenticatedHTTPResolver
    }

    func trackApplySubtitleStyle(_ style: SubtitleStyle) {
        applySubtitleStyle(style)
    }

    func trackRememberedSubtitle(for item: MediaItem) -> RememberedSubtitleSelection? {
        rememberedSubtitle(for: item)
    }

    func trackEffectiveSubtitleRule(for item: MediaItem) -> SubtitlePolicy.Rule {
        effectiveSubtitleRule(for: item)
    }

    func trackRecordAudioSelection(language: String?) {
        recordSeriesAudioSelection(language: language)
    }

    func trackRecordSubtitleSelection(_ selection: RememberedSubtitleSelection?) {
        recordSeriesSubtitleSelection(selection)
    }

    func trackRefreshSubtitleDelayAvailability() {
        refreshSubtitleDelayAvailability()
    }

    func trackPlayResolvedForImageSubtitleSwap(
        _ request: PlaybackRequest, startPosition: TimeInterval
    ) async {
        await playResolved(request, engineKind: .plozzigen, startPosition: startPosition)
    }
}

// MARK: - EngineHandoffCoordinatorHost

extension PlayerViewModel: EngineHandoffCoordinatorHost {
    var handoffStyle: SubtitleStyle { style }
    var handoffRequest: PlaybackRequest? { request }
    var handoffItemID: String { itemID }
    var handoffStartPositionOverride: TimeInterval? { startPositionOverride }
    /// The HDR range whose Plozzigen criteria a fresh-engine retry should keep
    /// applied across the swap (only when the authoritative range is HDR), so the
    /// panel doesn't flap out of HDR/DV between the failed attempt and its retry.
    var handoffPreservedRetryRange: SourceDynamicRange? {
        effectiveDynamicRange.authoritativeRange?.isHDR == true
            ? effectiveDynamicRange.authoritativeRange
            : nil
    }
    var handoffDidStop: Bool { didStop }
    var handoffDynamicRangeLoadGeneration: UInt { dynamicRangeLoadGeneration }

    func handoffSetPendingPreservedDynamicRange(_ range: SourceDynamicRange?) {
        pendingPreservedDynamicRange = range
    }

    func handoffConfigureEngineCallbacks() {
        configureEngineCallbacks()
    }

    func handoffPlayResolved(
        _ request: PlaybackRequest,
        engineKind: PlaybackEngineKind,
        startPosition: TimeInterval
    ) async {
        await playResolved(request, engineKind: engineKind, startPosition: startPosition)
    }

    func handoffStartPlayback(forceTranscode: Bool, resumeOverride: TimeInterval?) async {
        await startPlayback(forceTranscode: forceTranscode, resumeOverride: resumeOverride)
    }

    func handoffSetPhase(_ phase: PlayerViewModel.Phase) {
        self.phase = phase
    }

    func handoffClearFirstFrameWait() {
        nextEpisodeCoordinator.clearFirstFrameWait()
    }
}

// MARK: - ForegroundReloadCoordinatorHost

extension PlayerViewModel: ForegroundReloadCoordinatorHost {
    var reloadPhase: PlayerViewModel.Phase { phase }
    var reloadDidStop: Bool { didStop }
    var reloadEngine: any VideoEngine { engine }
    var reloadEngineToken: UUID { engineToken }
    var reloadIsPlozzigenEngine: Bool { currentEngineKind == .plozzigen }
    var reloadIntendsPlayback: Bool { intendsPlayback }
    var reloadPlaybackSpeed: Double { controls.playbackSpeed }

    func reloadReapplyTrackSelections(to engine: any VideoEngine) {
        subtitleController.reapplyTrackSelections(to: engine)
    }

    func reloadLoadTrackOptions() {
        subtitleController.loadTrackOptions()
    }

    func reloadReconcilePaused(_ paused: Bool) {
        controls.isPaused = paused
        controls.intendsPause = paused
    }

    func reloadFail(_ error: AppError) {
        phase = .failed(error)
    }
}

#endif
