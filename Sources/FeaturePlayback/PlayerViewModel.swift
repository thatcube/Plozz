#if canImport(AVFoundation)
import Foundation
import AVFoundation
import Observation
import CoreModels
import CoreNetworking
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

    /// Shared, observable transport state for the custom player overlay. The
    /// view model writes live playback facts here; the input controller writes
    /// scrub state; the SwiftUI overlay reads.
    public let controls = PlayerControlsModel()

    private let provider: any MediaProvider
    private let itemID: String
    private let captionSettings: CaptionSettings
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

    /// Seek-coordinator state. `latestSeekTarget` is the most-recently-requested
    /// committed seek time; `seekTask` is the single in-flight loop that drains
    /// it. Together they guarantee rapid presses ACCUMULATE and resolve to the
    /// final target without overlapping engine seeks racing each other.
    private var latestSeekTarget: TimeInterval?
    private var seekTask: Task<Void, Never>?

    /// Persisted player preferences (e.g. last-used playback speed).
    private let preferencesStore: PlaybackPreferencesStoring

    public init(
        provider: any MediaProvider,
        itemID: String,
        captionSettings: CaptionSettings = .default,
        startPosition: TimeInterval? = nil,
        engineFactory: EngineFactory = .native,
        capabilities: MediaCapabilities = .detected(),
        preferencesStore: PlaybackPreferencesStoring = PlaybackPreferencesStore()
    ) {
        self.provider = provider
        self.itemID = itemID
        self.captionSettings = captionSettings
        self.startPositionOverride = startPosition
        self.engineFactory = engineFactory
        self.capabilities = capabilities
        self.preferencesStore = preferencesStore
        self.engine = engineFactory.makeNative(captionSettings)
        self.currentEngineKind = .native
        // Seed last-used speed so a user who set 1.25× on the last show keeps it.
        self.controls.playbackSpeed = preferencesStore.loadPlaybackSpeed()
        configureEngineCallbacks()
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
        case .native:
            return engineFactory.makeNative(captionSettings)
        }
    }

    /// Swaps the active engine when the routed kind differs from the current one,
    /// tearing the old engine down and re-pointing the UI at the new surface.
    private func switchEngine(to kind: PlaybackEngineKind) {
        guard kind != currentEngineKind else {
            plozzTrace("switchEngine: no-op, already \(kind)")
            return
        }
        plozzTrace("switchEngine: \(currentEngineKind) -> \(kind); bumping engineToken (forces host rebuild)")
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
                plozzTrace("initial engine commit: already \(kind); no host rebuild")
                return
            }
            plozzTrace("initial engine commit: \(currentEngineKind) -> \(kind); no token bump")
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
            return engineFactory.hybridAvailable ? .hybrid : nil
        case .hybrid:
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
        await startPlayback(forceTranscode: false, resumeOverride: nil)
    }

    /// Resolves a stream and brings up the player. `forceTranscode` asks the
    /// provider to bypass direct play (used by the automatic fallback); when set,
    /// `resumeOverride` carries the position the failed attempt reached so the
    /// retry resumes there instead of the provider's stale resume point.
    private func startPlayback(forceTranscode: Bool, resumeOverride: TimeInterval?) async {
        phase = .loading
        do {
            let request = try await provider.playbackInfo(for: itemID, forceTranscode: forceTranscode)
            self.request = request
            configureControls(for: request)

            // An explicit override wins over the provider's resume point so the
            // caller can force "start over" (0) or resume from a chosen second.
            let startPosition = resumeOverride ?? startPositionOverride ?? request.startPosition

            // Pick the engine from the resolved source facts (pure decision).
            var kind = EngineRouter.selectEngine(
                source: request.sourceMetadata,
                capabilities: capabilities,
                isTranscoding: request.isTranscoding,
                hybridAvailable: engineFactory.hybridAvailable
            )

            // If the subtitle that would be shown by default is image-based
            // (PGS/VOBSUB), AVPlayer can't render it — route to the hybrid engine
            // so it appears, but only when we're direct-playing and a hybrid
            // engine is available. (A file with a text-subtitle equivalent stays
            // native; see `defaultSubtitleNeedsHybridEngine`.)
            if kind == .native, !request.isTranscoding, engineFactory.hybridAvailable,
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

            plozzTrace("startPlayback: routed initial engineKind=\(kind) (transcoding=\(request.isTranscoding))")
            await playResolved(request, engineKind: kind, startPosition: startPosition)

            // Best-effort, never blocking play(): (if enabled) fetch a missing
            // subtitle in the preferred language.
            startAutoSubtitleDownloadIfNeeded(request: request)        } catch let error as AppError {
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
        plozzTrace("playResolved: engineKind=\(engineKind) start=\(startPosition) (current=\(currentEngineKind))")
        commitEngineForPlayback(engineKind)
        // Arm the stall watchdog around load() so a hang that never reports an
        // error still triggers the fallback chain instead of spinning forever.
        armPlaybackWatchdog(startPosition: startPosition)
        await Self.yieldToRunLoop()
        plozzTrace("playResolved: post-swap runloop turn reached; calling engine.load()")
        await engine.load(request: request, startPosition: startPosition)
        plozzTrace("playResolved: engine.load() RETURNED; setting phase=.ready")
        phase = .ready
        // Publish diagnostics after the engine load attempt returns, so the
        // diagnostics sampler doesn't churn SwiftUI layout during mpv init.
        diagnosticsToken = UUID()
        plozzTrace("playResolved: phase=.ready set; about to report(.start)")
        await report(event: .start, isPaused: false)
        plozzTrace("playResolved: report(.start) done")

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
        plozzTrace("handleEngineFailure: \(error) (current=\(currentEngineKind), triedAlternate=\(hasTriedAlternateEngine))")
        guard let request else {
            phase = .failed(error)
            return
        }
        let resumeFrom = max(engine.furthestObservedPosition, engine.currentTime)
        let resume = resumeFrom > 1 ? resumeFrom : (startPositionOverride ?? request.startPosition)

        // 1) Direct play failed on the chosen engine → try the other engine once,
        //    re-using the same raw stream (no re-resolve needed).
        if !request.isTranscoding, !hasTriedAlternateEngine, let alternate = alternateEngineKind {
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
                await self.engine.seek(to: next, kind: kind)
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

    /// Call when leaving playback: report a final stop so the server records the
    /// resume point, then tear the engine down.
    public func stop() async {
        cancelWatchdog()
        subtitleDownloadTask?.cancel()
        subtitleDownloadTask = nil
        // Silence the engine *before* the final server report. The report is a
        // network round-trip that can take a second or two; stopping first means
        // leaving the player never keeps playing audio while it completes. Grab
        // the resume position up front since the engine is torn down here.
        let finalPosition = max(engine.furthestObservedPosition, engine.currentTime)
        engine.stop()
        await report(event: .stop, isPaused: true, positionOverride: finalPosition)
    }

    // MARK: - View / diagnostics access

    /// The live `AVPlayer` backing the active (native) engine, exposed for the
    /// AVFoundation-specific diagnostics sampler and the system player view.
    /// Returns `nil` for a non-AVFoundation engine (diagnostics is best-effort).
    public var player: AVPlayer? { (engine as? NativeVideoEngine)?.underlyingPlayer }

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
    /// transcode). Read by the playback diagnostics overlay's Source row.
    public var deliveryMode: PlaybackDiagnostics.PlaybackMode { request?.deliveryMode ?? .unknown }

    /// Provider source facts (codec/HDR/channels/…) for the playing item, used
    /// to populate the playback diagnostics overlay.
    public var sourceMetadata: MediaSourceMetadata? { request?.sourceMetadata }

    /// Scrubbing-preview thumbnails for the playing item, if the server has them.
    public var trickplay: TrickplayManifest? { request?.trickplay }

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
        controls.title = request.item.title
        controls.subtitle = Self.subtitleText(for: request.item)
        controls.hasTrickplay = request.trickplay?.isUsable ?? false
        controls.duration = request.item.runtime ?? 0
        controls.currentSeconds = 0
        controls.bufferedSeconds = 0
        controls.isScrubbing = false
        controls.previewImage = nil
        controls.isPaused = false
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
