#if canImport(AVFoundation)
import Foundation
import AVFoundation
import Observation
import CoreModels
import CoreNetworking

// MARK: - Failure fallback policy (pure)

/// The next step to take when the active engine reports a failure. Produced by
/// ``EngineFailurePolicy/decide(...)`` so the *decision* (which is the part that
/// historically broke silently — a guard that fires twice, or a stale callback
/// that isn't ignored) is pure and directly unit-testable, separate from the
/// engine/task machinery that carries it out.
enum EngineFailureAction: Equatable {
    /// The callback belongs to an engine we've already swapped away from — ignore.
    case ignoreStale
    /// No resolved request to retry — surface the error.
    case failNoRequest
    /// Rebuild a *fresh* Plozzigen instance for the same network-file source and
    /// re-resolve (drains the old SMB session first). Fires at most once.
    case retryFreshNetworkFile(resume: TimeInterval)
    /// Re-resolve on the *other* engine at the last known position. Fires at most
    /// once.
    case swapAlternate(kind: PlaybackEngineKind, resume: TimeInterval)
    /// Both engines exhausted (or none to swap to) — force a server transcode,
    /// resuming where the failed attempt left off. Fires at most once.
    case forceServerTranscode(resume: TimeInterval?)
    /// Every fallback has been tried (or we were already transcoding) — surface
    /// the error.
    case exhausted
}

/// The "each fallback fires at most once" bookkeeping. Kept as its own value so
/// the policy is a pure function of (facts, state) and the whole fallback chain
/// can be exercised in a test by feeding failures in sequence.
struct EngineFallbackState: Equatable {
    var hasTriedAlternateEngine = false
    var hasRetriedNetworkFileEngine = false
    var hasAttemptedTranscodeFallback = false
}

/// The cross-engine fallback decision, extracted from
/// `PlayerViewModel.handleEngineFailure` as a pure function.
///
/// Dual-provider/engine safety: this only *chooses*; the coordinator still owns
/// engine construction and hand-off. Keeping the decision pure means Plex and
/// Jellyfin failures walk exactly the same chain, and the fragile once-only
/// guards can be pinned with tests instead of discovered on a device.
enum EngineFailurePolicy {
    /// - Parameters:
    ///   - tokenMatches: the failing engine is still the active one.
    ///   - hasRequest: a resolved `PlaybackRequest` exists to retry.
    ///   - isNetworkFile: the source is a typed network file (SMB/WebDAV) — only
    ///     Plozzigen may reinterpret it; native URL loaders must never touch it.
    ///   - isTranscoding: the current attempt is already a server transcode.
    ///   - hasExternalAudio: the source pairs a separate audio track (adaptive) —
    ///     only the hybrid engine can mux it, so a native swap would play silent.
    ///   - resume: the position to resume the retry at.
    ///   - state: the once-only guards, mutated as each branch fires.
    static func decide(
        tokenMatches: Bool,
        hasRequest: Bool,
        isNetworkFile: Bool,
        isTranscoding: Bool,
        hasExternalAudio: Bool,
        currentEngineKind: PlaybackEngineKind,
        alternateEngineKind: PlaybackEngineKind?,
        resume: TimeInterval,
        state: inout EngineFallbackState
    ) -> EngineFailureAction {
        guard tokenMatches else { return .ignoreStale }
        guard hasRequest else { return .failNoRequest }

        // 1a) A network-file source that failed on Plozzigen retries a *fresh*
        //     Plozzigen instance once — re-using the same raw stream, not the
        //     other engine (native can't reinterpret a typed network file).
        if isNetworkFile, currentEngineKind == .plozzigen, !state.hasRetriedNetworkFileEngine {
            state.hasRetriedNetworkFileEngine = true
            return .retryFreshNetworkFile(resume: resume)
        }

        // 1b) Direct play failed on the chosen engine → try the other engine once.
        //     Skipped for an adaptive source (separate audio track): only the
        //     hybrid engine can mux it, so swapping to native would play silent
        //     video. Also skipped when the only alternate is native AVPlayer and
        //     the source is a typed network file.
        if !isTranscoding, !state.hasTriedAlternateEngine, !hasExternalAudio,
           let alternate = alternateEngineKind,
           !(alternate == .native && isNetworkFile) {
            state.hasTriedAlternateEngine = true
            return .swapAlternate(kind: alternate, resume: resume)
        }

        // 2) Both engines exhausted (or none to swap to) → force a server
        //    transcode once, resuming where the failed attempt left off.
        if !isNetworkFile, !isTranscoding, !state.hasAttemptedTranscodeFallback {
            state.hasAttemptedTranscodeFallback = true
            return .forceServerTranscode(resume: resume > 1 ? resume : nil)
        }

        // 3) Already transcoding (or out of options): surface the error.
        return .exhausted
    }
}

