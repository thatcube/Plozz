#if canImport(AVFoundation)
import CoreModels
import CoreNetworking
import Foundation

/// Seam back to the owner (``PlayerViewModel``) for the surrounding-playback
/// state the next-episode machinery reads. The coordinator holds a *weak*
/// reference so it never retains the view model (which SwiftUI owns).
///
/// - `upNextEngine` is a **getter** on purpose: the engine can be swapped
///   mid-session (native ⇆ Plozzigen handoff, image-subtitle swap, retry), so
///   the windowed-prefetch decision and the first-frame poll must always read
///   the *current* engine, exactly as the inline code did.
/// - `nextEpisodeCandidate` mirrors ``PlayerViewModel/nextEpisode`` (resolved by
///   the neighbor lookup and read widely), so it stays owned by the view model.
/// - `upNextResolveAndRoute` funnels the (network-bound) stream resolve + engine
///   route back through the view model's single resolver.
@MainActor
protocol NextEpisodeCoordinatorHost: AnyObject {
    var nextEpisodeCandidate: MediaItem? { get }
    var upNextEngine: any VideoEngine { get }
    var upNextProvider: any MediaProvider { get }
    var upNextContentDisplayMode: HDRDisplayMode { get }
    var upNextCurrentEngineKind: PlaybackEngineKind { get }
    var upNextBringUpStartedAt: Date? { get }
    func upNextResolveAndRoute(
        itemID: String, mediaSourceID: String?, forceTranscode: Bool
    ) async throws -> PlayerViewModel.PrefetchedPlayback
}

/// Owns the fast-hand-off next-episode machinery extracted from
/// ``PlayerViewModel``: the one-shot next-episode prefetch (eager for
/// idempotent providers, windowed for Jellyfin), the spoiler-aware Up Next card,
/// and the single bring-up first-frame gate.
///
/// The fragile semantics this type preserves exactly:
/// - **The prefetch is one-shot** (`didStartNextEpisodePrefetch`): a failure
///   never re-arms, so a marker-less Jellyfin server can't re-POST every
///   progress tick and orphan a freshly minted session.
/// - **A cancelled-after-resolve prefetch releases its session** so a back-out
///   never orphans a Jellyfin play/transcode session.
/// - **`awaitingFirstFrame` holds the bring-up spinner** until the engine is
///   genuinely presenting moving frames (one continuous tap → first-frame
///   indicator), and clears immediately when the engine is already presenting.
@MainActor
@Observable
final class NextEpisodeCoordinator {
    @ObservationIgnored private weak var host: NextEpisodeCoordinatorHost?
    /// Shared, stably-referenced controls model (never reassigned on the VM).
    @ObservationIgnored private let controls: PlayerControlsModel
    @ObservationIgnored private let playbackSettings: PlaybackSettings
    @ObservationIgnored private let spoilerSettings: SpoilerSettings

    /// A resolved, engine-routed playback for the NEXT episode, prefetched during
    /// this episode so the hand-off is near-instant. Handed to the incoming
    /// player via ``consumePrefetchedNext(matching:)``; released on teardown if
    /// the viewer backs out without advancing (so a Jellyfin session isn't
    /// orphaned).
    private(set) var prefetchedNext: PlayerViewModel.PrefetchedPlayback?

    /// True from bring-up until the engine is genuinely presenting moving frames.
    /// Drives the bring-up spinner via the view model's `videoDisplayState`.
    private(set) var awaitingFirstFrame = false

    /// Background resolve of the NEXT episode's playback (see ``prefetchedNext``).
    @ObservationIgnored private var nextEpisodePrefetchTask: Task<Void, Never>?
    /// Fires the next-episode prefetch at most once per player.
    @ObservationIgnored private var didStartNextEpisodePrefetch = false
    /// Polls the engine for its first presented frame so the bring-up spinner can
    /// be held until the picture is actually on screen.
    @ObservationIgnored private var firstFrameTask: Task<Void, Never>?
    /// Throttle for the near-end Up Next diagnostic.
    @ObservationIgnored private var lastUpNextDiagAt = Date.distantPast

    /// How long before the end to prefetch the next episode when the provider's
    /// `playbackInfo` is NOT idempotent (Jellyfin) and no closing-credits marker
    /// opened the Up Next window — a safety net for marker-less servers so the
    /// hand-off is still resolved ahead of time without orphaning a session early.
    static let windowedNextPrefetchLeadTime: TimeInterval = 90

    init(
        host: NextEpisodeCoordinatorHost,
        controls: PlayerControlsModel,
        playbackSettings: PlaybackSettings,
        spoilerSettings: SpoilerSettings
    ) {
        self.host = host
        self.controls = controls
        self.playbackSettings = playbackSettings
        self.spoilerSettings = spoilerSettings
    }

