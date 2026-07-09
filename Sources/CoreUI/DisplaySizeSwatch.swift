#if canImport(SwiftUI)
import SwiftUI
import CoreModels

/// Fixed, theme-independent colours for the display-size preview swatch — the
/// same neutral family as `NavigationPreviewColors`, so Display Size reads as a
/// sibling of the other picker swatches. Deliberately colourless: the *subject*
/// here is card size, so plain grey placeholder posters carry it — no tint is
/// needed to convey meaning.
private enum DisplaySizePreviewColors {
    static let bgTop = Color(red: 0.17, green: 0.17, blue: 0.19)
    static let bgBottom = Color(red: 0.10, green: 0.10, blue: 0.12)
    static let tileTop = Color(white: 0.30)
    static let tileBottom = Color(white: 0.22)
    static let tileBorder = Color.white.opacity(0.10)
}

/// A tiny mock "screen" painted with fixed colours, illustrating one `UIDensity`:
/// a wall of neutral grey placeholder posters at that density's real card size.
/// Every option's screen is the *same size* (a TV's dimensions don't change);
/// what changes is the card size, so denser options pack many small posters
/// across the screen and roomier ones a few big ones, with the bottom row
/// clipping like the wall scrolling off-screen. Card counts come from the
/// density's real `posterGridColumns`, so it's honestly to-scale.
private struct DisplaySizeMini: View {
    let density: UIDensity

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let pad = min(w, h) * 0.1
            let availW = max(0, w - pad * 2)
            let availH = max(0, h - pad * 2)

            let cols = density.posterGridColumns
            let gap = availW * 0.022
            let tileW = (availW - CGFloat(cols - 1) * gap) / CGFloat(cols)
            let tileH = tileW * 1.5
            let corner = max(1.5, tileW * 0.12)
            // Enough rows to fill the screen plus one that clips at the bottom.
            let rows = max(1, Int(ceil((availH + gap) / (tileH + gap))) + 1)

            VStack(alignment: .leading, spacing: gap) {
                ForEach(0..<rows, id: \.self) { _ in
                    HStack(spacing: gap) {
                        ForEach(0..<cols, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: corner, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [DisplaySizePreviewColors.tileTop, DisplaySizePreviewColors.tileBottom],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                                        .strokeBorder(DisplaySizePreviewColors.tileBorder, lineWidth: 1)
                                )
                                .frame(width: tileW, height: tileH)
                        }
                    }
                }
            }
            .frame(width: availW, height: availH, alignment: .topLeading)
            .clipped()
            .frame(width: w, height: h, alignment: .center)
            .background(
                LinearGradient(
                    colors: [DisplaySizePreviewColors.bgTop, DisplaySizePreviewColors.bgBottom],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
    }
}

/// The per-option preview graphic for the Display Size picker: a mock screen
/// filled with neutral posters at one density's card size. Fills the caller's
/// frame, mirroring `NavigationStyleSwatch` / `CardStyleSwatch`.
public struct DisplaySizeSwatch: View {
    private let density: UIDensity
    private let cornerRadius: CGFloat

    public init(density: UIDensity, cornerRadius: CGFloat = 16) {
        self.density = density
        self.cornerRadius = cornerRadius
    }

    public var body: some View {
        DisplaySizeMini(density: density)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color(white: 0.5).opacity(0.35), lineWidth: 1)
            )
    }
}
#endif
