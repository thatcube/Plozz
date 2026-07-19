#if canImport(SwiftUI)
import SwiftUI

/// A seamless legibility vignette for hero backdrops.
///
/// Replaces a single directional scrim (which pooled the darkening on one side —
/// obvious over a mostly-white hero) with two things layered together:
///   1. a faint **all-over wash** that darkens the whole image a touch, so a
///      bright hero doesn't read as blown-out; and
///   2. a **symmetric edge vignette** — the same darkening on the left, right,
///      top and bottom edges — that fades to clear through the middle.
///
/// Each edge reaches `edgePeak` (matching the strength the old one-sided scrim
/// used on the content side, so legibility is never reduced), and because the
/// horizontal and vertical passes overlap, the corners land a little darker —
/// exactly the even, seamless vignette look. Kept static (no per-slide state) and
/// meant to live *under* the caller's dissolve mask so it melts away with the
/// image at the bottom and never tints the revealed background.
public struct HeroLegibilityScrim: View {
    private let tone: Color
    private let edgePeak: Double
    private let wash: Double

    /// - Parameters:
    ///   - tone: Mode-appropriate scrim colour (dark in dark mode, light in light).
    ///   - edgePeak: Opacity at each edge — set to the old scrim's content-side
    ///     strength so the readable side is never lightened.
    ///   - wash: Flat opacity applied across the whole image (the subtle overall
    ///     darkening). Defaults to a gentle 6%.
    public init(tone: Color, edgePeak: Double, wash: Double = 0.06) {
        self.tone = tone
        self.edgePeak = edgePeak
        self.wash = wash
    }

    public var body: some View {
        ZStack {
            tone.opacity(wash)
            edgeGradient(startPoint: .leading, endPoint: .trailing)
            edgeGradient(startPoint: .top, endPoint: .bottom)
        }
    }

    /// One axis of the vignette: `edgePeak` at both ends, fading to a clear centre
    /// band so most of the image stays untinted.
    private func edgeGradient(startPoint: UnitPoint, endPoint: UnitPoint) -> some View {
        LinearGradient(
            stops: [
                .init(color: tone.opacity(edgePeak), location: 0.0),
                .init(color: .clear, location: 0.42),
                .init(color: .clear, location: 0.58),
                .init(color: tone.opacity(edgePeak), location: 1.0)
            ],
            startPoint: startPoint,
            endPoint: endPoint
        )
    }
}
#endif
