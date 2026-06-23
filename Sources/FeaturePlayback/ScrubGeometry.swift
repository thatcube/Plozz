import Foundation

/// Pure, UI-framework-agnostic geometry for translating a horizontal pan into a
/// scrub position. Extracted so the transfer function can be unit-tested on the
/// host (the UIKit gesture surface in `CustomPlayerContainer` can't be).
///
/// ## Why this is velocity-accelerated (and incremental)
/// The Siri Remote touch surface is *indirect*: one physical swipe produces only
/// a few hundred points of `translation`, and a **fast flick produces *less*
/// travel than a slow deliberate drag** (shorter contact). The previous model
/// mapped `translation.x / fullScreenWidth × sensitivity` linearly, so a quick
/// left-to-right swipe divided a small translation by a ~1920 pt screen width and
/// barely moved — the "it gets stuck / won't let me drag further" feel. Slow,
/// small drags worked because they're all most of the surface gives.
///
/// The fix is a **pointer-acceleration** transfer function applied to each pan
/// *increment*: at low speed the gain is ~1:1 precise (so a deliberate nudge of
/// ±1 minute stays silky), but as pan speed rises the gain ramps up along a
/// smoothstep S-curve to a modest ceiling, so a fast flick crosses a good chunk
/// of the film without feeling abrupt or jumpy. Working on per-sample increments
/// (rather than absolute translation against a base) is what lets the gain vary
/// with the speed of each sample. The caller is expected to feed a *smoothed*
/// speed (the raw recognizer velocity is jittery).
enum ScrubGeometry {
    /// Tunable parameters for the velocity-accelerated scrub transfer function.
    struct Tuning: Equatable {
        /// Seconds of scrub per point of pad travel at low (sub-onset) speed —
        /// the precise, deliberate-drag regime.
        var baseSecondsPerPoint: Double
        /// Pan speed (points/sec) below which no acceleration is applied, so slow
        /// drags stay 1:1 precise.
        var accelOnsetSpeed: Double
        /// Pan speed (points/sec) at which the gain reaches `maxAccelMultiplier`.
        /// Between the onset and this, the gain follows a smoothstep S-curve so
        /// acceleration eases in and eases out — no abrupt kick, no hard cap edge.
        var accelSaturationSpeed: Double
        /// Ceiling on the acceleration multiplier. Kept modest so a fast flick is
        /// quick but still controllable (a high ceiling reads as "jumpy").
        var maxAccelMultiplier: Double
    }

    /// The acceleration multiplier (always ≥ 1) for a given pan speed, following a
    /// smoothstep S-curve from 1 at `accelOnsetSpeed` to `maxAccelMultiplier` at
    /// `accelSaturationSpeed`. The S-curve (vs a linear ramp into a hard cap) is
    /// what makes a fast flick feel smooth rather than jumpy: gain changes
    /// gradually near both ends instead of snapping on at the onset and clipping
    /// at the ceiling.
    static func accelerationMultiplier(
        speedPointsPerSecond speed: Double,
        tuning: Tuning
    ) -> Double {
        let lo = tuning.accelOnsetSpeed
        let hi = max(lo + 1, tuning.accelSaturationSpeed)
        let t = min(max((speed - lo) / (hi - lo), 0), 1)
        let smooth = t * t * (3 - 2 * t)
        return 1 + (tuning.maxAccelMultiplier - 1) * smooth
    }

    /// Seconds the scrub head should move for one pan sample of `dx` points
    /// travelled at `speed` points/sec. The sign follows `dx`, so dragging back
    /// (negative `dx`) scrubs backward.
    static func scrubDeltaSeconds(
        translationDeltaPoints dx: Double,
        speedPointsPerSecond speed: Double,
        tuning: Tuning
    ) -> TimeInterval {
        dx * tuning.baseSecondsPerPoint
            * accelerationMultiplier(speedPointsPerSecond: speed, tuning: tuning)
    }

    /// Advances a running scrub position by one pan sample, clamped to
    /// `0...duration`.
    static func advance(
        scrubSeconds: TimeInterval,
        translationDeltaPoints dx: Double,
        speedPointsPerSecond speed: Double,
        tuning: Tuning,
        duration: TimeInterval
    ) -> TimeInterval {
        let next = scrubSeconds + scrubDeltaSeconds(
            translationDeltaPoints: dx, speedPointsPerSecond: speed, tuning: tuning)
        return min(max(0, next), duration)
    }
}