// MARK: - Host seam

/// The `PlayerViewModel`-owned concerns the coordinator drives back into: the
/// current resolved request, subtitle style for engine construction, phase and
/// diagnostics, and the two bring-up orchestrators (`playResolved` / re-resolve
/// via `startPlayback`). A weak reference — the view model owns the coordinator.
@MainActor
protocol EngineHandoffCoordinatorHost: AnyObject {
    /// Current subtitle appearance, read when a fresh engine is constructed.
    var handoffStyle: SubtitleStyle { get }
    /// The resolved request currently playing (nil before the first resolve).
    var handoffRequest: PlaybackRequest? { get }
    /// Item id, for hand-off diagnostics only.
    var handoffItemID: String { get }
    /// A user/resume start-position override, when one was supplied.
    var handoffStartPositionOverride: TimeInterval? { get }
    /// Whether the content's dynamic range is HDR (drives whether a fresh-engine
    /// retry preserves the display mode across the swap).
    var handoffContentDisplayModeIsHDR: Bool { get }

    /// (Re)wire the active engine's callbacks after a swap. Owned by the view
    /// model because the closures fan out into its collaborators.
    func handoffConfigureEngineCallbacks()
    /// Bring a resolved request up on `engineKind` at `startPosition`.
    func handoffPlayResolved(
        _ request: PlaybackRequest,
        engineKind: PlaybackEngineKind,
        startPosition: TimeInterval
    ) async
    /// Re-resolve from the provider (optionally forcing a server transcode).
    func handoffStartPlayback(forceTranscode: Bool, resumeOverride: TimeInterval?) async
    /// Move the player to a new phase (loading / failed).
    func handoffSetPhase(_ phase: PlayerViewModel.Phase)
    /// Release any first-frame hand-off gate when playback fails terminally.
    func handoffClearFirstFrameWait()
}

// MARK: - Coordinator

/// Owns the active `VideoEngine` instance and everything about *swapping* it:
/// construction, the token that re-hosts the SwiftUI video surface, tear-down,
/// the stall watchdog, and the cross-engine failure fallback chain.
///
/// Extracted from `PlayerViewModel` so the engine's lifecycle (the part that
/// causes forever-spinners and landed-but-frozen swaps) lives in one place with
/// the decision logic pinned by `EngineFailurePolicy` tests. The view model
/// reads `engine`/`currentEngineKind`/`engineToken` through thin forwarders and
/// keeps orchestrating bring-up (`playResolved` / `startPlayback`); it hands the
/// mechanics here.
@MainActor
@Observable
final class EngineHandoffCoordinator {
    @ObservationIgnored private weak var host: EngineHandoffCoordinatorHost?
    @ObservationIgnored private let engineFactory: EngineFactory
    @ObservationIgnored private let initialStyle: SubtitleStyle
    @ObservationIgnored private let watchdogTimeout: TimeInterval

    /// The active engine. A `var` so the cross-engine fallback can swap engines
    /// at runtime (e.g. a failed native attempt → Plozzigen, or vice-versa).
    private(set) var engine: any VideoEngine
    /// Which engine ``engine`` currently is, so swaps know the alternate.
    private(set) var currentEngineKind: PlaybackEngineKind
    /// Bumped whenever ``engine`` is swapped, so the SwiftUI player re-hosts the
    /// new engine's bare video surface (`.id(engineToken)`).
    private(set) var engineToken = UUID()

    /// Once-only fallback guards — see ``EngineFailurePolicy``.
    @ObservationIgnored private var fallbackState = EngineFallbackState()
    /// Bumped the moment the first routed engine is committed; suppresses the
    /// unnecessary `engineToken` bump for that first selection.
    @ObservationIgnored private var hasCommittedInitialEngine = false

    @ObservationIgnored private var watchdogTask: Task<Void, Never>?
    /// Stall recovery runs OFF ``watchdogTask``: recovery re-arms the watchdog
    /// (via `playResolved` → ``armPlaybackWatchdog``), which cancels
    /// ``watchdogTask``. If recovery ran on that same task it would cancel its
    /// own in-flight re-resolve.
    @ObservationIgnored private var recoveryTask: Task<Void, Never>?

