#if canImport(SwiftUI)
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// A non-interactive placeholder that mirrors `PosterCardView`'s outer geometry
/// exactly (same glass surface, paddings, artwork aspect/corner radii and the
/// two text lines beneath) but renders soft neutral fills instead of a real
/// `MediaItem`.
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

    @Environment(\.plozzMetrics) private var metrics

    public init(style: Style = .poster) {
        self.style = style
    }

    public var body: some View {
        switch style {
        case .poster: posterCard
        case .landscape: landscapeCard
        }
    }

    // Mirrors `PosterCardView.posterCard`.
    private var posterCard: some View {
        VStack(alignment: .leading, spacing: metrics.posterCaptionTopSpacing) {
            Color.clear
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay {
                    RoundedRectangle(cornerRadius: PlozzTheme.Metrics.posterArtCornerRadius, style: .continuous)
                        .fill(Color.plozzSkeletonFill)
                }
                .clipShape(RoundedRectangle(cornerRadius: PlozzTheme.Metrics.posterArtCornerRadius, style: .continuous))
                .plozzMediaEdge(cornerRadius: PlozzTheme.Metrics.posterArtCornerRadius)

            // Match PosterCardView's caption: VStack(spacing: 2), subheadline +
            // size-20 fonts. Reusing the same fonts (via hidden sizing text) keeps
            // the caption block the exact same height, so the row never shifts
            // vertically when real content swaps in.
            textLines(contentWidth: metrics.posterWidth - 2 * metrics.posterCaptionInset, spacing: 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding([.horizontal, .bottom], metrics.posterCaptionInset)
        }
        .padding(metrics.cardInset)
        .plozzGlassCard(cornerRadius: metrics.posterCardCornerRadius, isFocused: false)
        .shimmering()
    }

    // Mirrors `PosterCardView.landscapeCard`.
    private var landscapeCard: some View {
        VStack(alignment: .leading, spacing: metrics.landscapeCaptionTopSpacing) {
            RoundedRectangle(cornerRadius: PlozzTheme.Metrics.mediumMediaCornerRadius, style: .continuous)
                .fill(Color.plozzSkeletonFill)
                .frame(width: metrics.landscapeWidth, height: metrics.landscapeHeight)
                .clipShape(RoundedRectangle(cornerRadius: PlozzTheme.Metrics.mediumMediaCornerRadius, style: .continuous))
                .plozzMediaEdge(cornerRadius: PlozzTheme.Metrics.mediumMediaCornerRadius)

            // PosterCardView's landscape caption uses VStack(spacing: 4).
            textLines(contentWidth: metrics.landscapeWidth - 2 * metrics.landscapeCaptionInset, spacing: 4)
                .padding([.horizontal, .bottom], metrics.landscapeCaptionInset)
                .frame(width: metrics.landscapeWidth, alignment: .leading)
        }
        .padding(metrics.cardInset)
        .plozzGlassCard(cornerRadius: metrics.landscapeCardCornerRadius, isFocused: false)
        .shimmering()
    }

    /// Two fully-rounded placeholder pills standing in for the card's title and
    /// subtitle. Each pill is laid inside a hidden sizing `Text` using the *same*
    /// font the real card uses, so the line reserves the identical height — the
    /// capsule is just a shorter shape leading-aligned within it. This keeps the
    /// caption block height pixel-identical to `PosterCardView` (no vertical shift
    /// on load) while giving the placeholders soft, fully-rounded edges.
    private func textLines(contentWidth: CGFloat, spacing: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: spacing) {
            capsuleLine(font: .system(size: metrics.cardTitleFontSize, weight: .semibold), width: max(contentWidth * 0.7, 1), height: (16 * metrics.scale).rounded())
            capsuleLine(font: .system(size: metrics.cardSubtitleFontSize), width: max(contentWidth * 0.45, 1), height: (13 * metrics.scale).rounded())
        }
    }

    private func capsuleLine(font: Font, width: CGFloat, height: CGFloat) -> some View {
        // The hidden text drives the line's height to match the real caption's
        // font metrics exactly; the capsule (shorter) is overlaid, leading-aligned.
        Text(" ")
            .font(font)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hidden()
            .overlay(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.plozzSkeletonFill)
                    .frame(width: width, height: height)
            }
    }
}

public extension Color {
    /// Adaptive neutral fill for skeleton placeholders: a light gray on dark/OLED
    /// backgrounds (so cards read clearly against pure black) and a darker gray in
    /// light mode. Kept low-opacity so it stays a quiet placeholder, not a solid
    /// block.
    static var plozzSkeletonFill: Color {
        #if canImport(UIKit)
        return Color(UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(white: 1.0, alpha: 0.11)
                : UIColor(white: 0.0, alpha: 0.12)
        })
        #else
        return Color.gray.opacity(0.12)
        #endif
    }
}

#endif
