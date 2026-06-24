#if canImport(AVFoundation)
import Foundation
import Observation

/// Smooths the ugly flash/black-snap the TV produces while it re-syncs its HDMI
/// display mode when **entering** or **leaving** HDR / Dolby Vision playback.
///
/// When the dynamic range actually changes, we fade the UI to black (raise a
/// veil) so the panel's mode switch happens behind black, then fade back in once
/// the display reports it has settled (`AVDisplayManager` mode-switch-end) — or,
/// as a hard guarantee, once a safety timeout elapses. The timeout means a
/// missing/late settle callback can **never** strand the user on a black screen.
///
/// This is provider-agnostic: it keys off `HDRDisplayMode` (derived from the
/// provider's `MediaSourceMetadata`), so it behaves identically for Plex and
/// Jellyfin. The platform wiring (observing the display manager) lives in the
/// view; this model owns only the testable timing/decision logic.
@MainActor
@Observable
final class HDRTransitionModel {
    /// Veil opacity: `0` = fully clear, `1` = fully black. The view animates a
    /// black overlay to this value.
    private(set) var veilOpacity: Double = 0

    struct Configuration: Sendable {
        /// Absolute cap on how long the veil may stay up waiting for the display
        /// to settle on the **enter** path. The safety net that prevents a
        /// permanent black screen.
        var maxBlackout: TimeInterval = 4.5
        /// Minimum time the veil stays up after a settle signal, so a
        /// near-instant settle doesn't cause a visible flicker.
        var minVeil: TimeInterval = 0.35
        /// How long to wait for the black veil to finish fading in before we let
        /// the caller tear the HDR surface down. Matches the view's veil-fade
        /// animation so the panel's mode switch never shows through a half-faded
        /// frame (the "pre-empt": go solid black *before* the switch starts).
        var veilFade: TimeInterval = 0.35
        /// Absolute cap on how long the veil may stay up on the **exit** path
        /// while we wait for the display to finish switching HDR/DV → SDR. The TV
        /// can legitimately take 1–3s for that physical HDMI switch, so this is
        /// deliberately generous; it only fires as a last resort if the
        /// mode-switch-end callback never arrives, so the user is never stranded.
        var exitSettleTimeout: TimeInterval = 5.0
        init(
            maxBlackout: TimeInterval = 4.5,
            minVeil: TimeInterval = 0.35,
            veilFade: TimeInterval = 0.35,
            exitSettleTimeout: TimeInterval = 5.0
        ) {
            self.maxBlackout = maxBlackout
            self.minVeil = minVeil
            self.veilFade = veilFade
            self.exitSettleTimeout = exitSettleTimeout
        }
    }

    let configuration: Configuration
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    private var safetyTask: Task<Void, Never>?
    private var settleTask: Task<Void, Never>?

