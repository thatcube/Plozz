#if canImport(SwiftUI)
import SwiftUI

/// Shared building blocks for the borderless ("Posters") `CardStyle` — the
/// artwork-only look with **no** glass surface. Both the movie/show
/// `PosterCardView` and the music `MusicCard` compose these so the two stay
/// pixel-identical.
public extension View {
    /// The shared focus **halo** for artwork tiles — one theme-aware, translucent
    /// liquid-glass focus frame used by BOTH the circular artist/cast tiles and the
    /// borderless ("Posters") cards, so focus looks identical across them. It is the
    /// same surface (`plozzGlassCard`) the app's cards lift to on focus.
    ///
    /// On focus a `plozzGlassCard` blooms *around* the already-clipped artwork as a
    /// concentric band: it's drawn in the **background** (so it never changes
    /// layout) and extended `circleFocusPadding` beyond every edge, its radius
    /// bumped to stay concentric, with the opaque artwork on top masking the centre
    /// — leaving only a soft glass ring + drop shadow. At rest there's no surface at
    /// all, just the artwork. The whole thing scales together on focus so the ring
    /// keeps hugging the artwork and stays `circleFocusPadding` wide at any tile
    /// size. Being a pure render treatment (`background` + `scaleEffect`), it never
    /// alters the tile's footprint, so focusing can't nudge the row or neighbours.
    ///
    /// Pass `cornerRadius: side / 2` for a circular avatar (the band becomes a ring)
    /// or the artwork's outer radius for a rounded-rect card.
    func plozzFocusHalo(
        cornerRadius: CGFloat,
        focusScale: CGFloat,
        isFocused: Bool
    ) -> some View {
        modifier(FocusHaloModifier(
            cornerRadius: cornerRadius,
            focusScale: focusScale,
            isFocused: isFocused
        ))
    }
}

private struct FocusHaloModifier: ViewModifier {
    let cornerRadius: CGFloat
    let focusScale: CGFloat
    let isFocused: Bool

    @Environment(\.plozzMetrics) private var metrics
    @Environment(\.themePalette) private var palette

    func body(content: Content) -> some View {
        let pad = metrics.circleFocusPadding
        content
            .background {
                // The shared liquid-glass focus surface, bloomed into a band around
                // the artwork: sized to the artwork by `.background`, then grown
                // `pad` beyond every edge with negative padding (backgrounds draw
                // outside the content bounds), its radius bumped to stay concentric.
                Color.clear
                    .plozzGlassCard(
                        cornerRadius: cornerRadius + pad,
                        isFocused: true,
                        addsFocusHaloBacking: true
                    )
                    .padding(-pad)
                    .shadow(
                        color: .black.opacity(palette.isLight ? 0.44 : 0.36),
                        radius: 20,
                        y: 10
                    )
                    .opacity(isFocused ? 1 : 0)
            }
            .scaleEffect(isFocused ? focusScale : 1)
    }
}

/// The borderless card's caption: a left-aligned title + subtitle held off the
/// rounded artwork corners by `horizontalInset` (the same optical clearance the
/// framed caption uses) so the text lines up with the artwork's visual edge. It
/// sits on the page (never on glass), so — unlike the framed caption — it doesn't
/// flip to dark ink on focus.
///
/// Callers constrain the width (the card slot / artwork width); this fills it and
/// stays leading-aligned.
public struct BorderlessCardCaption: View {
    private let title: String
    private let subtitle: String?
    private let horizontalInset: CGFloat

    @Environment(\.plozzMetrics) private var metrics

    public init(title: String, subtitle: String?, horizontalInset: CGFloat) {
        self.title = title
        self.subtitle = subtitle
        self.horizontalInset = horizontalInset
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: metrics.cardTitleFontSize, weight: .semibold))
                .foregroundStyle(Color.primary)
                .lineLimit(1)
            Text(subtitle ?? " ")
                .font(.system(size: metrics.cardSubtitleFontSize))
                .foregroundStyle(Color.secondary)
                .lineLimit(1)
                .opacity(subtitle == nil ? 0 : 1)
        }
        .padding(.horizontal, horizontalInset)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
#endif
