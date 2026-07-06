#if canImport(UIKit)
import UIKit

/// Centralised owner of the process-wide "keep the display awake" assertion
/// (`UIApplication.isIdleTimerDisabled`) for video playback.
///
/// The tvOS screensaver / Apple TV sleep must be suppressed **only while a
/// stream is actively playing** and re-enabled the moment it pauses, ends, or
/// the player goes away. Because the custom player renders a bare engine surface
/// (an `AVPlayerLayer` *or* another engine's render layer) with a hand-built transport, no
/// system component manages the idle timer for us — non-AVPlayer paths in particular
/// have no `AVPlayer` and would otherwise let the screensaver start mid-movie.
///
/// This guard makes the toggle idempotent and self-healing: callers push the
/// desired state every refresh tick via `keepAwake(_:)`, and the assertion is
/// always released on `deinit`, so leaving playback (or tearing the host down on
/// an engine swap) can never strand the device in a never-sleep state.
@MainActor
final class IdleSleepGuard {
    private var isHoldingWakeLock = false

    /// Pushes the desired wake state. Safe to call every frame/tick — it only
    /// touches `UIApplication` when the state actually changes.
    func keepAwake(_ shouldStayAwake: Bool) {
        guard shouldStayAwake != isHoldingWakeLock else { return }
        isHoldingWakeLock = shouldStayAwake
        UIApplication.shared.isIdleTimerDisabled = shouldStayAwake
    }

    /// Releases the wake lock (allows the screensaver / sleep again) if held.
    func allowSleep() {
        keepAwake(false)
    }

    deinit {
        // `deinit` may run off the main actor; hop on to release the assertion
        // without capturing `self`.
        if isHoldingWakeLock {
            Task { @MainActor in
                UIApplication.shared.isIdleTimerDisabled = false
            }
        }
    }
}
#endif
