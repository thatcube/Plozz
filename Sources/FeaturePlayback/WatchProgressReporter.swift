import CoreModels
import CoreNetworking
import Foundation
import TraktService

/// Seam back to ``PlayerViewModel`` for the live playback signals the reporter
/// samples. Held **weakly** so the reporter never retains the view model.
///
/// The engine is read through the host (not captured) on purpose: it can be
/// swapped mid-session (native ⇆ Plozzigen handoff, retry), and every report /
/// checkpoint must sample the *current* engine.
@MainActor
protocol WatchProgressReporterHost: AnyObject {
    var reporterEngineCurrentTime: TimeInterval { get }
    var reporterEngineDuration: TimeInterval { get }
    var reporterEngineIsPaused: Bool { get }
    var reporterControlsDuration: TimeInterval { get }
    var reporterRequest: PlaybackRequest? { get }
    /// The position a checkpoint should record — the view model's resume-position
    /// policy (current time, or the furthest observed point when the clock has
    /// been zeroed by a natural EOF).
    var reporterResumePosition: TimeInterval { get }
}

/// Owns progress reporting + the convergence-checkpoint loop extracted from
/// ``PlayerViewModel``: fanning the play/pause/progress/stop lifecycle out to
/// the provider and Trakt, and periodically writing the live position back so
/// progress converges across servers without waiting for the user to press Back.
///
/// Responsibilities that were fragile inline and are now in one testable place:
/// - the **defer-until-started** rule for a pause/unpause that arrives before
///   the `.start` report has been sent (``reportStateChange`` / ``reportStart``)
/// - the checkpoint **dedup + paused/stall guard** so a paused or stuck player
///   never re-writes the same position to N servers (``emitCheckpoint``)
@MainActor
final class WatchProgressReporter {
    private weak var host: WatchProgressReporterHost?
    private let provider: any MediaProvider
    private let itemID: String
    private let scrobbler: any TraktScrobbling
    private let checkpointInterval: TimeInterval
    private let onCheckpoint: @Sendable (_ position: TimeInterval, _ watchedPercent: Double) -> Void

    private var checkpointTask: Task<Void, Never>?
    private var lastCheckpointPosition: TimeInterval = 0

    /// Whether the `.start` lifecycle report has been sent. Until it has, a
    /// pause/unpause is deferred (see ``pendingPlaybackStateReport``) so the
    /// server never sees a state change for a session it doesn't know about yet.
    private(set) var hasReportedPlaybackStart = false
    /// A pause/unpause that arrived before `.start`; flushed by ``reportStart``.
    private var pendingPlaybackStateReport: Bool?

    init(
        host: WatchProgressReporterHost,
        provider: any MediaProvider,
        itemID: String,
        scrobbler: any TraktScrobbling,
        checkpointInterval: TimeInterval,
        onCheckpoint: @escaping @Sendable (_ position: TimeInterval, _ watchedPercent: Double) -> Void
    ) {
        self.host = host
        self.provider = provider
        self.itemID = itemID
        self.scrobbler = scrobbler
        self.checkpointInterval = checkpointInterval
        self.onCheckpoint = onCheckpoint
    }

    // MARK: - Reporting

    /// Reports the current position. Best-effort: a failed report must never
    /// interrupt playback, so errors are swallowed (and never logged with data).
    /// The same lifecycle is forwarded to Trakt so watches sync to the user's
    /// Trakt history.
    func report(
        event: PlaybackEvent,
        isPaused: Bool,
        positionOverride: TimeInterval? = nil,
        durationOverride: TimeInterval? = nil
    ) async {
        guard let host, let request = host.reporterRequest else { return }
        let position = positionOverride ?? host.reporterEngineCurrentTime
        let knownDuration = durationOverride ?? knownPlaybackDuration()
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
        let scrobblePercent = positionOverride.map { watchedPercent(at: $0) } ?? watchedPercentNow()
        await scrobbler.scrobble(item: request.item, progress: scrobblePercent, event: event)
    }

