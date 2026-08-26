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
    /// The ring a focused card wears in the outlined style. Brighter and
    /// harder-edged than the real translucent glass band, so the option is
    /// legible at swatch size — see `poster(tileW:...)`.
    static let haloFill = Color.white.opacity(0.30)
    static let haloEdge = Color.white.opacity(0.95)
    static let tileBorder = Color.white.opacity(0.12)
    static let titlePrimary = Color.white.opacity(0.72)
    static let titleSecondary = Color.white.opacity(0.30)

    static let tileArt: [Color] = [
        Color(red: 0.24, green: 0.52, blue: 0.62),
        Color(red: 0.14, green: 0.28, blue: 0.44)
    ]
}

/// A row of three mock posters with the **middle one focused**, illustrating what
/// focus does to a card:
/// - `.outlined`: the focused poster wears a bright outline around its edge.
/// - `.highlight`: no outline at all. The focused poster is simply **bigger**, lit
///   from above, and tipped slightly, with its caption pushed down out of the way.
///
/// Three posters with the focused one in the middle, because this setting is
/// about the *difference* between a focused card and the cards either side of it
/// — and only a card with neighbours on both sides shows how far it grows into
/// them. Fills whatever frame the caller gives it and stays proportionate at the
/// compact and full sizes.
private struct CardFocusMini: View {
    let style: CardFocusStyle

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let margin = min(w, h) * 0.07
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
    /// The gap between posters, and the room the focused one needs to grow into
    /// without touching its neighbours.
    private var tileGapRatio: CGFloat { 0.20 }
    /// How wide the outlined style's ring is drawn, as a fraction of a poster's
    /// width.
    ///
    /// Roughly twice the real band. The real one is a few points of translucent
    /// glass around a full-size card; shrunk to swatch scale and drawn honestly
    /// it is a hairline you have to hunt for, and the entire job of this picture
    /// is to make the two options tell themselves apart at a glance. Overstating
    /// it says what the option *is* — a card with a ring around it — which is the
    /// true thing here. The same reasoning as the ring's brightness; see
    /// `poster(tileW:...)`.
    private var outlineBandRatio: CGFloat { 0.105 }

    /// How much bigger the focused poster reads. Not the real scales — those are
    /// a few percent and would be invisible at swatch size — but the same
    /// *relationship*: highlight grows further, because it has no outline to
    /// cover the ground for it.
    private var focusedScale: CGFloat { style.drawsFocusOutline ? 1.08 : 1.20 }

    @ViewBuilder
    private func content(availW: CGFloat, availH: CGFloat) -> some View {
        // Three tiles across, sized so the middle one's growth still fits both
        // the width (against its neighbours) and the height.
        let widthBound = availW / (3 + tileGapRatio * 2)
        let heightBound = availH / unitHeightRatio / focusedScale
        let tileW = min(widthBound, heightBound)

        HStack(alignment: .top, spacing: tileW * tileGapRatio) {
            mediaUnit(tileW: tileW, isFocused: false)
            mediaUnit(tileW: tileW, isFocused: true)
                // Above its neighbours, exactly as a real focused card is, so the
                // growth reads as the card coming forward rather than being
                // squeezed between them.
                .zIndex(1)
            mediaUnit(tileW: tileW, isFocused: false)
        }
    }

    private func mediaUnit(tileW: CGFloat, isFocused: Bool) -> some View {
        let posterH = tileW * 1.5
        let corner = tileW * 0.10
        let barH = max(3, tileW * barHeightRatio)
        let pad = tileW * outlineBandRatio
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
            // The neighbours' captions dim, so the focused card's own caption is
            // the one being read.
            .opacity(isFocused ? 1 : 0.55)
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
            // Outlined: a bright ring hugging the artwork.
            //
            // Deliberately brighter and harder-edged than the real thing, which is
            // translucent Liquid Glass and picks up whatever is behind it. At
            // swatch size a faithful glass band is a smudge you can barely see —
            // and the whole job of this picture is to make the difference between
            // the two options obvious at a glance. It reads as what the option
            // *is* (a card with a ring around it) rather than as a colour match.
            art.background {
                RoundedRectangle(cornerRadius: corner + pad, style: .continuous)
                    .fill(CardFocusPreviewColors.haloFill)
                    .overlay {
                        RoundedRectangle(cornerRadius: corner + pad, style: .continuous)
                            .strokeBorder(CardFocusPreviewColors.haloEdge, lineWidth: max(1, pad * 0.34))
                    }
                    .padding(-pad)
            }
        } else if isFocused {
            // Highlight: no outline. Lit from above across the whole card, and
            // tipped the way it would lean arriving from its neighbour on the left.
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
            // Sized from the poster, NOT from `pad`: that is the outlined style's
            // ring width, and this is the highlight style's lift. Tying them
            // together meant widening the ring quietly deepened a shadow in the
            // other option's picture.
            .shadow(color: .black.opacity(0.5), radius: tileW * 0.13, y: tileW * 0.055)
            // A hint of the lean, not a demonstration of it. The real card tips
            // 5° for a moment and comes back; a still picture holding a big angle
            // reads as the card being permanently crooked.
            .rotation3DEffect(.degrees(4), axis: (x: 0, y: 1, z: 0), perspective: 0.4)
        } else {
            // The neighbours sit back, so the focused card is unmistakably the
            // one being looked at.
            art.opacity(0.62)
        }
    }
}

/// The per-option preview graphic for the card focus-style picker: three mock
/// posters with the middle one focused, showing either the ring around it or the
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
