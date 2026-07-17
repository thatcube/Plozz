#if canImport(AVFoundation)
import Foundation
import Observation
import CoreModels

// MARK: - Host seam

/// Everything the ``ForegroundReloadCoordinator`` needs to read from / drive on
/// its owner during a background → foreground recovery. Kept read-mostly so the
/// coordinator owns the *generation bookkeeping* while the view model retains
/// ownership of the engine, controls, and subtitle collaborator.
@MainActor
protocol ForegroundReloadCoordinatorHost: AnyObject {
    /// Current bring-up phase. The recovery loop waits out `.loading` and only
    /// rebuilds once `.ready`.
    var reloadPhase: PlayerViewModel.Phase { get }
    /// Whether playback has been torn down (view dismissed). Aborts recovery.
    var reloadDidStop: Bool { get }
    /// The engine to rebuild. Captured once at the start of a recovery.
    var reloadEngine: any VideoEngine { get }
    /// Live token identifying the active engine; re-read at each guard so a
    /// mid-flight engine swap (retry/handoff) cancels a stale recovery.
    var reloadEngineToken: UUID { get }
    /// Whether the active engine is Plozzigen (needs track re-application after a
    /// rebuild; native AVPlayer restores its own selections).
    var reloadIsPlozzigenEngine: Bool { get }
    /// The user's play/pause *intent* (not the mirror-polluted engine flag).
    var reloadIntendsPlayback: Bool { get }
    /// The speed to re-program on the rebuilt engine.
    var reloadPlaybackSpeed: Double { get }

    /// Re-applies the remembered audio/subtitle selections to a freshly rebuilt
    /// Plozzigen engine.
    func reloadReapplyTrackSelections(to engine: any VideoEngine)
    /// Rebuilds the track-options menu after the engine came back.
    func reloadLoadTrackOptions()
    /// Mirrors the reconciled paused state onto the controls model.
    func reloadReconcilePaused(_ paused: Bool)
    /// Surfaces a failed rebuild as a terminal phase.
    func reloadFail(_ error: AppError)
}

// MARK: - Coordinator

/// Owns the background/foreground lifecycle reconciliation for a single playback
/// session.
///
/// tvOS can suspend the app (Home button, sleep, app switcher) without ever
/// firing the view's `onDisappear`/`stop()`. AetherEngine/Plozzigen tears down
/// its AVPlayer item, loopback HLS server, demuxer, and decode session on that
/// transition, so a later `.active` phase has to **rebuild** the pipeline rather
/// than call `play()` on an empty shell. The native engine remains valid and
/// no-ops its reload.
///
/// The single tricky invariant is *generation bookkeeping*: a background entry
/// bumps a generation and a foreground recovery consumes exactly that one, so
/// duplicate `.active` callbacks (which tvOS does emit) can't rebuild the same
/// session twice, and an engine swap that races the async rebuild (retry /
/// handoff) is detected and the stale recovery bails without touching the new
/// engine. Those guards are what break silently on device, so they're pinned by
/// ``ForegroundReloadCoordinatorTests``.
@MainActor
@Observable
final class ForegroundReloadCoordinator {
    private weak var host: ForegroundReloadCoordinatorHost?

    /// Incremented for each real tvOS background entry. A foreground recovery
    /// consumes exactly one generation, preventing duplicate `.active` callbacks
    /// from rebuilding the same playback session more than once.
    private var backgroundGeneration = 0
    private var pendingForegroundReloadGeneration: Int?

    /// Keeps the full-screen loading indicator visible while a suspended engine
    /// rebuilds its media pipeline at the preserved position.
    private(set) var isRecovering = false

    init(host: ForegroundReloadCoordinatorHost) {
        self.host = host
    }

    /// Marks a genuine tvOS background entry, arming exactly one pending
    /// foreground recovery.
    func markEnteredBackground() {
        backgroundGeneration += 1
        pendingForegroundReloadGeneration = backgroundGeneration
    }

    /// Restores the engine after a real background round-trip while preserving
    /// the user's paused state. No provider re-resolve or lifecycle report is
    /// emitted: Plex, Jellyfin, and file-share sources all recover through the
    /// same engine seam at their existing position and session URL.
    func resume() async {
        guard let host else { return }
        guard let generation = pendingForegroundReloadGeneration else { return }

        // Background can interrupt initial bring-up. Wait for that load to settle,
        // then rebuild the pipeline that tvOS invalidated before returning active.
        while host.reloadPhase == .loading,
              pendingForegroundReloadGeneration == generation,
              !host.reloadDidStop {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        guard pendingForegroundReloadGeneration == generation,
              host.reloadPhase == .ready,
              !host.reloadDidStop else { return }

        pendingForegroundReloadGeneration = nil
        let recoveringEngine = host.reloadEngine
        let recoveringEngineToken = host.reloadEngineToken
        isRecovering = true
        defer {
            if backgroundGeneration == generation {
                isRecovering = false
            }
        }

        do {
            try await recoveringEngine.reloadAfterForeground()
        } catch {
            guard backgroundGeneration == generation,
                  host.reloadEngineToken == recoveringEngineToken,
                  !host.reloadDidStop else { return }
            let appError = (error as? AppError) ?? .unknown(String(describing: error))
            host.reloadFail(appError)
            return
        }

        guard backgroundGeneration == generation,
              host.reloadEngineToken == recoveringEngineToken else { return }
        guard !host.reloadDidStop else {
            recoveringEngine.stop()
            return
        }

        recoveringEngine.setPlaybackSpeed(host.reloadPlaybackSpeed)
        if host.reloadIsPlozzigenEngine {
            host.reloadReapplyTrackSelections(to: recoveringEngine)
        }
        // A play press can arrive while the async rebuild is in flight. Reconcile
        // last, after restoring speed/tracks that may restart AVPlayer, and avoid a
        // duplicate pause/unpause report; the genuine user action already sent it.
        if host.reloadIntendsPlayback {
            recoveringEngine.play()
        } else {
            recoveringEngine.pause()
        }
        host.reloadReconcilePaused(!host.reloadIntendsPlayback)
        host.reloadLoadTrackOptions()
    }
}

#endif