    private var engine: (any VideoEngine)? { host?.upNextEngine }

    // MARK: - Next-episode prefetch (fast hand-off)

    /// Resolves the NEXT episode's stream + engine ahead of the hand-off and
    /// caches it in ``prefetchedNext``. Fires at most once. Best-effort: a failure
    /// just means the hand-off resolves normally (no regression). The eager path
    /// (idempotent providers) calls this from the neighbor resolve; the windowed
    /// path (Jellyfin) calls it from ``maybeStartWindowedNextPrefetch()``.
    func startNextEpisodePrefetch(trigger: String) {
        guard let host, let next = host.nextEpisodeCandidate,
              !didStartNextEpisodePrefetch, prefetchedNext == nil,
              nextEpisodePrefetchTask == nil else { return }
        didStartNextEpisodePrefetch = true
        HandoffDiagnostics.emit("prefetch START trigger=\(trigger) next=\(next.id) provider=\(host.upNextProvider.kind.rawValue) idempotent=\(host.upNextProvider.kind.playbackInfoIsIdempotent)")
        let prefetchStart = Date()
        nextEpisodePrefetchTask = Task { @MainActor [weak self] in
            guard let self, let host = self.host else { return }
            do {
                let resolved = try await host.upNextResolveAndRoute(
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
    func maybeStartWindowedNextPrefetch() {
        guard let host, host.nextEpisodeCandidate != nil, prefetchedNext == nil,
              !didStartNextEpisodePrefetch, nextEpisodePrefetchTask == nil else { return }
        guard !host.upNextProvider.kind.playbackInfoIsIdempotent else { return }
        let engine = host.upNextEngine
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
    func logUpNextStateIfNearEnd() {
        guard let host, HandoffDiagnostics.isEnabled, host.nextEpisodeCandidate != nil else { return }
        let cDur = controls.duration
        let cCur = controls.currentSeconds
        let remaining = cDur - cCur
        let durUnknown = !(cDur.isFinite && cDur > 0)
        guard durUnknown || (remaining > 0 && remaining <= 60) else { return }
        guard Date().timeIntervalSince(lastUpNextDiagAt) >= 8 else { return }
        lastUpNextDiagAt = Date()
        let creditsStart = controls.skippableSegments.first { $0.kind == .credits }?.start
        HandoffDiagnostics.emit("upnext-state cDur=\(Int(cDur)) cCur=\(Int(cCur)) eDur=\(Int(host.upNextEngine.duration)) remaining=\(Int(remaining)) creditsStart=\(creditsStart.map { Int($0) }.map(String.init) ?? "none") card=\(controls.upNext != nil) show=\(playbackSettings.showUpNextCard) marker=\(controls.hasCreditsMarker) nearEndByTime=\(controls.isNearEndByTime) active=\(controls.upNextActive) presenting=\(controls.isPresentingUpNext) lead=\(Int(controls.upNextLeadSeconds))")
    }

    /// Hands the prefetched next-episode resolution to the incoming player and
    /// clears it locally so teardown won't release the session being adopted.
    /// Returns `nil` when there's no prefetch or it doesn't match `itemID` (the
    /// hand-off then resolves normally). Call this synchronously BEFORE `stop()`.
    func consumePrefetchedNext(matching itemID: String) -> PlayerViewModel.PrefetchedPlayback? {
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
    func shouldPreserveDisplayMode(forNext next: PlayerViewModel.PrefetchedPlayback?) -> Bool {
        guard let host else { return false }
        let curMode = host.upNextContentDisplayMode
        let nextMode = next.map { HDRDisplayMode($0.request.sourceMetadata) }
        let bothPlozzigen = host.upNextCurrentEngineKind == .plozzigen && next?.engineKind == .plozzigen
        let preserve = bothPlozzigen && (nextMode?.isHDR ?? false) && nextMode == curMode
        HandoffDiagnostics.emit("handoff display cur=\(curMode) next=\(nextMode.map { "\($0)" } ?? "none") bothPlozzigen=\(bothPlozzigen) preserve=\(preserve)")
        return preserve
    }

    /// Releases a prefetched-but-unadopted server session so a back-out doesn't
    /// orphan a Jellyfin play/transcode session. A no-op for idempotent providers
    /// (Plex/SMB create no server-side state). Best-effort.
    private func releasePrefetchedSession(_ request: PlaybackRequest) async {
        guard let host, !host.upNextProvider.kind.playbackInfoIsIdempotent else { return }
        guard let sessionID = request.playSessionID, !sessionID.isEmpty else { return }
        let progress = PlaybackProgress(
            itemID: request.item.id, playSessionID: sessionID, positionSeconds: 0, isPaused: true)
        try? await host.upNextProvider.reportPlayback(progress, event: .stop)
        PlozzLog.playback.info("Released orphaned prefetched next-episode session")
    }

    /// Cancels the in-flight next-episode prefetch (its session, if any, is
    /// released separately by ``releaseOrphanedPrefetchIfNeeded()`` after the
    /// engine is silenced so cleanup never delays stopping playback).
    func cancelPrefetch() {
        nextEpisodePrefetchTask?.cancel()
        nextEpisodePrefetchTask = nil
    }

    /// Releases any prefetched-but-unadopted next-episode session on teardown.
    func releaseOrphanedPrefetchIfNeeded() async {
        if let orphan = prefetchedNext {
            prefetchedNext = nil
            await releasePrefetchedSession(orphan.request)
        }
    }

    /// Releases a specific unadopted session (e.g. an adopted-but-never-committed
    /// incoming playback owned by the view model) through the same best-effort path.
    func releaseSession(_ request: PlaybackRequest) async {
        await releasePrefetchedSession(request)
    }

    // MARK: - First-frame gate (single bring-up spinner)

    /// Minimum forward motion of the rendered clock past its bring-up baseline
    /// before we call the picture "on screen". Small enough that the spinner drops
    /// as the picture appears, but above the pinned (buffering) clock's noise floor
    /// — while AVPlayer holds the parked frame in `waitingToPlay` the clock is
    /// steady, so a couple of frames of real advance is an unambiguous "playing".
    private static let firstFramePresentThreshold: TimeInterval = 0.10

    /// Holds the bring-up spinner until the engine is genuinely presenting moving
    /// frames, so tap → first frame shows ONE continuous indicator. Called after
    /// `engine.load()`, passing the resolved `resumeClock` (start/resume position).
    ///
    /// The true "first frame on screen" signal is the engine's rendered clock
    /// *advancing past* where it was pinned during bring-up — NOT
    /// `preventsDisplaySleep` alone. On the native path `preventsDisplaySleep`
    /// (`timeControlStatus == .playing`) already only flips once frames present,
    /// so it's unaffected. But on the Plozzigen/custom-source path
    /// `preventsDisplaySleep` is `state == .playing`, which flips the instant the
    /// play command is issued (~a beat after load) — up to ~20s before a cold
    /// SMB/WebDAV source actually renders its first frame. Gating on `preventsDisplaySleep`
    /// alone therefore dropped the spinner ~20s early, leaving a black screen that
    /// looked broken. Requiring the clock to have advanced past the buffering
    /// baseline holds the single bring-up spinner across the whole cold-start,
    /// however slow the connection — and clears the instant playback truly starts.
    func beginAwaitingFirstFrame(resumeClock: TimeInterval) {
        guard let host else { return }
        firstFrameTask?.cancel()
        // The clock is pinned at the resume/start position while AVPlayer buffers
        // (it holds the last frame in `waitingToPlay`); `max` guards a baseline
        // captured before the resume seek has settled the clock.
        let baselineClock = max(host.upNextEngine.currentTime, resumeClock)
        awaitingFirstFrame = true
        firstFrameTask = Task { @MainActor [weak self] in
            // Poll for the rendered clock advancing past the buffering baseline
            // while the engine reports playing — finer than the ~report-cadence
            // `onProgress`, so the spinner drops the instant the picture is up.
            // A true hang is handled by the existing playback watchdog, not here.
            while !Task.isCancelled {
                guard let self, self.awaitingFirstFrame, let host = self.host else { return }
                if host.upNextEngine.preventsDisplaySleep,
                   host.upNextEngine.currentTime > baselineClock + Self.firstFramePresentThreshold {
                    self.awaitingFirstFrame = false
                    if let start = host.upNextBringUpStartedAt {
                        HandoffDiagnostics.emit("first-frame PRESENTED total=\(HandoffDiagnostics.ms(start)) engine=\(host.upNextCurrentEngineKind.rawValue)")
                    }
                    return
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    /// Tears down the first-frame gate on any terminal path (stop / failure) so
    /// the poll never lingers and the spinner never sticks.
    func clearFirstFrameWait() {
        firstFrameTask?.cancel()
        firstFrameTask = nil
        awaitingFirstFrame = false
    }

    // MARK: - Up Next card

    /// Builds the spoiler-aware Up Next presentation for the resolved next episode
    /// and publishes it to the controls model — or clears it when there's no next
    /// episode or the card is disabled. The container only ever shows the card
    /// during the closing-credits window (see ``PlayerControlsModel/upNextActive``).
    func updateUpNextCard() {
        guard playbackSettings.showUpNextCard, let next = host?.nextEpisodeCandidate else {
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
    static func upNextMeta(for item: MediaItem) -> String? {
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
    static func upNextRuntimeLabel(_ seconds: TimeInterval) -> String {
        let totalMinutes = max(0, Int(seconds / 60))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        return "\(minutes)m"
    }
}
#endif
