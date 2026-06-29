#if canImport(AVFoundation)
import Foundation
import AVFoundation
import Observation
import CoreModels
import CoreNetworking
import TraktService
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
    /// hybrid (mpv) engine renders HDR without a panel mode switch, so it stays
    /// `.sdr` here and the view never raises an unnecessary veil. Provider-
    /// agnostic — derived from `MediaSourceMetadata`, identical for Plex/Jellyfin.
    private(set) var displayMode: HDRDisplayMode = .sdr

    /// The dynamic range of the **content** being played, independent of which
    /// engine renders it. `displayMode` only goes HDR for the native engine
    /// (the only one that drives `AVDisplayManager`'s mode switch *itself*), but
    /// on some TVs the mpv engine's HDR/DV output still makes the panel switch
    /// HDMI modes — so the exit veil must cover that switch for *any* engine
    /// playing HDR/DV content. Gating the exit veil on content (not engine)
    /// avoids the flash-on-Home when an mpv-played HDR/DV title is dismissed.
    private(set) var contentDisplayMode: HDRDisplayMode = .sdr

    /// Shared, observable transport state for the custom player overlay. The
    /// view model writes live playback facts here; the input controller writes
    /// scrub state; the SwiftUI overlay reads.
    public let controls = PlayerControlsModel()

    private let provider: any MediaProvider
    private let itemID: String
    /// The chosen `MediaVersion.id` (Jellyfin `MediaSourceId` / Plex `Media` id)
    /// to play when the title has multiple versions; `nil` plays the default.
    private let mediaSourceID: String?
    private let captionSettings: CaptionSettings
    /// Per-profile playback prefs. Today: whether to offer the Skip Intro/Credits
    /// button. When `skipIntros` is off, segments are never fetched or shown.
    private let playbackSettings: PlaybackSettings
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

    /// Debug launch-arg flag (`-com.plozz.playback.remuxHevcAny YES`, **default
    /// OFF**): widen local-remux eligibility from Dolby-Vision-only to *any*
    /// AVPlayer-decodable HEVC (HDR10 / HDR10+ / HLG / SDR, 8- or 10-bit) in an MKV
    /// with AC-3 / E-AC-3 audio. Set as a launch argument, it lands in the standard
    /// `NSArgumentDomain`, so the maintainer can A/B exactly this one routing change
    /// on the shared Apple TV. When ON, those titles reach remux→AVPlayer (native
    /// seek + surround/Atmos) instead of falling through to the multichannel-
    /// crashing mpv engine. Dolby Vision Profile 7 and TrueHD still stay on mpv.
    private var allowAnyDecodableHEVCRemux: Bool {
        UserDefaults.standard.bool(forKey: "com.plozz.playback.remuxHevcAny")
    }

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

    /// Seek-coordinator state. `latestSeekTarget` is the most-recently-requested
    /// committed seek time; `seekTask` is the single in-flight loop that drains
    /// it. Together they guarantee rapid presses ACCUMULATE and resolve to the
    /// final target without overlapping engine seeks racing each other.
    private var latestSeekTarget: TimeInterval?
    private var seekTask: Task<Void, Never>?
    /// The active local-remux session, when this playback chose the shared remux
    /// seam over the standard native/mpv routing.
    private var localRemuxSession: (any LocalRemuxStreamingSession)?
    /// Optional long-running scripted seek benchmark.
    private var remuxSeekTestTask: Task<Void, Never>?
    /// User-facing reason for the remux harness state on the current load.
    private var localRemuxActivationMessage: String?

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
    /// Background series-id enrichment; awaited (briefly) at stop so a fast
    /// finisher still scrobbles with the show's ids resolved.
    private var enrichTask: Task<Void, Never>?

    public init(
        provider: any MediaProvider,
        itemID: String,
        mediaSourceID: String? = nil,
        captionSettings: CaptionSettings = .default,
        playbackSettings: PlaybackSettings = .default,
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
        checkpointInterval: TimeInterval = 60
    ) {
        self.provider = provider
        self.itemID = itemID
        self.mediaSourceID = mediaSourceID
        self.captionSettings = captionSettings
        self.playbackSettings = playbackSettings
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
        self.engine = engineFactory.makeNative(captionSettings)
        self.currentEngineKind = .native
        PlaybackInstrumentation.increment(.viewModel)
        // Seed last-used speed so a user who set 1.25× on the last show keeps it.
        self.controls.playbackSpeed = preferencesStore.loadPlaybackSpeed()
        self.controls.localRemuxStrategies = LocalRemuxStrategyRegistry.availableChoices
        self.controls.selectedLocalRemuxStrategyID = preferencesStore.loadLocalRemuxStrategyID()
        self.controls.skipBackwardInterval = playbackSettings.skipBackwardInterval
        self.controls.skipForwardInterval = playbackSettings.skipForwardInterval
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
            Task { await self.report(event: .progress, isPaused: false) }
        }
        engine.onFailure = { [weak self] error in
            guard let self else { return }
            Task { await self.handleEngineFailure(error) }
        }
        engine.onEnded = { [weak self] in
            self?.handlePlaybackEnded()
        }
    }

    /// Called when the active engine reports a clean playthrough to the end of the
    /// stream. Auto-advances to the next episode when one is queued, otherwise
    /// dismisses so the player never freezes on the final frame: trailers/movies
    /// return to detail, a season finale returns to the series page.
    private func handlePlaybackEnded() {
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
    }

    /// Fetches the playing episode's series-level ids and folds them into the
    /// item's `providerIDs` under the `Series*` namespace, so scrobblers that
    /// need the show's id (Simkl) can match an episode that only carried
    /// episode-level ids. Best-effort: a miss leaves scrobble behavior unchanged.
    private func enrichSeriesIDs() async {
        guard let seriesIDResolver, var current = request else { return }
        guard let raw = await seriesIDResolver(), !raw.isEmpty else { return }
        let map: [(ProviderIDNamespace, String)] = [
            (.imdb, "SeriesImdb"), (.tmdb, "SeriesTmdb"), (.tvdb, "SeriesTvdb"),
            (.myAnimeList, "SeriesMal"), (.aniList, "SeriesAniList")
        ]
        var merged = current.item.providerIDs
        for (namespace, key) in map {
            guard let value = raw.providerID(namespace) else { continue }
            if merged[key] == nil { merged[key] = value }
        }
        current.item.providerIDs = merged
        request = current
    }

    // MARK: - Engine selection / swapping

    /// Instantiates the engine for `kind`, falling back to native if a hybrid
    /// engine was requested but isn't wired in (defensive — the router never
    /// asks for hybrid unless it's available).
    private func makeEngine(_ kind: PlaybackEngineKind) -> any VideoEngine {
        switch kind {
        case .hybrid:
            if let makeHybrid = engineFactory.makeHybrid {
                return makeHybrid(captionSettings)
            }
            return engineFactory.makeNative(captionSettings)
        case .plozzigen:
            if let makePlozzigen = engineFactory.makePlozzigen, let engine = makePlozzigen() {
                return engine
            }
            return engineFactory.makeNative(captionSettings)
        case .native:
            return engineFactory.makeNative(captionSettings)
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
    /// only if it's actually available (no hybrid → nothing to swap to).
    private var alternateEngineKind: PlaybackEngineKind? {
        switch currentEngineKind {
        case .native:
            // AVPlayer failed (e.g. the runtime `hev1` black-screen catch). Prefer
            // Plozzigen (AetherEngine): it fetches the source itself and remuxes
            // on-device. mpv (the hybrid engine) shares a decode-only FFmpeg with
            // NO network/TLS protocols, so it cannot open a remote HTTPS stream and
            // would only drop straight to a server transcode — use it only when
            // Plozzigen isn't wired in.
            if engineFactory.plozzigenAvailable { return .plozzigen }
            return engineFactory.hybridAvailable ? .hybrid : nil
        case .hybrid:
            // mpv failed — try Plozzigen before giving up to native/transcode.
            return engineFactory.plozzigenAvailable ? .plozzigen : .native
        case .plozzigen:
            // Plozzigen failed — fall back to native (server transcode safety net).
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
        do {
            localRemuxActivationMessage = nil
            await teardownLocalRemuxSession()
            var request = try await provider.playbackInfo(for: itemID, mediaSourceID: mediaSourceID, forceTranscode: forceTranscode)
            // A user-initiated Back during playbackInfo resolution should NOT
            // proceed to bring up an engine that will immediately be torn down —
            // short-circuit cleanly without going through the failure path.
            try Task.checkCancellation()
            request = await applyLocalRemuxIfNeeded(to: request, forceTranscode: forceTranscode)
            self.request = request
            configureControls(for: request)

            // Enrich the episode with its series-level ids in the background so the
            // first scrobble can identify the show on trackers that require it.
            if request.item.kind == .episode, seriesIDResolver != nil {
                enrichTask = Task { @MainActor [weak self] in await self?.enrichSeriesIDs() }
            }

            // An explicit override wins over the provider's resume point so the
            // caller can force "start over" (0) or resume from a chosen second.
            let startPosition = resumeOverride ?? startPositionOverride ?? request.startPosition

            // Pick the engine from the resolved source facts (pure decision).
            let isLocalRemux = request.deliveryMode == .localRemux
            var kind: PlaybackEngineKind
            if isLocalRemux {
                kind = .native
            } else if !forceTranscode, engineFactory.plozzigenAvailable,
                      let descriptor = request.localRemuxSource,
                      case .eligible = descriptor.plozzigenEligibility {
                // Plozzigen handles the full pipeline: FFmpeg demux → HLS-fMP4 →
                // localhost → AVPlayer. Covers HEVC/H.264/VP9/AV1 video with any
                // audio (stream-copy or lossless bridge). Skip LocalRemux; the
                // engine reads localRemuxSource.originalURL directly.
                kind = .plozzigen
            } else {
                kind = EngineRouter.selectEngine(
                    source: request.sourceMetadata,
                    capabilities: capabilities,
                    isTranscoding: request.isTranscoding,
                    hybridAvailable: engineFactory.hybridAvailable
                )
                // mpv (the hybrid engine) shares AetherEngine's decode-only FFmpeg
                // build, which has NO network/TLS protocols compiled in. It
                // therefore cannot open a remote HTTPS stream (every Plex/Jellyfin
                // direct URL) — `loadfile` fails instantly and the player drops to
                // a heavy server transcode. Plozzigen (AetherEngine) fetches the
                // source itself and remuxes HEVC/`hev1`/etc. to AVPlayer on-device,
                // so prefer it for any AVPlayer-incompatible source that would
                // otherwise hit mpv.
                if kind == .hybrid, engineFactory.plozzigenAvailable {
                    kind = .plozzigen
                }
            }

            // An adaptive source carries its audio as a *separate* track (e.g. a
            // high-resolution YouTube DASH trailer). Only the hybrid (mpv) engine
            // can mux two bare URLs, so force it there — AVPlayer would otherwise
            // play the video-only stream silently.
            if !isLocalRemux, request.externalAudioURL != nil, engineFactory.hybridAvailable {
                kind = .hybrid
            }

            // If the subtitle that would be shown by default is image-based
            // (PGS/VOBSUB), AVPlayer can't render it — route to the hybrid engine
            // so it appears, but only when we're direct-playing and a hybrid
            // engine is available. (A file with a text-subtitle equivalent stays
            // native; see `defaultSubtitleNeedsHybridEngine`.) Plozzigen also
            // can't render bitmap subtitles, so it overrides too.
            if !isLocalRemux, (kind == .native || kind == .plozzigen), !request.isTranscoding, engineFactory.hybridAvailable,
               request.subtitleTracks.defaultSubtitleNeedsHybridEngine(
                   mode: captionSettings.subtitleMode,
                   preferredLanguage: captionSettings.resolvedPreferredLanguage) {
                PlozzLog.playback.info("Default subtitle is image-based; routing to the hybrid engine so it can be rendered")
                kind = .hybrid
                // Reflect the auto-selected image subtitle in the track menu.
                selectedSubtitleTrackID = request.subtitleTracks.defaultSubtitleSelection(
                    mode: captionSettings.subtitleMode,
                    preferredLanguage: captionSettings.resolvedPreferredLanguage)?.id
            }

            try Task.checkCancellation()
            await playResolved(request, engineKind: kind, startPosition: startPosition)

            // Best-effort, never blocking play(): (if enabled) fetch a missing
            // subtitle in the preferred language.
            startAutoSubtitleDownloadIfNeeded(request: request)        } catch is CancellationError {
            // Leave `phase` as `.loading`; the view is dismissing.
            return
        } catch let error as AppError {
            phase = .failed(error)
        } catch {
            phase = .failed(.unknown(""))
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
        commitEngineForPlayback(engineKind)
        // Publish the dynamic range the display is being driven to *before*
        // engine.load() requests the actual HDMI mode switch, so the view can
        // fade to black ahead of it. Only the native engine drives the panel's
        // display-mode switch; the hybrid (mpv) engine plays HDR without one, so
        // it stays `.sdr` and no veil is raised. On a cross-engine fallback this
        // re-evaluates correctly: native→hybrid drops to `.sdr` (the native
        // engine's teardown restores SDR — a real switch the view should veil),
        // and hybrid→native rises to HDR (the new switch the view should veil).
        displayMode = engineKind == .native ? HDRDisplayMode(request.sourceMetadata) : .sdr
        // Engine-independent: tracks the *content's* range so the exit veil can
        // cover a panel HDR/DV → SDR switch even when mpv (which stays `.sdr`
        // above) drove the panel into HDR on this TV.
        contentDisplayMode = HDRDisplayMode(request.sourceMetadata)
        // Arm the stall watchdog around load() so a hang that never reports an
        // error still triggers the fallback chain instead of spinning forever.
        armPlaybackWatchdog(startPosition: startPosition)
        await Self.yieldToRunLoop()
        await engine.load(request: request, startPosition: startPosition)
        phase = .ready
        localRemuxSession?.metricsController.recordFirstFrameIfNeeded()
        // Publish diagnostics after the engine load attempt returns, so the
        // diagnostics sampler doesn't churn SwiftUI layout during mpv init.
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

        // Load skip markers once playback is live (opt-in, best-effort).
        loadSkipSegmentsIfEnabled()
    }

    // MARK: - Local remux seam

    private func applyLocalRemuxIfNeeded(
        to request: PlaybackRequest,
        forceTranscode: Bool
    ) async -> PlaybackRequest {
        guard !forceTranscode else {
            localRemuxActivationMessage = "Server fallback transcode is active; remux testing is skipped for this load."
            return request
        }
        guard let descriptor = request.localRemuxSource else {
            localRemuxActivationMessage = "This provider did not expose original-file bytes for remux testing."
            return request
        }
        switch descriptor.eligibility(capabilities: capabilities, allowAnyDecodableHEVC: allowAnyDecodableHEVCRemux) {
        case .eligible:
            break
        case .ineligible(let reason):
            localRemuxActivationMessage = reason
            return request
        }

        let selectedStrategyID = preferencesStore.loadLocalRemuxStrategyID()
        controls.selectedLocalRemuxStrategyID = selectedStrategyID
        guard selectedStrategyID != LocalRemuxStrategyChoice.disabledID else {
            localRemuxActivationMessage = "Remux testing is off. Choose Server HLS baseline, then reload."
            return request
        }
        guard let streamer = LocalRemuxStrategyRegistry.makeStreamer(for: selectedStrategyID) else {
            localRemuxActivationMessage = "Selected remux mode is not installed in this build."
            return request
        }

        do {
            let session = try await streamer.openSession(source: descriptor)
            let prepared = try await session.preparePlayback()
            localRemuxSession = session
            var remuxed = request
            remuxed.streamURL = prepared.playbackURL
            remuxed.isManifestStream = prepared.isManifestStream
            remuxed.deliveryMode = prepared.deliveryMode
            localRemuxActivationMessage = "Active now: \(session.strategy.displayName)"
            return remuxed
        } catch {
            await teardownLocalRemuxSession()
            PlozzLog.playback.debug("Local remux strategy failed; falling back to standard routing")
            localRemuxActivationMessage = "\(streamer.strategy.displayName) could not prepare this title; normal routing is playing instead."
            return request
        }
    }

    private func teardownLocalRemuxSession() async {
        remuxSeekTestTask?.cancel()
        remuxSeekTestTask = nil
        if let localRemuxSession {
            await localRemuxSession.teardown()
        }
        self.localRemuxSession = nil
    }

    // MARK: - Skip intros/credits

    /// Fetches server-detected skip segments when the per-profile Skip Intros
    /// setting is on, publishing them to the controls model so the overlay can
    /// offer a Skip button. No-op when disabled; failures degrade silently to no
    /// button (older/marker-less servers). Runs once per load.
    private func loadSkipSegmentsIfEnabled() {
        guard playbackSettings.skipIntros.fetchesMarkers else { return }
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
        //    to the re-resolved safe (muxed) fallback below instead.
        if request.deliveryMode != .localRemux,
           !request.isTranscoding, !hasTriedAlternateEngine, request.externalAudioURL == nil,
           let alternate = alternateEngineKind {
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
        phase = .failed(error)
    }

    // MARK: - Progress reporting

    /// Reports the current position. Best-effort: a failed report must never
    /// interrupt playback, so errors are swallowed (and never logged with data).
    /// The same lifecycle is forwarded to Trakt so watches sync to the user's
    /// Trakt history.
    private func report(event: PlaybackEvent, isPaused: Bool, positionOverride: TimeInterval? = nil) async {
        guard let request else { return }
        let progress = PlaybackProgress(
            itemID: itemID,
            playSessionID: request.playSessionID,
            positionSeconds: positionOverride ?? engine.currentTime,
            isPaused: isPaused
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
        if !engine.isPaused {
            setPaused(true)
        }
    }

    // MARK: - Local-remux seek torture harness

    private func executeLocalRemuxSeekTortureTest() async {
        guard let session = localRemuxSession else {
            controls.remuxHarnessStatus = "Seek torture test requires an active local-remux strategy."
            return
        }
        let metrics = session.metricsController
        controls.remuxHarnessRunning = true
        metrics.resetHarnessState()

        do {
            let duration = max(engine.duration, request?.item.runtime ?? 0)
            guard duration > 120 else {
                throw NSError(
                    domain: "LocalRemuxHarness",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Title is too short for the scripted seek torture test."]
                )
            }

            let initialPaused = engine.isPaused
            let current = max(engine.currentTime, 0)
            let jumpForward = min(max(current + 600, 30), max(30, duration - 30))
            let jumpBack = max(0, min(current + 30, jumpForward - 30))
            let eofTarget = max(0, duration - 15)

            try await runTortureSeekStep("Jump +10m", target: jumpForward)
            try await runTortureSeekStep("Jump back", target: jumpBack)
            try await runRapidScrubBurst(duration: duration)
            try await runTortureSeekStep("Seek near EOF", target: eofTarget)

            metrics.setHarnessRunning(step: "Pause 60s")
            controls.remuxHarnessStatus = "Seek torture test: Pause 60s"
            setPaused(true)
            try await Task.sleep(nanoseconds: 60_000_000_000)
            if !initialPaused {
                setPaused(false)
            }

            let summary = PlaybackDiagnostics.joinParts([
                "Passed",
                metrics.snapshot.timeToFirstFrameMs.map { "TTFF \($0) ms" },
                metrics.snapshot.lastSeekLatencyMs.map { "Last seek \($0) ms" },
                metrics.snapshot.stallCount.map { "Stalls \($0)" }
            ])
            metrics.finishHarness(success: true, summary: summary)
            controls.remuxHarnessStatus = summary
        } catch is CancellationError {
            metrics.resetHarnessState()
            controls.remuxHarnessStatus = "Seek torture test cancelled."
        } catch {
            let message = (error as NSError).localizedDescription
            let summary = "Failed · \(message)"
            metrics.finishHarness(success: false, summary: summary)
            controls.remuxHarnessStatus = summary
        }

        controls.remuxHarnessRunning = false
    }

    private func runTortureSeekStep(_ label: String, target: TimeInterval) async throws {
        localRemuxSession?.metricsController.setHarnessRunning(step: label)
        controls.remuxHarnessStatus = "Seek torture test: \(label)"
        await seek(to: target)
        try await waitForPlaybackPosition(near: target)
    }

    private func runRapidScrubBurst(duration: TimeInterval) async throws {
        let targets = [
            max(15, duration * 0.20),
            max(30, duration * 0.55),
            max(45, duration * 0.33),
            max(60, duration * 0.72)
        ]
        localRemuxSession?.metricsController.setHarnessRunning(step: "Rapid scrub burst")
        controls.remuxHarnessStatus = "Seek torture test: Rapid scrub burst"
        for target in targets {
            requestSeek(to: target)
            try await Task.sleep(nanoseconds: 120_000_000)
        }
        try await waitForSeekLoopToDrain()
        if let final = targets.last {
            try await waitForPlaybackPosition(near: final)
        }
    }

    private func waitForSeekLoopToDrain(timeout: TimeInterval = 20) async throws {
        let started = Date()
        while controls.isSeeking || seekTask != nil {
            if Date().timeIntervalSince(started) > timeout {
                throw NSError(
                    domain: "LocalRemuxHarness",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Seek burst did not settle before the timeout."]
                )
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    private func waitForPlaybackPosition(
        near target: TimeInterval,
        tolerance: TimeInterval = 2,
        timeout: TimeInterval = 20
    ) async throws {
        let started = Date()
        while abs(engine.currentTime - target) > tolerance {
            if Date().timeIntervalSince(started) > timeout {
                throw NSError(
                    domain: "LocalRemuxHarness",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Player never settled near \(Int(target.rounded()))s."]
                )
            }
            try await Task.sleep(nanoseconds: 200_000_000)
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
        controls.currentSeconds = target
        controls.pendingSeekTarget = target
        controls.isSeeking = true
        latestSeekTarget = target
        if seekTask == nil {
            startSeekLoop()
        }
    }

    private func startSeekLoop() {
        seekTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Drain: process the latest pending target until none remains.
            while let next = self.takeLatestSeekTarget() {
                // If a newer target arrives while this one is in flight, we
                // can be cheap here — only the LAST one needs to be precise.
                let isFinal = (self.latestSeekTarget == nil)
                let kind: VideoSeekKind = isFinal ? .exact : .fast
                self.localRemuxSession?.metricsController.beginSeek()
                await self.engine.seek(to: next, kind: kind)
                self.localRemuxSession?.metricsController.endSeek()
            }
            self.seekTask = nil
            self.controls.isSeeking = false
            // `pendingSeekTarget` is cleared by the refresh poll once the
            // engine's `currentTime` arrives within tolerance of the target —
            // that's the moment it's safe to resume mirroring engine time.
        }
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
        localRemuxSession?.metricsController.beginSeek()
        await engine.seek(to: seconds, kind: .exact)
        localRemuxSession?.metricsController.endSeek()
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
    }

    public func setDialogEnhanceEnabled(_ enabled: Bool) {
        controls.dialogEnhanceEnabled = enabled
        engine.setDialogEnhanceEnabled(enabled)
    }

    /// Toggles play/pause from the custom transport, keeping `controls` and the
    /// server report in sync.
    public func togglePlayPause() {
        setPaused(!engine.isPaused)
    }

    public func setPaused(_ paused: Bool) {
        if paused { engine.pause() } else { engine.play() }
        // A user pause means "no progress" is expected — don't let the stall
        // watchdog misfire.
        if paused { cancelWatchdog() }
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
    public func stop() async {
        guard !didStop else { return }
        didStop = true
        prefetchTask?.cancel()
        prefetchTask = nil
        checkpointTask?.cancel()
        checkpointTask = nil
        remuxSeekTestTask?.cancel()
        remuxSeekTestTask = nil
        segmentsTask?.cancel()
        segmentsTask = nil
        autoSkipNoticeTask?.cancel()
        autoSkipNoticeTask = nil
        cancelWatchdog()
        subtitleDownloadTask?.cancel()
        subtitleDownloadTask = nil
        // Silence the engine *before* the final server report. The report is a
        // network round-trip that can take a second or two; stopping first means
        // leaving the player never keeps playing audio while it completes. Grab
        // the resume position up front since the engine is torn down here.
        let finalPosition = max(engine.furthestObservedPosition, engine.currentTime)
        let percent = watchedPercent(at: finalPosition)
        engine.stop()
        await teardownLocalRemuxSession()
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
    /// Plozzigen/mpv engines vend it so those fields aren't blank.
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

    /// The URL AVPlayer is actually playing (after any local-remux swap), used for
    /// the diagnostics "Stream" transport row.
    public var diagnosticsStreamURL: URL? { request?.streamURL }

    /// Local-remux eligibility for the active title, as a `(eligible, detail)` pair
    /// for the diagnostics overlay. `detail` is a compact reason — the eligible
    /// source facts when it qualifies, or the disqualifying reason when it doesn't.
    public var remuxEligibilitySummary: (eligible: Bool, detail: String)? {
        guard let descriptor = request?.localRemuxSource else { return nil }
        switch descriptor.eligibility(capabilities: capabilities, allowAnyDecodableHEVC: allowAnyDecodableHEVCRemux) {
        case .eligible:
            let metadata = descriptor.sourceMetadata
            let doVi = descriptor.normalizedDolbyVisionProfile.map { "DoVi P\($0)" }
            let parts = [
                metadata.container?.uppercased(),
                metadata.video?.codec?.uppercased(),
                doVi,
                metadata.audio?.codec?.uppercased()
            ].compactMap { $0 }
            return (true, parts.joined(separator: " · "))
        case .ineligible(let reason):
            return (false, reason)
        }
    }

    /// Local-remux comparison-harness snapshot, when the current playback is using
    /// the shared remux seam.
    public var localRemuxDiagnostics: PlaybackDiagnostics.RemuxDiagnostics? {
        localRemuxSession?.metricsController.snapshot
    }

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

    public func selectLocalRemuxStrategy(_ strategyID: String) {
        let resolved = LocalRemuxStrategyChoice.choice(for: strategyID)
        controls.selectedLocalRemuxStrategyID = resolved.id
        preferencesStore.saveLocalRemuxStrategyID(resolved.id)
        controls.localRemuxReloadAvailable = controls.localRemuxEligible
            && resolved.id != LocalRemuxStrategyChoice.disabledID
        if request?.deliveryMode == .localRemux, localRemuxSession?.strategy.id != resolved.id {
            controls.localRemuxEligibilityMessage = "Saved \(resolved.displayName). Reload to apply it to this playback."
            controls.remuxHarnessStatus = "Saved \(resolved.displayName). Reload to compare it against the current strategy."
        } else if controls.localRemuxEligible, resolved.id != LocalRemuxStrategyChoice.disabledID, !controls.localRemuxActive {
            controls.localRemuxEligibilityMessage = "Saved \(resolved.displayName). Use Reload now so this title stops playing through mpv."
        } else if resolved.id == LocalRemuxStrategyChoice.disabledID {
            controls.localRemuxEligibilityMessage = "Remux testing is off. This title will use normal routing."
        }
    }

    public func reloadWithSelectedLocalRemuxStrategy() {
        guard controls.localRemuxEligible else { return }
        controls.localRemuxEligibilityMessage = "Reloading with \(LocalRemuxStrategyChoice.choice(for: controls.selectedLocalRemuxStrategyID).displayName)…"
        let resume = max(engine.currentTime, controls.currentSeconds)
        Task { @MainActor [weak self] in
            await self?.startPlayback(forceTranscode: false, resumeOverride: resume > 1 ? resume : nil)
        }
    }

    public func runLocalRemuxSeekTortureTest() {
        guard remuxSeekTestTask == nil else { return }
        remuxSeekTestTask = Task { @MainActor [weak self] in
            await self?.executeLocalRemuxSeekTortureTest()
            self?.remuxSeekTestTask = nil
        }
    }

    // MARK: - Custom transport configuration

    /// Seeds the transport overlay with title/subtitle/duration facts when a
    /// stream resolves, so the controls are correct from the first frame.
    private func configureControls(for request: PlaybackRequest) {
        controls.title = request.item.title
        controls.subtitle = Self.subtitleText(for: request.item)
        controls.hasTrickplay = request.scrubPreview?.isUsable ?? false
        controls.duration = request.item.runtime ?? 0
        controls.currentSeconds = 0
        controls.bufferedSeconds = 0
        controls.isScrubbing = false
        controls.previewImage = nil
        controls.isPaused = false
        controls.localRemuxStrategies = LocalRemuxStrategyRegistry.availableChoices
        let selectedRemuxStrategyID = preferencesStore.loadLocalRemuxStrategyID()
        controls.selectedLocalRemuxStrategyID = selectedRemuxStrategyID
        if let descriptor = request.localRemuxSource {
            switch descriptor.eligibility(capabilities: capabilities, allowAnyDecodableHEVC: allowAnyDecodableHEVCRemux) {
            case .eligible:
                controls.localRemuxEligible = true
                controls.localRemuxEligibilityMessage = localRemuxActivationMessage
                    ?? "Eligible: single-layer Dolby Vision MKV with AC-3/E-AC-3 audio."
            case .ineligible(let reason):
                controls.localRemuxEligible = false
                controls.localRemuxEligibilityMessage = localRemuxActivationMessage ?? reason
            }
        } else {
            controls.localRemuxEligible = false
            controls.localRemuxEligibilityMessage = localRemuxActivationMessage
                ?? "Provider did not expose an original-file remux source for this title."
        }
        controls.localRemuxActive = request.deliveryMode == .localRemux
        controls.activeLocalRemuxStrategyName = localRemuxSession?.strategy.displayName
        controls.localRemuxReloadAvailable = controls.localRemuxEligible
            && selectedRemuxStrategyID != LocalRemuxStrategyChoice.disabledID
        controls.remuxHarnessRunning = false
        controls.remuxHarnessStatus = localRemuxSession?.metricsController.snapshot.lastHarnessResult?.summary ?? ""
    }

    /// A short secondary line for the transport bar (series · SxEx for episodes).
    private static func subtitleText(for item: MediaItem) -> String {
        var parts: [String] = []
        if let parent = item.parentTitle, !parent.isEmpty { parts.append(parent) }
        if let season = item.seasonNumber, let episode = item.episodeNumber {
            parts.append("S\(season)E\(episode)")
        } else if let episode = item.episodeNumber {
            parts.append("Episode \(episode)")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Track selection (custom player menu)

    /// Publishes the engine's audio/subtitle track lists into `controls` for the
    /// in-player track menu. Switching is routed back through the engine so the
    /// menu behaves identically across engines.
    private func loadTrackOptions() {
        let audio = engine.audioTracks
        if selectedAudioTrackID == nil {
            selectedAudioTrackID = audio.first(where: { $0.isDefault })?.id ?? audio.first?.id
        }
        controls.audioOptions = audio.map { track in
            PlayerTrackOption(id: track.id, title: track.displayTitle, isSelected: track.id == selectedAudioTrackID)
        }

        let subtitles = engine.subtitleTracks
        if subtitles.isEmpty {
            controls.subtitleOptions = []
        } else {
            var options = [PlayerTrackOption(id: PlayerTrackOption.offID, title: "Off", isSelected: selectedSubtitleTrackID == nil)]
            options.append(contentsOf: subtitles.map { track in
                PlayerTrackOption(id: track.id, title: track.displayTitle, isSelected: track.id == selectedSubtitleTrackID)
            })
            controls.subtitleOptions = options
        }
    }

    /// Selects an audio track from the menu, routed through the engine.
    public func selectAudioOption(id: Int) {
        guard let track = engine.audioTracks.first(where: { $0.id == id }) else { return }
        engine.selectAudioTrack(track)
        selectedAudioTrackID = id
        loadTrackOptions()
    }

    /// Selects a subtitle track, or turns subtitles off (`PlayerTrackOption.offID`).
    public func selectSubtitleOption(id: Int) {
        if id == PlayerTrackOption.offID {
            engine.selectSubtitleTrack(nil)
            selectedSubtitleTrackID = nil
            loadTrackOptions()
            return
        }
        guard let track = engine.subtitleTracks.first(where: { $0.id == id }) else { return }

        // Image-based subtitles (no text delivery URL — PGS/VOBSUB) can't be
        // rendered by AVPlayer. If the user picks one while on the native engine,
        // swap to the hybrid engine at the current position and apply the
        // selection there so the subtitle actually shows.
        if track.deliveryURL == nil, currentEngineKind == .native,
           let request, !request.isTranscoding, engineFactory.hybridAvailable {
            selectedSubtitleTrackID = id
            Task { await swapEngineForImageSubtitle(track) }
            return
        }

        engine.selectSubtitleTrack(track)
        selectedSubtitleTrackID = id
        loadTrackOptions()
    }

    /// Swaps from the native engine to the hybrid engine (preserving position) so
    /// an image-based subtitle the user manually selected can be rendered, then
    /// applies that selection on the new engine.
    private func swapEngineForImageSubtitle(_ track: MediaTrack) async {
        guard let request else { return }
        let resume = max(engine.furthestObservedPosition, engine.currentTime)
        await playResolved(request, engineKind: .hybrid, startPosition: resume > 1 ? resume : 0)
        engine.selectSubtitleTrack(track)
        selectedSubtitleTrackID = track.id
        loadTrackOptions()
    }

    // MARK: - Auto subtitle download

    /// If auto-download is enabled and the item lacks a suitable subtitle in the
    /// preferred language, kicks off a detached background search+download so the
    /// server fetches one. Never blocks or affects the current playback session.
    private func startAutoSubtitleDownloadIfNeeded(request: PlaybackRequest) {
        guard captionSettings.autoDownloadSubtitles else { return }
        let language = captionSettings.resolvedPreferredLanguage
        guard !request.subtitleTracks.hasSuitableSubtitle(forLanguage: language) else { return }
        guard let language, !language.isEmpty else { return }

        let provider = self.provider
        let itemID = self.itemID
        let mode = captionSettings.subtitleMode
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
