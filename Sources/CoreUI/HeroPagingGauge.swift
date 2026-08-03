#if canImport(UIKit)
import UIKit

/// Fills the hero's active paging pill by handing the animation to Core
/// Animation, rather than recomputing it on every frame.
///
/// The gauge is a linear ramp: a fill that grows from a circle to a pill over a
/// known duration. Both shells used to walk it themselves — tvOS with a
/// `CADisplayLink`, iPhone with a SwiftUI `TimelineView` — which means the app
/// woke up, re-ran layout and committed a transaction for every frame of an
/// animation whose whole definition is "go from here to there, evenly". On an
/// iPhone that measured a steady 7.2% CPU with nothing else happening.
///
/// A `CABasicAnimation` states the same thing once and lets the render server
/// interpolate it. The app does no per-frame work at all, so the fill runs at
/// the display's full rate — smoother than either hand-rolled version — while
/// costing effectively nothing.
///
/// The shape survives because the fill is a rounded rect whose corner radius is
/// half its height: at width == height it is a circle, and at any greater width
/// a capsule. Animating only the width therefore draws exactly the same shapes
/// the per-frame code drew.
public enum HeroPagingGauge {
    /// Key for the animation this type adds, so it can be replaced or removed
    /// without disturbing anything else on the layer.
    public static let animationKey = "plozz.heroPagingGauge"

    /// Prepares a layer to be used as a gauge fill. Left-anchored so growth only
    /// needs the width to change; the position then stays constant and does not
    /// have to be animated alongside it.
    public static func prepare(_ layer: CALayer, height: CGFloat, midY: CGFloat) {
        layer.anchorPoint = CGPoint(x: 0, y: 0.5)
        layer.position = CGPoint(x: 0, y: midY)
        layer.cornerRadius = height / 2
    }

    /// The fill width for a fraction of the way through the dwell. Starts as a
    /// circle (width == height) so an empty gauge still reads as a dot.
    public static func width(
        fraction: CGFloat,
        trackWidth: CGFloat,
        height: CGFloat
    ) -> CGFloat {
        let clamped = min(max(fraction, 0), 1)
        return height + (trackWidth - height) * clamped
    }

    /// Holds the gauge at one fraction, cancelling any running animation. Used
    /// when the dwell is paused or auto-advance is off, where there is nothing
    /// to animate and the fill should simply sit where it is.
    public static func setStatic(
        _ layer: CALayer,
        fraction: CGFloat,
        trackWidth: CGFloat,
        height: CGFloat
    ) {
        layer.removeAnimation(forKey: animationKey)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.bounds = CGRect(
            x: 0,
            y: 0,
            width: width(fraction: fraction, trackWidth: trackWidth, height: height),
            height: height
        )
        CATransaction.commit()
    }

    /// Runs the gauge from `fraction` to full over `remaining` seconds.
    ///
    /// The model value is set to the finished state and the animation describes
    /// the journey to it, so if the animation is ever dropped — app suspended,
    /// layer re-created — the layer still reads as complete rather than snapping
    /// back to empty.
    /// Where a ramp stated earlier has reached by `now`.
    ///
    /// Used to keep the gauge monotonic. Partway through a slide its source can
    /// change — a trailer begins and starts reporting its own clock from zero —
    /// and restating the ramp from that new source ran the bar backwards, which
    /// reads as a glitch rather than as new information. Deliberately computed
    /// from the stated ramp rather than read back from the layer: a layer only
    /// has a presentation copy while it is in a render tree and animating, so
    /// reading it would work sometimes and silently not others.
    public static func projectedFraction(
        from fraction: CGFloat,
        started: Date,
        remaining: TimeInterval,
        now: Date
    ) -> CGFloat {
        let clamped = min(max(fraction, 0), 1)
        guard remaining > 0 else { return 1 }
        let elapsed = now.timeIntervalSince(started)
        guard elapsed > 0 else { return clamped }
        let travelled = CGFloat(elapsed / remaining) * (1 - clamped)
        return min(clamped + travelled, 1)
    }

    public static func animate(
        _ layer: CALayer,
        from fraction: CGFloat,
        remaining: TimeInterval,
        trackWidth: CGFloat,
        height: CGFloat
    ) {
        let start = width(fraction: fraction, trackWidth: trackWidth, height: height)
        let end = width(fraction: 1, trackWidth: trackWidth, height: height)
        guard remaining > 0, start < end else {
            setStatic(layer, fraction: 1, trackWidth: trackWidth, height: height)
            return
        }

        layer.removeAnimation(forKey: animationKey)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.bounds = CGRect(x: 0, y: 0, width: end, height: height)
        CATransaction.commit()

        let animation = CABasicAnimation(keyPath: "bounds.size.width")
        animation.fromValue = start
        animation.toValue = end
        animation.duration = remaining
        // Linear because the gauge reports elapsed time; easing it would make it
        // lie about how long is left.
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.fillMode = .forwards
        layer.add(animation, forKey: animationKey)
    }
}
#endif