    init(
        host: EngineHandoffCoordinatorHost,
        engineFactory: EngineFactory,
        adopted: PlayerViewModel.PrefetchedPlayback?,
        initialStyle: SubtitleStyle,
        watchdogTimeout: TimeInterval = 30
    ) {
        self.host = host
        self.engineFactory = engineFactory
        self.initialStyle = initialStyle
        self.watchdogTimeout = watchdogTimeout

        // Boot directly on the engine the hand-off already resolved, so an
        // adopted prefetch skips the native→Plozzigen swap entirely — no
        // mid-bring-up engine switch, no SDR-drop→DV-resync, one loading
        // indicator. Falls back to native when there's no adopted decision
        // (fresh launch) or Plozzigen isn't linked.
        if let adopted, adopted.engineKind == .plozzigen,
           let makePlozzigen = engineFactory.makePlozzigen, let plozzigen = makePlozzigen() {
            self.engine = plozzigen
            self.currentEngineKind = .plozzigen
            HandoffDiagnostics.emit("engine BOOT plozzigen (adopted; no native→plozzigen swap)")
        } else {
            self.engine = engineFactory.makeNative(initialStyle)
            self.currentEngineKind = .native
        }
    }

    // MARK: Engine construction / swapping

    private var style: SubtitleStyle { host?.handoffStyle ?? initialStyle }

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

    private func clearEngineCallbacks() {
        engine.onProgress = nil
        engine.onFailure = nil
        engine.onEnded = nil
        engine.onTracksChanged = nil
        engine.onSubtitleCues = nil
        engine.onSecondarySubtitleCues = nil
    }

    /// Swaps the active engine when the routed kind differs from the current one,
    /// tearing the old engine down and re-pointing the UI at the new surface.
    private func switchEngine(to kind: PlaybackEngineKind) {
        guard kind != currentEngineKind else { return }
        clearEngineCallbacks()
        engine.stop()
        engine = makeEngine(kind)
        currentEngineKind = kind
        engineToken = UUID()
        host?.handoffConfigureEngineCallbacks()
    }

    private func replaceEngineForRetry(
        _ kind: PlaybackEngineKind,
        preserveDisplayMode: Bool
    ) async {
        let oldEngine = engine
        clearEngineCallbacks()
        oldEngine.stop(preserveDisplayMode: preserveDisplayMode)
        // Deterministically drain the old engine's leased transport (SMB session +
        // source cursor) before opening a fresh one, so the retry's re-resolve
        // doesn't race the old cursor's asynchronous deinit release — the race
        // that made the previous fresh-engine retry re-fail in ~3ms.
        await oldEngine.drainTransport()
        engine = makeEngine(kind)
        currentEngineKind = kind
        engineToken = UUID()
        host?.handoffConfigureEngineCallbacks()
    }

    /// Commits the first routed engine without forcing a host `.id` rebuild.
    /// Subsequent swaps use the normal token-bumping `switchEngine` path.
    func commitEngineForPlayback(_ kind: PlaybackEngineKind) {
        guard hasCommittedInitialEngine else {
            hasCommittedInitialEngine = true
            guard kind != currentEngineKind else { return }
            clearEngineCallbacks()
            engine.stop()
            engine = makeEngine(kind)
            currentEngineKind = kind
            host?.handoffConfigureEngineCallbacks()
            return
        }
        switchEngine(to: kind)
    }

    /// The engine to try when the current one fails: the opposite engine, but
    /// only if it's actually available (no Plozzigen → nothing to swap to).
    private var alternateEngineKind: PlaybackEngineKind? {
        switch currentEngineKind {
        case .native:
            // AVPlayer failed. Try Plozzigen (AetherEngine): it fetches the source
            // itself and remuxes on-device. If it isn't wired in, there's nothing
            // to swap to → fall through to the server-transcode safety net.
            return engineFactory.plozzigenAvailable ? .plozzigen : nil
        case .hybrid, .plozzigen:
            // On-device decode failed — fall back to native (server-transcode
            // safety net).
            return .native
        }
    }

    // MARK: Stall watchdog

