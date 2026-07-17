import Foundation

/// The pure engine→controls-model reconciliation extracted from
/// `PlayerInputViewController.refreshFromEngine`. Each refresh tick reads the
/// engine's clock/buffer/pause state and decides what to write into the controls
/// model — the part that historically broke silently: the "press right → snap
/// back" pending-seek hold, and the resume-confirm pause suppression.
///
/// Keeping it pure means those two fragile windows are unit-tested directly,
/// without a live engine or view hierarchy. The controller stays responsible for
/// the side effects it can't express as data (wake-lock, skip presentation).
enum PlaybackClockReconciler {
    /// The engine readings sampled once per tick.
    struct EngineSnapshot: Equatable {
        var currentTime: TimeInterval
        var duration: TimeInterval
        var bufferedPosition: TimeInterval
        var isPaused: Bool
    }

    /// What to write into the model this tick. A `nil` field means "leave it as
    /// is" (hold the current value); the controller applies only the non-nil ones.
    struct Resolution: Equatable {
        /// New known duration (only set once the engine reports a positive one).
        var duration: TimeInterval?
        /// New live position, or `nil` to hold (pinned to an optimistic seek
        /// target, or suppressed while scrubbing).
        var currentSeconds: TimeInterval?
        /// Clear `pendingSeekTarget` — the committed seek has arrived.
        var clearPendingSeek: Bool
        /// New buffered-ahead position, or `nil` to hold (while scrubbing).
        var bufferedSeconds: TimeInterval?
        /// New paused state, or `nil` to hold (while scrubbing, or a resume is
        /// being confirmed and the engine's transient rate-0 must not leak).
        var isPaused: Bool?
        /// Whether the controller should evaluate skip/up-next presentation this
        /// tick (skipped while scrubbing, matching the original early return).
        var shouldEvaluateSkip: Bool
    }

    /// The pending-seek release window (seconds). Must exceed the engine's
    /// `.exact` seek tolerance (1s): a seek can legally land up to 1s *ahead* of
    /// the target by snapping to the next keyframe, and a tighter window would
    /// leave the bar pinned forever in that case. A real seek jump is many
    /// seconds, so this stays comfortably clear of a false early release.
    static let pendingSeekReleaseTolerance: TimeInterval = 1.25

    static func reconcile(
        snapshot: EngineSnapshot,
        isScrubbing: Bool,
        pendingSeekTarget: TimeInterval?,
        isResumeConfirming: Bool
    ) -> Resolution {
        // Duration is adopted regardless of scrubbing (it never fights the head).
        let duration: TimeInterval? = snapshot.duration > 0 ? snapshot.duration : nil

        // Don't fight the scrub head or an in-flight committed seek.
        guard !isScrubbing else {
            return Resolution(
                duration: duration,
                currentSeconds: nil,
                clearPendingSeek: false,
                bufferedSeconds: nil,
                isPaused: nil,
                shouldEvaluateSkip: false)
        }

        var currentSeconds: TimeInterval?
        var clearPendingSeek = false
        if let pending = pendingSeekTarget {
            // A committed seek is in flight. Hold the bar at the optimistic target
            // until the engine actually arrives within tolerance, so a poll between
            // the optimistic update and the engine catching up can't snap the bar
            // back to the stale pre-seek time.
            if abs(snapshot.currentTime - pending) < pendingSeekReleaseTolerance {
                clearPendingSeek = true
                currentSeconds = snapshot.currentTime
            }
            // else: hold (currentSeconds stays nil).
        } else {
            currentSeconds = snapshot.currentTime
        }

        // While a resume is being confirmed the engine can briefly report paused
        // (rate-0 settle on a buffering edge). Don't mirror that transient, or the
        // pause icon flashes on by itself and the resume loop fights its own state.
        let isPaused: Bool? = isResumeConfirming ? nil : snapshot.isPaused

        return Resolution(
            duration: duration,
            currentSeconds: currentSeconds,
            clearPendingSeek: clearPendingSeek,
            bufferedSeconds: snapshot.bufferedPosition,
            isPaused: isPaused,
            shouldEvaluateSkip: true)
    }
}