    /// True between `beginExit` and the moment the exit wait resolves (settle or
    /// timeout). While exiting, the veil is held fully black continuously and is
    /// only removed when the caller dismisses the player (which tears the veil
    /// down with the view) — so black covers the player-dismiss → Home handoff.
    private(set) var isExiting = false
    /// Set once the exit wait has resolved, so a late `waitForExit()` returns
    /// immediately and `finishExit()` can never resume a continuation twice.
    private var exitFinished = false
    private var exitWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        configuration: Configuration = Configuration(),
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        }
    ) {
        self.configuration = configuration
        self.sleep = sleep
    }

    /// Whether moving the display from `current` range to `next` requires hiding
    /// a mode switch. Pure: true only when the dynamic-range class changes.
    static func dynamicRangeWillSwitch(from current: HDRDisplayMode, to next: HDRDisplayMode) -> Bool {
        current != next
    }

    /// True while the veil is covering (any non-trivial opacity).
    var isVeiled: Bool { veilOpacity > 0 }

    /// Begin a transition if the dynamic range will switch between `current` and
    /// `next`. Returns whether a veil was raised. Used for both enter
    /// (`.sdr → HDR/DV`) and the SDR-restore on leave (`HDR/DV → .sdr`).
    @discardableResult
    func beginTransition(from current: HDRDisplayMode, to next: HDRDisplayMode) -> Bool {
        guard Self.dynamicRangeWillSwitch(from: current, to: next) else { return false }
        raiseVeil()
        return true
    }

    /// Raise the veil immediately and arm the safety timeout that guarantees it
    /// will come back down even if no settle signal ever arrives. This is the
    /// **enter** path (fade to black while the panel switches into HDR/DV, reveal
    /// on settle); the safety timeout lowers the veil.
    func raiseVeil() {
        cancelTasks()
        isExiting = false
        veilOpacity = 1
        let sleep = self.sleep
        let timeout = configuration.maxBlackout
        safetyTask = Task { @MainActor [weak self] in
            try? await sleep(timeout)
            guard !Task.isCancelled else { return }
            self?.lowerVeil()
        }
    }

    /// The display finished switching modes (`AVDisplayManager` mode-switch-end).
    /// On the **exit** path this resolves the exit wait (after a short hold) while
    /// keeping the veil black; on the **enter** path it holds for `minVeil` then
    /// reveals. No-op if the veil isn't up or a reveal/finish is already scheduled.
    func displayDidSettle() {
        if isExiting {
            finishExitAfterHold()
            return
        }
        guard veilOpacity > 0, settleTask == nil else { return }
        let sleep = self.sleep
        let hold = configuration.minVeil
        settleTask = Task { @MainActor [weak self] in
            try? await sleep(hold)
            guard !Task.isCancelled else { return }
            self?.lowerVeil()
        }
    }

    /// Drop the veil now and cancel any pending reveal/timeout work.
    func lowerVeil() {
        cancelTasks()
        veilOpacity = 0
    }

    // MARK: - Exit (HDR/DV → SDR on leaving playback)

    /// Begin the exit transition when leaving HDR/Dolby-Vision playback. If the
    /// display will switch back to SDR (`isHDR == true`), raise the veil to full
    /// black and arm the exit safety timeout, then return `true`; the caller must
    /// `awaitVeilOpaque()`, trigger the SDR restore, `await waitForExit()`, and
    /// only then dismiss. Returns `false` for SDR content (no switch to hide — the
    /// caller dismisses immediately, raising no needless black).
    @discardableResult
    func beginExit(isHDR: Bool) -> Bool {
        guard isHDR else { return false }
        cancelTasks()
        isExiting = true
        exitFinished = false
        veilOpacity = 1
        let sleep = self.sleep
        let timeout = configuration.exitSettleTimeout
        safetyTask = Task { @MainActor [weak self] in
            try? await sleep(timeout)
            guard !Task.isCancelled else { return }
            // Never strand the user on black: if mode-switch-end never arrives,
            // resolve the exit wait so the caller dismisses anyway.
            self?.finishExit()
        }
        return true
    }

    /// Wait for the black veil to finish fading in before the caller tears the
    /// HDR surface down, so the panel's mode switch starts behind solid black
    /// (the pre-empt) and never shows through a half-faded frame.
    func awaitVeilOpaque() async {
        try? await sleep(configuration.veilFade)
    }

    /// Suspend until the exit transition resolves — either the display reports it
    /// finished switching to SDR (mode-switch-end, after a short `minVeil` hold)
    /// or the exit safety timeout fires. Returns immediately if already resolved.
    /// The veil stays fully black for the entire wait, so the caller can dismiss
    /// straight into an already-SDR Home with no gap.
    func waitForExit() async {
        if exitFinished { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if exitFinished {
                continuation.resume()
            } else {
                exitWaiters.append(continuation)
            }
        }
    }

    /// Settle arrived during an exit: hold the veil for `minVeil` so the freshly
    /// restored SDR frame is stable, then resolve the exit wait. Armed at most once.
    private func finishExitAfterHold() {
        guard isExiting, !exitFinished, settleTask == nil else { return }
        let sleep = self.sleep
        let hold = configuration.minVeil
        settleTask = Task { @MainActor [weak self] in
            try? await sleep(hold)
            guard !Task.isCancelled else { return }
            self?.finishExit()
        }
    }

    /// Resolve the exit wait exactly once and wake every `waitForExit()` caller.
    /// Deliberately keeps `veilOpacity` at 1 — the veil is removed only when the
    /// caller dismisses the player, so black covers the dismiss → Home handoff.
    private func finishExit() {
        guard !exitFinished else { return }
        exitFinished = true
        cancelTasks()
        let waiters = exitWaiters
        exitWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    private func cancelTasks() {
        safetyTask?.cancel()
        safetyTask = nil
        settleTask?.cancel()
        settleTask = nil
    }
}
#endif
