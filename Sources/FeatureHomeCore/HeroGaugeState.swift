import CoreGraphics
import Foundation

/// What the hero's auto-advance gauge should show, and how long it has left.
///
/// The gauge has two possible sources — the slide's dwell timer, or a trailer's
/// own playback clock — and the decision between them caused every bug this type
/// exists to prevent. It lives here, above both shells, so tvOS and iPhone cannot
/// disagree about it and so the rules can be tested without a running hero.
public struct HeroGaugeState: Equatable, Sendable {
    /// How far along the bar is, `0...1`.
    public let fraction: CGFloat
    /// Seconds until the bar is full, or `nil` when nothing is running and the
    /// bar should simply hold where it is.
    public let remaining: TimeInterval?

    public init(fraction: CGFloat, remaining: TimeInterval?) {
        self.fraction = fraction
        self.remaining = remaining
    }

    /// - Parameters:
    ///   - isTransitioning: true while the hero is moving to a new slide. The
    ///     view already points at the incoming slide, but `dwellStart` still
    ///     belongs to the outgoing one, so the elapsed time reads as a finished
    ///     dwell. Treated as a dwell that has not begun rather than one that is
    ///     over, which is what stopped the incoming bar being drawn full.
    ///   - trailerElapsed/trailerDuration: the trailer's clock, when one is
    ///     playing AND has reported a usable duration. Until it does it says
    ///     nothing about progress, so the dwell keeps driving the bar instead of
    ///     the bar emptying and restarting when the clock finally arrives.
    public static func resolve(
        autoAdvance: Bool,
        dwellStart: Date,
        dwellDuration: TimeInterval,
        now: Date,
        isTransitioning: Bool = false,
        trailerElapsed: Double? = nil,
        trailerDuration: Double? = nil
    ) -> HeroGaugeState {
        // Nothing is counting down, so the pill reads as a solid full pill.
        guard autoAdvance else { return HeroGaugeState(fraction: 1, remaining: nil) }

        if let trailerDuration, let trailerElapsed,
           trailerDuration > 0, trailerElapsed.isFinite, trailerElapsed >= 0 {
            let fraction = clamp(CGFloat(trailerElapsed / trailerDuration))
            return HeroGaugeState(
                fraction: fraction,
                remaining: max(0, trailerDuration - trailerElapsed)
            )
        }

        let duration = max(dwellDuration, 1)
        let elapsed = now.timeIntervalSince(dwellStart)
        guard !isTransitioning, elapsed < duration else {
            return HeroGaugeState(fraction: 0, remaining: duration)
        }
        return HeroGaugeState(
            fraction: clamp(CGFloat(elapsed / duration)),
            remaining: max(0, duration - elapsed)
        )
    }

    private static func clamp(_ value: CGFloat) -> CGFloat {
        min(max(value, 0), 1)
    }
}
