#if canImport(SwiftUI)
import SwiftUI
import CoreModels

/// Fixed, theme-independent colours for the display-size preview strip — a
/// *picture* of the feature that looks the same in every theme (like
/// `CardStylePreviewColors` / `WatchIndicatorPreviewColors`).
private enum DisplaySizePreviewColors {
    static let bg = Color(red: 0.12, green: 0.12, blue: 0.14)
    static let tileBorder = Color.white.opacity(0.10)
    /// A small palette of muted poster gradients, cycled across the row so
    /// neighbouring mock posters read as distinct without pulling focus.
    static let tileArt: [[Color]] = [
        [Color(red: 0.24, green: 0.52, blue: 0.62), Color(red: 0.14, green: 0.28, blue: 0.44)],
        [Color(red: 0.55, green: 0.34, blue: 0.52), Color(red: 0.30, green: 0.18, blue: 0.36)],
        [Color(red: 0.60, green: 0.44, blue: 0.28), Color(red: 0.36, green: 0.24, blue: 0.16)],
        [Color(red: 0.30, green: 0.52, blue: 0.40), Color(red: 0.16, green: 0.32, blue: 0.26)]
    ]
}

/// A horizontal strip of mock poster cards drawn at one `UIDensity`'s **true
/// relative scale**, so the six densities stacked in a list read as a size ramp:
/// each row's preview area is the same width, but the cards are sized by the
/// density's real `scale`, so smaller densities fit many little cards and larger
/// ones a few big cards — clipped to whatever fits. Semi-accurate on purpose:
/// it conveys both "bigger cards" and "fewer fit" at a glance without trying to
/// mirror the live grid pixel-for-pixel.
public struct DisplaySizeSwatch: View {
    private let density: UIDensity
    /// Height of a `.standard` (scale 1.0) mock poster; every other density scales
    /// off this. The strip's own height is the tallest option's card height so all
    /// rows share a baseline and the ramp reads cleanly.
    private let baseCardHeight: CGFloat

    public init(density: UIDensity, baseCardHeight: CGFloat = 46) {
        self.density = density
        self.baseCardHeight = baseCardHeight
    }

    private var cardHeight: CGFloat { baseCardHeight * density.scale }
    private var cardWidth: CGFloat { cardHeight * (2.0 / 3.0) }
    private var gap: CGFloat { max(4, 7 * density.scale) }
    private var corner: CGFloat { max(3, cardHeight * 0.1) }

    public var body: some View {
        // Draw plenty of cards, left-aligned, and clip to the available width:
        // the clip is what makes the count "honest" (fewer big cards fit than
        // small ones) without measuring the live grid.
        HStack(spacing: gap) {
            ForEach(0..<12, id: \.self) { i in
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: DisplaySizePreviewColors.tileArt[i % DisplaySizePreviewColors.tileArt.count],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: corner, style: .continuous)
                            .strokeBorder(DisplaySizePreviewColors.tileBorder, lineWidth: 1)
                    )
                    .frame(width: cardWidth, height: cardHeight)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
    }
}
#endif