    /// Emits the `.start` lifecycle report, marks the session started, then
    /// flushes any pause/unpause that arrived before start (only when it differs
    /// from the started state).
    func reportStart(isPaused: Bool, positionOverride: TimeInterval?) async {
        await report(event: .start, isPaused: isPaused, positionOverride: positionOverride)
        hasReportedPlaybackStart = true
        if let pendingPaused = pendingPlaybackStateReport {
            pendingPlaybackStateReport = nil
            if pendingPaused != isPaused {
                await report(event: pendingPaused ? .pause : .unpause, isPaused: pendingPaused)
            }
        }
    }

    /// Reports a genuine pause/unpause. If the `.start` report hasn't gone out
    /// yet, the state is deferred and flushed by ``reportStart``.
    func reportStateChange(paused: Bool) {
        if hasReportedPlaybackStart {
            Task { await report(event: paused ? .pause : .unpause, isPaused: paused) }
        } else {
            pendingPlaybackStateReport = paused
        }
    }

    /// Reports a mid-play progress heartbeat (from the engine's onProgress).
    func reportProgress() {
        Task { await report(event: .progress, isPaused: false) }
    }

    // MARK: - Duration / percent

    func knownPlaybackDuration() -> TimeInterval? {
        guard let host else { return nil }
        return WatchProgressMath.knownDuration(
            engineDuration: host.reporterEngineDuration,
            controlsDuration: host.reporterControlsDuration,
            itemRuntime: host.reporterRequest?.item.runtime
        )
    }

    /// Watched percentage (0...100) from the engine's current position over the
    /// item's duration, preferring the engine's known duration and falling back
    /// to the item runtime. `0` when neither is known.
    func watchedPercentNow() -> Double {
        watchedPercent(at: host?.reporterEngineCurrentTime ?? 0)
    }

    /// Watched percentage (0...100) for an explicit `position` over the item's
    /// duration, preferring the engine's known duration and falling back to the
    /// item runtime. `0` when neither is known. Used at `stop()` so the percentage
    /// is computed from the captured final position (the engine is torn down there).
    func watchedPercent(at position: TimeInterval) -> Double {
        WatchProgressMath.watchedPercent(
            position: position,
            engineDuration: host?.reporterEngineDuration ?? 0,
            itemRuntime: host?.reporterRequest?.item.runtime
        )
    }

    // MARK: - Convergence checkpoints

    /// Starts the periodic mid-play convergence loop. Each tick fires a checkpoint
    /// (see ``emitCheckpoint``) so progress fans out to other servers roughly every
    /// ``checkpointInterval`` seconds without the user pressing Back. Cancelled and
    /// restarted defensively; `stop()` tears it down. A non-positive interval (or a
    /// default no-op hook) leaves the loop off so standalone/test players are
    /// unaffected.
    func startCheckpointLoop(seedPosition: TimeInterval) {
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
    func emitCheckpoint(includingPaused: Bool = false) {
        guard let host, host.reporterRequest != nil,
              includingPaused || !host.reporterEngineIsPaused else { return }
        let position = host.reporterResumePosition
        guard position > 1, abs(position - lastCheckpointPosition) >= 1 else { return }
        lastCheckpointPosition = position
        onCheckpoint(position, watchedPercent(at: position))
    }

    /// Forces an immediate convergence checkpoint regardless of the timer — used
    /// when the app is about to be backgrounded/suspended (the TV Home button or
    /// sleep path, which never fires the view's `onDisappear`/`stop()`), so the
    /// latest position is durably captured before the process can be killed.
    func checkpointNow() {
        emitCheckpoint(includingPaused: true)
    }

    /// Tears down the checkpoint loop (called from `stop()`).
    func cancel() {
        checkpointTask?.cancel()
        checkpointTask = nil
    }
}