    /// Watches the active engine for stalled start-up: if playback never makes
    /// real progress within ``watchdogTimeout``, the engine is treated as stalled
    /// and the cross-engine / transcode fallback chain runs.
    func armPlaybackWatchdog(startPosition: TimeInterval) {
        watchdogTask?.cancel()
        let timeout = watchdogTimeout
        let threshold = startPosition + 0.5
        let watchedEngineToken = engineToken
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
                // Run recovery on a SEPARATE task, not this watchdog task.
                self.launchStallRecovery(token: watchedEngineToken)
            }
        }
    }

    /// Runs stall recovery off ``watchdogTask`` (see ``recoveryTask``). Replaces
    /// any in-flight recovery so a later watchdog fire can't stack two retries.
    private func launchStallRecovery(token: UUID) {
        recoveryTask?.cancel()
        recoveryTask = Task { [weak self] in
            guard let self else { return }
            await self.handleEngineFailure(.invalidResponse, sourceEngineToken: token)
        }
    }

    func cancelWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = nil
    }

    /// Cancels both the stall watchdog and any in-flight stall recovery. Used on
    /// teardown so a pending recovery can't resurrect a stopped player.
    func cancelWatchdogAndRecovery() {
        watchdogTask?.cancel()
        watchdogTask = nil
        recoveryTask?.cancel()
        recoveryTask = nil
    }

    // MARK: Cross-engine failure fallback

    /// Formats the typed `.unknown` payload as a redacted ` detail=…` suffix for a
    /// failure log line (empty string for classified errors or an empty payload),
    /// so a stall/retry line names the underlying throw without leaking URLs or
    /// credentials.
    private static func redactedFailureDetail(_ error: AppError) -> String {
        guard case .unknown(let message) = error, !message.isEmpty else { return "" }
        return " detail=\(HandoffDiagnostics.redactedDetail(message))"
    }

    /// Decides what to do when the active engine reports a playback failure,
    /// following the fallback chain (see ``EngineFailurePolicy``) and carrying out
    /// the chosen action. Each step fires at most once so the chain can never loop.
    func handleEngineFailure(_ error: AppError, sourceEngineToken: UUID) async {
        guard let host else { return }
        let detail = Self.redactedFailureDetail(error)
        let itemID = host.handoffItemID
        let request = host.handoffRequest

        let isNetworkFile: Bool
        if case .some(.networkFile) = request?.playbackSource {
            isNetworkFile = true
        } else {
            isNetworkFile = false
        }

        let resumeFrom = max(engine.furthestObservedPosition, engine.currentTime)
        let resume = resumeFrom > 1
            ? resumeFrom
            : (host.handoffStartPositionOverride ?? request?.startPosition ?? 0)

        let action = EngineFailurePolicy.decide(
            tokenMatches: sourceEngineToken == engineToken,
            hasRequest: request != nil,
            isNetworkFile: isNetworkFile,
            isTranscoding: request?.isTranscoding ?? false,
            hasExternalAudio: request?.externalAudioURL != nil,
            currentEngineKind: currentEngineKind,
            alternateEngineKind: alternateEngineKind,
            resume: resume,
            state: &fallbackState
        )

        switch action {
        case .ignoreStale:
            HandoffDiagnostics.emit(
                "engine FAILURE_IGNORED stale-callback item=\(itemID) "
                    + "error=\(HandoffDiagnostics.errorCode(error))\(detail)"
            )

        case .failNoRequest:
            HandoffDiagnostics.emit(
                "engine FAILED item=\(itemID) request=nil "
                    + "error=\(HandoffDiagnostics.errorCode(error))\(detail)"
            )
            host.handoffSetPhase(.failed(error))

        case .retryFreshNetworkFile(let resume):
            guard let request else { host.handoffSetPhase(.failed(error)); return }
            HandoffDiagnostics.emit(
                "engine RETRY_FRESH item=\(itemID) engine=plozzigen "
                    + "error=\(HandoffDiagnostics.errorCode(error))\(detail)"
            )
            host.handoffSetPhase(.loading)
            await replaceEngineForRetry(.plozzigen, preserveDisplayMode: host.handoffContentDisplayModeIsHDR)
            await host.handoffPlayResolved(request, engineKind: .plozzigen, startPosition: resume)

        case .swapAlternate(let kind, let resume):
            guard let request else { host.handoffSetPhase(.failed(error)); return }
            PlozzLog.playback.info("Engine failed; swapping to the alternate engine")
            await host.handoffPlayResolved(request, engineKind: kind, startPosition: resume)

        case .forceServerTranscode(let resume):
            PlozzLog.playback.info("Direct play failed; retrying with server transcode")
            await host.handoffStartPlayback(forceTranscode: true, resumeOverride: resume)

        case .exhausted:
            HandoffDiagnostics.emit(
                "engine FAILED item=\(itemID) engine=\(currentEngineKind.rawValue) "
                    + "error=\(HandoffDiagnostics.errorCode(error))\(detail) exhausted=true"
            )
            host.handoffClearFirstFrameWait()
            host.handoffSetPhase(.failed(error))
        }
    }
}
#endif
