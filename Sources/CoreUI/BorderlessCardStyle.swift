#if canImport(SwiftUI)
import SwiftUI

/// Shared building blocks for the borderless ("Posters") `CardStyle` — the
/// artwork-only look with **no** glass surface. Both the movie/show
/// `PosterCardView` and the music `MusicCard` compose these so the two stay
/// pixel-identical.
public extension View {
    /// Applies the borderless card's focus treatment to an already-clipped
    /// artwork view: a crisp **outline** hugging the rounded artwork edge, a soft
    /// lift shadow, and the focus scale — all animating in together on focus.
    ///
    /// The outline is an `overlay` drawn *before* the `scaleEffect`, so it scales
    /// with the artwork and always frames the card exactly (a real outline around
    /// the card, never a detached ring behind it). It's outset by its own width so
    /// it sits just outside the artwork edge, concentric with the corner. At rest
    /// there is no surface or ring at all — just the artwork.
    func plozzBorderlessArtworkFocus(
        cornerRadius: CGFloat,
        focusScale: CGFloat,
        isFocused: Bool
    ) -> some View {
        modifier(BorderlessArtworkFocusModifier(
            cornerRadius: cornerRadius,
            focusScale: focusScale,
            isFocused: isFocused
        ))
    }
}

private struct BorderlessArtworkFocusModifier: ViewModifier {
    let cornerRadius: CGFloat
    let focusScale: CGFloat
    let isFocused: Bool

    @Environment(\.plozzMetrics) private var metrics

    func body(content: Content) -> some View {
        let outline = metrics.borderlessFocusOutlineWidth
        content
            .overlay {
                // Concentric outset ring: the shape frame is grown by `outline` on
                // every side (padding(-outline)) and its radius bumped to match, so
                // `strokeBorder` paints the ring in the band immediately *outside*
                // the artwork edge — framing it rather than covering the art.
                RoundedRectangle(cornerRadius: cornerRadius + outline, style: .continuous)
                    .strokeBorder(Color.white, lineWidth: outline)
                    .padding(-outline)
                    .opacity(isFocused ? 1 : 0)
            }
            .shadow(color: .black.opacity(isFocused ? 0.35 : 0), radius: 18, y: 8)
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
