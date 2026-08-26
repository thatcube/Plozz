#if canImport(SwiftUI)
import SwiftUI
import CoreModels

/// Fixed, theme-independent colours for the focus-style preview swatch. Like
/// `CardStylePreviewColors` / `WatchIndicatorPreviewColors`, these are a *picture*
/// of the feature and never adapt to the applied theme, so the illustration looks
/// the same in every theme.
private enum CardFocusPreviewColors {
    static let bgTop = Color(red: 0.17, green: 0.17, blue: 0.19)
    static let bgBottom = Color(red: 0.10, green: 0.10, blue: 0.12)
    /// The glass halo a focused card blooms in the outlined style.
    static let halo = Color.white.opacity(0.34)
    static let tileBorder = Color.white.opacity(0.12)
    static let titlePrimary = Color.white.opacity(0.72)
    static let titleSecondary = Color.white.opacity(0.30)

    static let tileArt: [Color] = [
        Color(red: 0.24, green: 0.52, blue: 0.62),
        Color(red: 0.14, green: 0.28, blue: 0.44)
    ]
}

/// A pair of mock posters — one resting, one focused — illustrating what focus
/// does to a card:
/// - `.outlined`: the focused poster wears a glass halo around its edge.
/// - `.highlight`: no halo at all. The focused poster is simply **bigger**, lit
///   from above, and tipped slightly, with its caption pushed down out of the way.
///
/// Two posters rather than one, because this setting is about the *difference*
/// between a focused card and its neighbour — a single card can't show that.
/// Fills whatever frame the caller gives it and stays proportionate at the
/// compact and full sizes.
private struct CardFocusMini: View {
    let style: CardFocusStyle

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let margin = min(w, h) * 0.09
            let availW = max(0, w - margin * 2)
            let availH = max(0, h - margin * 2)

            content(availW: availW, availH: availH)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(width: w, height: h)
                .background(
                    LinearGradient(
                        colors: [CardFocusPreviewColors.bgTop, CardFocusPreviewColors.bgBottom],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
    }

    // The media unit is a 2:3 poster plus two caption bars, matching
    // `CardStyleSwatch` so the two illustrations in the Cards pane read as the
    // same mock card seen twice.
    private var captionGapRatio: CGFloat { 0.16 }
    private var barGapRatio: CGFloat { 0.11 }
    private var barHeightRatio: CGFloat { 0.085 }
    private var unitHeightRatio: CGFloat { 1.5 + captionGapRatio + barHeightRatio * 2 + barGapRatio }
    /// The gap between the two posters, and the room the focused one needs to
    /// grow into without touching its neighbour.
    private var tileGapRatio: CGFloat { 0.22 }
    /// How much bigger the focused poster reads. Not the real scales — those are
    /// a few percent and would be invisible at swatch size — but the same
    /// *relationship*: highlight grows further, because it has no outline to
    /// cover the ground for it.
    private var focusedScale: CGFloat { style.drawsFocusOutline ? 1.10 : 1.22 }

    @ViewBuilder
    private func content(availW: CGFloat, availH: CGFloat) -> some View {
        // Two tiles side by side, sized so the focused one's growth still fits.
        let widthBound = availW / (2 + tileGapRatio) / focusedScale
        let heightBound = availH / unitHeightRatio / focusedScale
        let tileW = min(widthBound, heightBound)

        HStack(alignment: .top, spacing: tileW * tileGapRatio) {
            mediaUnit(tileW: tileW, isFocused: false)
            mediaUnit(tileW: tileW, isFocused: true)
        }
    }

    private func mediaUnit(tileW: CGFloat, isFocused: Bool) -> some View {
        let posterH = tileW * 1.5
        let corner = tileW * 0.10
        let barH = max(3, tileW * barHeightRatio)
        let pad = tileW * 0.055
        // The caption drops further in the highlight style, because the card it
        // has to stay clear of grows further. Same rule as the real cards.
        let captionPush = tileW * (style.drawsFocusOutline ? 0.06 : 0.12)

        return VStack(alignment: .leading, spacing: tileW * captionGapRatio) {
            poster(tileW: tileW, posterH: posterH, corner: corner, pad: pad, isFocused: isFocused)

            VStack(alignment: .leading, spacing: tileW * barGapRatio) {
                Capsule().fill(CardFocusPreviewColors.titlePrimary)
                    .frame(width: tileW * 0.68, height: barH)
                Capsule().fill(CardFocusPreviewColors.titleSecondary)
                    .frame(width: tileW * 0.44, height: barH)
            }
            .offset(y: isFocused ? captionPush : 0)
        }
        .frame(width: tileW)
        // Only the focused tile grows, and it grows about its own centre, exactly
        // as a real focused card does.
        .scaleEffect(isFocused ? focusedScale : 1)
    }

    @ViewBuilder
    private func poster(
        tileW: CGFloat,
        posterH: CGFloat,
        corner: CGFloat,
        pad: CGFloat,
        isFocused: Bool
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        let art = shape
            .fill(
                LinearGradient(
                    colors: CardFocusPreviewColors.tileArt,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .saturation(0.5)
            .overlay(shape.strokeBorder(CardFocusPreviewColors.tileBorder, lineWidth: 1))
            .frame(width: tileW, height: posterH)

        if isFocused && style.drawsFocusOutline {
            // Outlined: the halo blooms *around* the artwork as a concentric band.
            art.background {
                RoundedRectangle(cornerRadius: corner + pad, style: .continuous)
                    .fill(CardFocusPreviewColors.halo)
                    .padding(-pad)
            }
        } else if isFocused {
            // Highlight: no halo. Lit from above across the whole card, and tipped
            // the way it would lean arriving from its neighbour on the left.
            art.overlay {
                shape.fill(
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(0.20), location: 0),
                            .init(color: .white.opacity(0.12), location: 0.45),
                            .init(color: .white.opacity(0.07), location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            }
            .shadow(color: .black.opacity(0.45), radius: pad * 2.2, y: pad)
            .rotation3DEffect(.degrees(9), axis: (x: 0, y: 1, z: 0), perspective: 0.55)
        } else {
            art
        }
    }
}

/// The per-option preview graphic for the card focus-style picker: two mock
/// posters, the right-hand one focused, showing either the glass halo or the
/// bigger, lit, tipped card that replaces it. Fills the caller's frame, so it
/// scales for both the full and compact card sizes, mirroring `CardStyleSwatch` /
/// `WatchStatusIndicatorSwatch`.
public struct CardFocusStyleSwatch: View {
    private let style: CardFocusStyle
    private let cornerRadius: CGFloat

    public init(style: CardFocusStyle, cornerRadius: CGFloat = 16) {
        self.style = style
        self.cornerRadius = cornerRadius
    }

    public var body: some View {
        CardFocusMini(style: style)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color(white: 0.5).opacity(0.35), lineWidth: 1)
            )
    }
}
#endif
