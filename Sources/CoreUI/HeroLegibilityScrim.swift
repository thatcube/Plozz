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
    /// Which edges the vignette darkens.
    ///
    /// The vignette is symmetric by default, which is right for a hero whose
    /// content sits centred. A surface that only places text along one side
    /// pays for the opposite edges in contrast without getting legibility back,
    /// so it can drop them.
    public struct Edges: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let leading = Edges(rawValue: 1 << 0)
        public static let trailing = Edges(rawValue: 1 << 1)
        public static let top = Edges(rawValue: 1 << 2)
        public static let bottom = Edges(rawValue: 1 << 3)

        public static let all: Edges = [.leading, .trailing, .top, .bottom]
    }

    private let tone: Color
    private let edgePeak: Double
    private let wash: Double
    private let edges: Edges
    private let sideDarkeningStart: Double
    private let bottomFadeTop: Double

    /// - Parameters:
    ///   - tone: Mode-appropriate scrim colour (dark in dark mode, light in light).
    ///   - edgePeak: Opacity at each edge — set to the old scrim's content-side
    ///     strength so the readable side is never lightened.
    ///   - wash: Flat opacity applied across the whole image (the subtle overall
    ///     darkening). Defaults to a gentle 6%.
    ///   - edges: Which edges to darken. Defaults to all four.
    ///   - sideDarkeningStart: How far DOWN the hero the left/right darkening
    ///     ramps in, as a fraction of height. `0` darkens the full column
    ///     evenly (the symmetric default). A higher value keeps the upper
    ///     corners clean and brings the wash in only where content sits.
    ///   - bottomFadeTop: The upper edge of the bottom-anchored fade. Lower values
    ///     make the fade taller while leaving its bottom edge unchanged.
    public init(
        tone: Color,
        edgePeak: Double,
        wash: Double = 0.06,
        edges: Edges = .all,
        sideDarkeningStart: Double = 0,
        bottomFadeTop: Double = 0.58
    ) {
        self.tone = tone
        self.edgePeak = edgePeak
        self.wash = wash
        self.edges = edges
        self.sideDarkeningStart = sideDarkeningStart
        self.bottomFadeTop = bottomFadeTop
    }

    public var body: some View {
        ZStack {
            tone.opacity(wash)
            if edges.contains(.leading) || edges.contains(.trailing) {
                edgeGradient(
                    startPoint: .leading,
                    endPoint: .trailing,
                    startsDark: edges.contains(.leading),
                    endsDark: edges.contains(.trailing)
                )
                .mask(sideDarkeningMask)
            }
            if edges.contains(.top) || edges.contains(.bottom) {
                edgeGradient(
                    startPoint: .top,
                    endPoint: .bottom,
                    startsDark: edges.contains(.top),
                    endsDark: edges.contains(.bottom),
                    bottomFadeTop: bottomFadeTop
                )
            }
        }
    }

    /// Ramps the side darkening in vertically, so the upper corners keep the
    /// artwork's own contrast while the wash still arrives at full strength over
    /// the title, metadata and buttons lower down. A plain column of darkening
    /// dimmed the top corner for no legibility gain — nothing is drawn over it.
    ///
    /// Opaque (no masking) when `sideDarkeningStart` is 0, so the symmetric
    /// default is untouched.
    @ViewBuilder
    private var sideDarkeningMask: some View {
        if sideDarkeningStart <= 0 {
            Color.black
        } else {
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0), location: 0),
                    .init(color: .black.opacity(0.35), location: sideDarkeningStart),
                    .init(color: .black, location: min(1, sideDarkeningStart + 0.28))
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    /// One axis of the vignette: `edgePeak` at both ends, fading to a clear centre
    /// band so most of the image stays untinted.
    private func edgeGradient(
        startPoint: UnitPoint,
        endPoint: UnitPoint,
        startsDark: Bool,
        endsDark: Bool,
        bottomFadeTop: Double = 0.58
    ) -> some View {
        LinearGradient(
            stops: [
                .init(color: tone.opacity(startsDark ? edgePeak : 0), location: 0),
                .init(color: .clear, location: 0.42),
                .init(color: .clear, location: bottomFadeTop),
                .init(color: tone.opacity(endsDark ? edgePeak : 0), location: 1)
            ],
            startPoint: startPoint,
            endPoint: endPoint
        )
    }
}
#endif
