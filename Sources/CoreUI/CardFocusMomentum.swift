#if canImport(SwiftUI)
import SwiftUI

/// Which way focus was travelling when it landed on a card.
///
/// This exists so a card's arrival can be a reaction to *your* input rather than
/// the same animation every time. A fixed lean — every card tipping the same way
/// whenever it takes focus — is a canned flourish, and a canned flourish gets old
/// on about the fifth card. A lean that follows the direction you moved does not
/// repeat: press Right and the card takes the push from the left; come up from
/// the row below and it rocks back over its bottom edge. Same code, different
/// result, because the input is different.
///
/// Deliberately **not** `@Observable`: nothing renders from this. Cards write to
/// it and read it back imperatively at the single instant focus lands, so
/// publishing changes would only invalidate views for a value none of them
/// display. It's ephemeral interface state — one focus, one direction, thrown
/// away as soon as it's used.
public final class CardFocusMomentum: @unchecked Sendable {
    /// One per app: only one card holds focus at a time, so there is only ever
    /// one "previous card" to measure from.
    public static let shared = CardFocusMomentum()

    /// Centre of the card that most recently took focus, in global coordinates.
    private var lastCenter: CGPoint?

    /// Far enough apart that the two cards can't plausibly be neighbours — a
    /// jump between screens rather than a move between cards. Those carry no
    /// meaningful direction (you didn't *travel* there), so they get no lean.
    private static let implausibleTravel: CGFloat = 2000
    /// Close enough that the "move" is really the same card being re-focused, or
    /// a layout shift. Also no lean.
    private static let negligibleTravel: CGFloat = 8

    public init() {}

    /// Records `frame` as the newest focused card and returns the direction focus
    /// travelled to reach it, with the dominant axis normalised to ±1 — or `nil`
    /// when there's no meaningful direction to report.
    @MainActor
    public func arrive(at frame: CGRect) -> CGVector? {
        guard frame != .zero else { return nil }
        let centre = CGPoint(x: frame.midX, y: frame.midY)
        defer { lastCenter = centre }

        guard let previous = lastCenter else { return nil }
        let delta = CGVector(dx: centre.x - previous.x, dy: centre.y - previous.y)
        let distance = max(abs(delta.dx), abs(delta.dy))
        guard distance > Self.negligibleTravel, distance < Self.implausibleTravel else {
            return nil
        }
        // Scale by the dominant axis rather than the true length, so a diagonal
        // move leans as hard as a straight one — the direction is what's being
        // expressed, not how far focus happened to jump.
        return CGVector(dx: delta.dx / distance, dy: delta.dy / distance)
    }

    /// Forgets the last card, so the next arrival is treated as a fresh start.
    /// Called when focus leaves the card system entirely.
    @MainActor
    public func reset() {
        lastCenter = nil
    }
}
#endif
