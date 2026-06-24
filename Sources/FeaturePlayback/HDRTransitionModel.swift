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
        /// to settle. The safety net that prevents a permanent black screen.
        var maxBlackout: TimeInterval = 4.5
        /// Minimum time the veil stays up after a settle signal, so a
        /// near-instant settle doesn't cause a visible flicker.
        var minVeil: TimeInterval = 0.35
        init(maxBlackout: TimeInterval = 4.5, minVeil: TimeInterval = 0.35) {
            self.maxBlackout = maxBlackout
            self.minVeil = minVeil
        }
    }

    let configuration: Configuration
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    private var safetyTask: Task<Void, Never>?
    private var settleTask: Task<Void, Never>?

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
    /// will come back down even if no settle signal ever arrives.
    func raiseVeil() {
        cancelTasks()
        veilOpacity = 1
        let sleep = self.sleep
        let timeout = configuration.maxBlackout
        safetyTask = Task { @MainActor [weak self] in
            try? await sleep(timeout)
            guard !Task.isCancelled else { return }
            self?.lowerVeil()
        }
    }

    /// The display finished switching modes. Hold for `minVeil`, then reveal.
    /// No-op if the veil isn't up or a settle reveal is already scheduled.
    func displayDidSettle() {
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

    private func cancelTasks() {
        safetyTask?.cancel()
        safetyTask = nil
        settleTask?.cancel()
        settleTask = nil
    }
}
#endif
