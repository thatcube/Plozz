#if canImport(SwiftUI)
import SwiftUI
import CoreModels

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
    /// When the profile has turned the focus outline **off**
    /// (`CardFocusStyle.highlight`) there is no halo at all: the tile takes tvOS's
    /// native treatment instead, growing by whatever the halo used to add to its
    /// size and catching a specular sweep (see `plozzCardFocusLift`). Callers don't
    /// choose — they keep asking for a halo and get whichever the profile wants.
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
    @Environment(\.plozzCardFocusStyle) private var focusStyle

    func body(content: Content) -> some View {
        if focusStyle.drawsFocusOutline {
            outlined(content)
        } else {
            // No halo: the tile grows into the space the halo occupied and
            // glistens instead. It keeps the halo's drop shadow, though — that
            // shadow is what lifted the tile off the page, and an artwork-only
            // card with neither outline nor shadow reads as flat rather than
            // focused. Expressed as animatable values rather than an `if` so it
            // fades with the lift; a fully transparent shadow draws nothing.
            content
                .shadow(
                    color: .black.opacity(isFocused ? 0.36 : 0),
                    radius: isFocused ? 20 : 0,
                    y: isFocused ? 10 : 0
                )
                .plozzCardFocusLift(
                    isFocused: isFocused,
                    cornerRadius: cornerRadius,
                    outlineScale: focusScale,
                    outlineReach: metrics.circleFocusPadding
                )
        }
    }

    private func outlined(_ content: Content) -> some View {
        let pad = metrics.circleFocusPadding
        return content
            .background {
                // The shared liquid-glass focus surface, bloomed into a band around
                // the artwork: sized to the artwork by `.background`, then grown
                // `pad` beyond every edge with negative padding (backgrounds draw
                // outside the content bounds), its radius bumped to stay concentric.
                //
                // BUILT ONLY WHEN FOCUSED, and that is a performance requirement,
                // not tidiness. This asks for `isFocused: true` unconditionally —
                // real refractive Liquid Glass, a live backdrop effect — plus a
                // 20pt shadow. Hiding that with `.opacity(0)` still renders it, so
                // every card in a row paid for a focus surface that was then
                // multiplied by zero: measured at ~100 offscreen passes per frame
                // on an A12 Apple TV, for a 3.3% hitch ratio. Only one card can
                // hold focus, so only one should ever build this.
                if isFocused {
                    Color.clear
                        .plozzGlassCard(cornerRadius: cornerRadius + pad, isFocused: true)
                        .padding(-pad)
                        .shadow(color: .black.opacity(0.36), radius: 20, y: 10)
                        .transition(.opacity)
                }
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
    /// The title. `Text`, not `String`, since this caption is also used to show
    /// `PosterCardView`'s spoiler-masked episode title (our own copy) alongside
    /// its normal (content) media-title use — see `PosterCardView.primaryText`.
    private let title: Text
    private let subtitle: String?   // l10n:content — media title/subtitle from the server
    private let horizontalInset: CGFloat
    private let reservesSubtitleSpace: Bool

    @Environment(\.plozzMetrics) private var metrics

    public init(
        title: Text,
        subtitle: String?,   // l10n:content — media title/subtitle from the server
        horizontalInset: CGFloat,
        reservesSubtitleSpace: Bool = true
    ) {
        self.title = title
        self.subtitle = subtitle
        self.horizontalInset = horizontalInset
        self.reservesSubtitleSpace = reservesSubtitleSpace
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            title
                .font(.system(size: metrics.cardTitleFontSize, weight: .semibold))
                .foregroundStyle(Color.primary)
                .lineLimit(1)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: metrics.cardSubtitleFontSize))
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
            } else if reservesSubtitleSpace {
                Text(verbatim: " ")
                    .font(.system(size: metrics.cardSubtitleFontSize))
                    .hidden()
            }
        }
        .padding(.horizontal, horizontalInset)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
#endif
