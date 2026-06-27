#if canImport(SwiftUI)
import SwiftUI

/// A non-interactive placeholder that mirrors `PosterCardView`'s outer geometry
/// exactly (same glass surface, paddings, artwork aspect/corner radii and the
/// two text lines beneath) but renders redacted, shimmering content instead of a
/// real `MediaItem`.
///
/// Keeping this in lock-step with `PosterCardView` — via the shared
/// `PlozzTheme.Metrics` and the same layout structure — is what makes a skeleton
/// row pixel-for-pixel 1:1 with the loaded row, so nothing shifts or reflows when
/// real content swaps in. It is deliberately **not** focusable: skeleton cards
/// must never take focus, or the tvOS focus engine would anchor on a placeholder
/// and lose its place when the real cards arrive.
public struct SkeletonCardView: View {
    public enum Style { case poster, landscape }

    private let style: Style

    public init(style: Style = .poster) {
        self.style = style
    }

    /// Adapts to light/dark like the real card's artwork placeholder.
    private var artFill: some ShapeStyle { .quaternary }

    public var body: some View {
        switch style {
        case .poster: posterCard
        case .landscape: landscapeCard
        }
    }

    // Mirrors `PosterCardView.posterCard`.
    private var posterCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Color.clear
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay {
                    RoundedRectangle(cornerRadius: PlozzTheme.Metrics.posterArtCornerRadius, style: .continuous)
                        .fill(artFill)
                }
                .clipShape(RoundedRectangle(cornerRadius: PlozzTheme.Metrics.posterArtCornerRadius, style: .continuous))
                .plozzMediaEdge(cornerRadius: PlozzTheme.Metrics.posterArtCornerRadius)

            textLines(titleFont: .subheadline.weight(.semibold), subtitleFont: .system(size: 20), spacing: 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
                .padding(.bottom, 4)
        }
        .padding(10)
        .plozzGlassCard(cornerRadius: PlozzTheme.Metrics.posterCardCornerRadius, isFocused: false)
        .shimmering()
    }

    // Mirrors `PosterCardView.landscapeCard`.
    private var landscapeCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: PlozzTheme.Metrics.mediumMediaCornerRadius, style: .continuous)
                .fill(artFill)
                .frame(width: PlozzTheme.Metrics.landscapeWidth, height: PlozzTheme.Metrics.landscapeHeight)
                .clipShape(RoundedRectangle(cornerRadius: PlozzTheme.Metrics.mediumMediaCornerRadius, style: .continuous))
                .plozzMediaEdge(cornerRadius: PlozzTheme.Metrics.mediumMediaCornerRadius)

            textLines(titleFont: .subheadline.weight(.semibold), subtitleFont: .system(size: 20), spacing: 4)
                .frame(width: PlozzTheme.Metrics.landscapeWidth, alignment: .leading)
        }
        .padding(PlozzTheme.Metrics.mediumCardInset)
        .plozzGlassCard(cornerRadius: PlozzTheme.Metrics.mediumCardCornerRadius, isFocused: false)
        .shimmering()
    }

    /// Two redacted text lines sized by the same fonts the real card uses, so the
    /// caption block has identical height. `.redacted` keeps the bars' metrics
    /// tied to the font rather than hard-coded sizes.
    private func textLines(titleFont: Font, subtitleFont: Font, spacing: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: spacing) {
            Text("Placeholder title")
                .font(titleFont)
                .lineLimit(1)
            Text("Placeholder subtitle")
                .font(subtitleFont)
                .lineLimit(1)
        }
        .redacted(reason: .placeholder)
    }
}

#endif
