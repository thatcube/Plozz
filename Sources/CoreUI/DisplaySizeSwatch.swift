#if canImport(SwiftUI)
import SwiftUI
import CoreModels

/// Fixed, theme-independent colours for the display-size preview swatch — the
/// same neutral family as `NavigationPreviewColors`, so Display Size reads as a
/// sibling of the other picker swatches. Deliberately colourless: the *subject*
/// here is card size, so plain grey placeholders carry it — no tint is needed to
/// convey meaning.
private enum DisplaySizePreviewColors {
    static let bgTop = Color(red: 0.17, green: 0.17, blue: 0.19)
    static let bgBottom = Color(red: 0.10, green: 0.10, blue: 0.12)
    static let tileTop = Color(white: 0.30)
    static let tileBottom = Color(white: 0.22)
    static let tileBorder = Color.white.opacity(0.10)
    /// The mock "Continue Watching" / "Watchlist" section titles.
    static let sectionTitle = Color.white.opacity(0.5)
}

/// A tiny mock **Home screen** illustrating one `UIDensity`: a "Continue Watching"
/// rail of landscape cards on top, then a "Watchlist" rail of posters, each under
/// a section title with real space between the rails — the actual layout of the
/// app. Every option's screen is the *same size* (a TV's dimensions don't change);
/// what changes is the card size, so the number of cards per rail is honestly
/// to-scale and the lower rail clips at the bottom edge like the page scrolling.
///
/// Card counts come from the live Home page: at Default the Continue Watching rail
/// shows ~3.3 landscape cards and the Watchlist ~6 posters, and both scale
/// inversely with the density's card `scale` (Huge ⇒ ~2.3 / ~4.2, matching device).
private struct DisplaySizeMini: View {
    let density: UIDensity

    private static let landscapeCountAtDefault: CGFloat = 3.3
    private static let posterCountAtDefault: CGFloat = 6.0

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let pad = min(w, h) * 0.09
            let availW = max(0, w - pad * 2)
            let availH = max(0, h - pad * 2)
            let s = CGFloat(density.scale)
            let gap = availW * 0.018

            // Card counts scale inversely with density; slot width = screen / count.
            let lCount = Self.landscapeCountAtDefault / s
            let pCount = Self.posterCountAtDefault / s
            let lW = max(1, availW / lCount - gap)
            let lH = lW * 9.0 / 16.0
            let pW = max(1, availW / pCount - gap)
            let pH = pW * 1.5
            let lDraw = Int(lCount.rounded(.up)) + 1
            let pDraw = Int(pCount.rounded(.up)) + 1

            let headerH = max(2.5, availH * 0.05)
            let headerGap = availH * 0.035
            let railGap = availH * 0.085
            // Enough Watchlist rails to fill the screen below the landscape rail,
            // then clip (Huge shows only the top sliver of the first, as on device).
            let pRailUnit = headerH + headerGap + pH + railGap
            let pRails = max(1, Int(ceil(availH / pRailUnit)) + 1)

            VStack(alignment: .leading, spacing: railGap) {
                rail(count: lDraw, cardW: lW, cardH: lH,
                     corner: max(1.5, lW * 0.07), gap: gap,
                     headerW: availW * 0.32, headerH: headerH, headerGap: headerGap)
                ForEach(0..<pRails, id: \.self) { _ in
                    rail(count: pDraw, cardW: pW, cardH: pH,
                         corner: max(1.5, pW * 0.1), gap: gap,
                         headerW: availW * 0.22, headerH: headerH, headerGap: headerGap)
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

    /// One rail: a section-title bar with a leading-aligned row of neutral cards
    /// beneath it.
    private func rail(count: Int, cardW: CGFloat, cardH: CGFloat, corner: CGFloat,
                      gap: CGFloat, headerW: CGFloat, headerH: CGFloat,
                      headerGap: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: headerGap) {
            Capsule()
                .fill(DisplaySizePreviewColors.sectionTitle)
                .frame(width: headerW, height: headerH)
            HStack(spacing: gap) {
                ForEach(0..<count, id: \.self) { _ in
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
                        .frame(width: cardW, height: cardH)
                }
            }
        }
    }
}

/// The per-option preview graphic for the Display Size picker: a mock Home screen
/// filled with neutral cards at one density's card size. Fills the caller's frame,
/// mirroring `NavigationStyleSwatch` / `CardStyleSwatch`.
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
