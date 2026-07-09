#if canImport(SwiftUI)
import SwiftUI
import CoreModels

/// Fixed, theme-independent colours for the card-style preview swatch. Like
/// `ThemePreviewColors` / `WatchIndicatorPreviewColors`, these are a *picture* of
/// the feature and never adapt to the applied theme, so the illustration looks the
/// same in every theme.
private enum CardStylePreviewColors {
    static let bgTop = Color(red: 0.17, green: 0.17, blue: 0.19)
    static let bgBottom = Color(red: 0.10, green: 0.10, blue: 0.12)
    /// The framed card's glass surface + its hairline border.
    static let cardSurface = Color(red: 0.27, green: 0.27, blue: 0.30)
    static let cardBorder = Color.white.opacity(0.16)
    /// Caption bars: a brighter title over a dimmer subtitle line.
    static let titlePrimary = Color.white.opacity(0.72)
    static let titleSecondary = Color.white.opacity(0.30)
    static let tileBorder = Color.white.opacity(0.12)

    /// One fixed poster gradient — a single title, since Card Style is about the
    /// *frame* around a card, not the watch state, so one poster reads clearest.
    static let tileArt: [Color] = [
        Color(red: 0.24, green: 0.52, blue: 0.62),
        Color(red: 0.14, green: 0.28, blue: 0.44)
    ]
}

/// A tiny mock media card painted with fixed colours, illustrating one
/// `CardStyle`:
/// - `.framed` ("Cards"): a single poster with its title/subtitle bars, the whole
///   lot wrapped in a bordered glass surface with even padding all the way around
///   — text sits *inside* the boundary.
/// - `.borderless` ("Posters"): the same poster reading larger, with the
///   title/subtitle underneath and **no** surface or padding — just the artwork
///   and its sub-text.
///
/// Deliberately shows a single poster (not the horizontal/vertical split) so the
/// choice reads as "frame vs no frame" at a glance. Fills whatever frame the
/// caller gives it and stays proportionate at the compact and full sizes.
private struct CardStyleMini: View {
    let style: CardStyle

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            // A little breathing room so the illustration floats in the gradient
            // rather than butting against the swatch's own rounded border.
            let margin = min(w, h) * 0.09
            let availW = max(0, w - margin * 2)
            let availH = max(0, h - margin * 2)

            content(availW: availW, availH: availH)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(width: w, height: h)
                .background(
                    LinearGradient(
                        colors: [CardStylePreviewColors.bgTop, CardStylePreviewColors.bgBottom],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
    }

    // The media unit (poster + two caption bars) is 2:3 poster plus a caption
    // block, so its height is a fixed multiple of the tile width. These constants
    // keep the framed and borderless variants sized from the same media unit; the
    // framed variant simply adds padding around it (so its poster ends up a touch
    // smaller — faithful to how a framed card trades a little artwork for its
    // surround, and why borderless "reads larger").
    private var captionGapRatio: CGFloat { 0.16 }
    private var barGapRatio: CGFloat { 0.11 }
    private var barHeightRatio: CGFloat { 0.085 }
    /// posterH (1.5) + captionGap + two bars + the gap between them, all ÷ tileW.
    private var unitHeightRatio: CGFloat { 1.5 + captionGapRatio + barHeightRatio * 2 + barGapRatio }
    private var cardPadRatio: CGFloat { 0.16 }

    @ViewBuilder
    private func content(availW: CGFloat, availH: CGFloat) -> some View {
        switch style {
        case .framed:
            // Framed adds cardPad on every side, so solve tileW against the padded
            // footprint in both axes and take the smaller.
            let heightBound = availH / (unitHeightRatio + cardPadRatio * 2)
            let widthBound = availW / (1 + cardPadRatio * 2)
            framedCard(tileW: min(heightBound, widthBound))
        case .borderless:
            // No surround: the media unit fills the available box directly, so the
            // poster reads larger than the framed one for the same swatch.
            let tileW = min(availH / unitHeightRatio, availW)
            mediaUnit(tileW: tileW)
        }
    }

    /// The poster + title/subtitle bars, leading-aligned. Shared by both variants.
    private func mediaUnit(tileW: CGFloat) -> some View {
        let posterH = tileW * 1.5
        let corner = tileW * 0.10
        let barH = max(4, tileW * barHeightRatio)

        return VStack(alignment: .leading, spacing: tileW * captionGapRatio) {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: CardStylePreviewColors.tileArt,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                // Dull the mock artwork so it reads as a quiet stand-in, matching
                // the watch-indicator swatch's posters.
                .saturation(0.5)
                .overlay(
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .strokeBorder(CardStylePreviewColors.tileBorder, lineWidth: 1)
                )
                .frame(width: tileW, height: posterH)

            VStack(alignment: .leading, spacing: tileW * barGapRatio) {
                Capsule().fill(CardStylePreviewColors.titlePrimary)
                    .frame(width: tileW * 0.68, height: barH)
                Capsule().fill(CardStylePreviewColors.titleSecondary)
                    .frame(width: tileW * 0.44, height: barH)
            }
        }
        .frame(width: tileW)
    }

    /// The framed variant: the media unit wrapped in a bordered glass surface with
    /// even padding all around, so the caption sits *inside* the card boundary.
    private func framedCard(tileW: CGFloat) -> some View {
        let cardPad = tileW * cardPadRatio
        let cardCorner = tileW * 0.20
        return mediaUnit(tileW: tileW)
            .padding(cardPad)
            .background(
                RoundedRectangle(cornerRadius: cardCorner, style: .continuous)
                    .fill(CardStylePreviewColors.cardSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cardCorner, style: .continuous)
                    .strokeBorder(CardStylePreviewColors.cardBorder, lineWidth: 1)
            )
    }
}

/// The per-option preview graphic for the card-style picker: a mock media card
/// shown framed (bordered surface with padding) or borderless (bare artwork with
/// text underneath). Fills the caller's frame, so it scales for both the full and
/// compact card sizes, mirroring `ThemeSwatch` / `WatchStatusIndicatorSwatch`.
public struct CardStyleSwatch: View {
    private let style: CardStyle
    private let cornerRadius: CGFloat

    public init(style: CardStyle, cornerRadius: CGFloat = 16) {
        self.style = style
        self.cornerRadius = cornerRadius
    }

    public var body: some View {
        CardStyleMini(style: style)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color(white: 0.5).opacity(0.35), lineWidth: 1)
            )
    }
}
#endif
