#if canImport(SwiftUI)
import SwiftUI
import CoreModels

/// Fixed, theme-independent colours for the display-size preview — a *picture* of
/// the feature that looks the same in every theme, matching `CardStylePreviewColors`
/// so Display Size reads as a sibling of the Card Style / Watched Indicator swatches
/// rather than a different visual language.
private enum DisplaySizePreviewColors {
    static let bgTop = Color(red: 0.17, green: 0.17, blue: 0.19)
    static let bgBottom = Color(red: 0.10, green: 0.10, blue: 0.12)
    static let tileBorder = Color.white.opacity(0.12)
    static let titlePrimary = Color.white.opacity(0.62)
    static let titleSecondary = Color.white.opacity(0.26)
    static let sectionTitle = Color.white.opacity(0.45)
    /// A few muted poster gradients, cycled along the rail and dulled (saturation
    /// 0.55) so the row reads as a calm stand-in for a shelf of posters — never a
    /// rainbow of blocks.
    static let tileArt: [[Color]] = [
        [Color(red: 0.24, green: 0.52, blue: 0.62), Color(red: 0.14, green: 0.28, blue: 0.44)],
        [Color(red: 0.52, green: 0.36, blue: 0.52), Color(red: 0.30, green: 0.20, blue: 0.36)],
        [Color(red: 0.34, green: 0.50, blue: 0.42), Color(red: 0.18, green: 0.30, blue: 0.26)]
    ]
}

/// The Display Size illustration: a mock **Home rail** — a single shelf of
/// captioned poster cards on a dark "screen" — drawn at one `UIDensity`'s true
/// relative card size. Every option's screen is the same size (a TV's width
/// doesn't change); what changes is how big the poster cards are, so denser
/// options fit many small captioned cards across the shelf and roomier ones a few
/// big ones. Cards that don't fit clip at the right edge, exactly like the real
/// rail running off-screen.
///
/// Mirrors `CardStyleMini`: fixed muted colours, 2:3 posters with two caption
/// bars, laid out from ratios so it scales to whatever frame the row gives it.
private struct DisplaySizeMini: View {
    let density: UIDensity

    // Poster media unit ratios (shared with the Card Style swatch so a poster here
    // reads identically): poster height 1.5·tileW plus the caption block.
    private let captionGapRatio: CGFloat = 0.16
    private let barGapRatio: CGFloat = 0.11
    private let barHeightRatio: CGFloat = 0.085
    private var unitHeightRatio: CGFloat { 1.5 + captionGapRatio + barHeightRatio * 2 + barGapRatio }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let margin = min(w, h) * 0.1
            let availW = max(0, w - margin * 2)
            let availH = max(0, h - margin * 2)

            // A faint section title above the shelf so the swatch reads as a page
            // section ("Watchlist"), not just floating cards.
            let headerH = max(3, availH * 0.08)
            let headerGap = availH * 0.12
            let shelfH = max(0, availH - headerH - headerGap)

            // Size the poster so the LARGEST density (Huge, scale 1.4) just fills
            // the shelf height; every other density scales down from there, so the
            // ramp is honest within one fixed screen height.
            let tileWMax = shelfH / unitHeightRatio
            let tileW = tileWMax * (density.scale / UIDensity.extraLarge.scale)
            let gap = max(3, tileW * 0.16)
            // Draw enough posters to overflow the shelf width, then clip.
            let count = max(1, Int(ceil((availW + gap) / (tileW + gap))) + 1)

            VStack(alignment: .leading, spacing: headerGap) {
                Capsule()
                    .fill(DisplaySizePreviewColors.sectionTitle)
                    .frame(width: availW * 0.24, height: headerH)
                HStack(alignment: .top, spacing: gap) {
                    ForEach(0..<count, id: \.self) { i in
                        mediaUnit(tileW: tileW, art: i)
                    }
                }
                .frame(width: availW, height: shelfH, alignment: .topLeading)
                .clipped()
            }
            .frame(width: availW, height: availH, alignment: .topLeading)
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

    /// One poster + its two caption bars, matching the Card Style swatch's media
    /// unit so posters look the same across pickers.
    private func mediaUnit(tileW: CGFloat, art: Int) -> some View {
        let posterH = tileW * 1.5
        let corner = max(2, tileW * 0.1)
        let barH = max(2.5, tileW * barHeightRatio)

        return VStack(alignment: .leading, spacing: tileW * captionGapRatio) {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: DisplaySizePreviewColors.tileArt[art % DisplaySizePreviewColors.tileArt.count],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .saturation(0.55)
                .overlay(
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .strokeBorder(DisplaySizePreviewColors.tileBorder, lineWidth: 1)
                )
                .frame(width: tileW, height: posterH)

            VStack(alignment: .leading, spacing: tileW * barGapRatio) {
                Capsule().fill(DisplaySizePreviewColors.titlePrimary)
                    .frame(width: tileW * 0.7, height: barH)
                Capsule().fill(DisplaySizePreviewColors.titleSecondary)
                    .frame(width: tileW * 0.44, height: barH)
            }
        }
        .frame(width: tileW)
    }
}

/// The per-option preview graphic for the Display Size picker. Fills the caller's
/// frame (give it a fixed height), mirroring `CardStyleSwatch` /
/// `WatchStatusIndicatorSwatch`.
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
