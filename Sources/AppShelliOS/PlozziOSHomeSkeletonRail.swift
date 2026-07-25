#if os(iOS)
import CoreUI
import FeatureHomeCore
import SwiftUI

/// Placeholder rail shown while a Home row's items are still loading.
///
/// Reuses `CoreUI.SkeletonCardView` — the same placeholder card tvOS's
/// `HomeSkeletonView` renders — so both platforms share one definition of what a
/// loading card looks like. Only the *rail* geometry is duplicated here, because
/// the tvOS skeleton is built around overscan-safe screen padding and its own
/// row metrics, while iOS uses `PlozziOSPageLayout` insets and `contentMargins`.
///
/// Geometry mirrors `PlozziOSHomeMediaRail` exactly (title font, 12pt title gap,
/// 14pt card spacing, the same `cardSlotWidth`, the same horizontal/vertical
/// content margins). That 1:1 match is the point: when the real items arrive the
/// cards swap in place, so nothing reflows or jumps.
struct PlozziOSHomeSkeletonRail: View {
    @Environment(\.plozzCardStyle) private var cardStyle
    @Environment(\.plozzMetrics) private var metrics
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let title: String
    let style: PosterCardView.Style
    /// Enough cards to fill the widest supported screen; the rail clips the rest.
    var cardCount: Int = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title2.bold())
                .padding(
                    .horizontal,
                    PlozziOSPageLayout.horizontalInset(for: horizontalSizeClass)
                )

            ScrollView(.horizontal) {
                // Deliberately NOT lazy: the placeholders are cheap, and a lazy
                // stack would only materialise the ones already on screen — the
                // opposite of what a "never show a blank row" placeholder is for.
                HStack(alignment: .top, spacing: 14) {
                    ForEach(0..<cardCount, id: \.self) { _ in
                        SkeletonCardView(style: style == .landscape ? .landscape : .poster)
                            .frame(
                                width: metrics.cardSlotWidth(
                                    for: style,
                                    cardStyle: cardStyle
                                )
                            )
                    }
                }
            }
            .contentMargins(
                .horizontal,
                PlozziOSPageLayout.horizontalInset(for: horizontalSizeClass),
                for: .scrollContent
            )
            .contentMargins(.vertical, 10, for: .scrollContent)
            .scrollIndicators(.hidden)
            // The placeholders are not content the viewer can act on.
            .scrollDisabled(true)
            .accessibilityHidden(true)
        }
    }
}

/// Whole-Home placeholder shown before the first rows resolve.
///
/// Deliberately mirrors the real Home's shape — a couple of poster rails with a
/// landscape "Continue Watching"-style rail — so the page doesn't visibly
/// restructure when content lands. A spinner was previously shown here, which
/// gave no sense of the layout and left the screen blank-feeling on a cold load.
struct PlozziOSHomeSkeletonScreen: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                PlozziOSHomeHeroSkeleton(
                    style: horizontalSizeClass == .compact
                        ? .compactPortrait
                        : .landscape
                )
                PlozziOSHomeSkeletonRail(title: " ", style: .landscape)
                PlozziOSHomeSkeletonRail(title: " ", style: .poster)
                PlozziOSHomeSkeletonRail(title: " ", style: .poster)
            }
        }
        .scrollDisabled(true)
        .accessibilityLabel("Loading Home")
    }
}

/// Placeholder for the Home hero, mirroring tvOS's `HomeHeroSkeletonView`.
///
/// Reserves the hero's real height (`PlozziOSHeroMetrics.height`) so the rows
/// below don't get pushed down when the hero resolves, and pins soft capsules to
/// the bottom where the metadata line and action buttons will be — the same
/// shape tvOS uses. No backdrop: the artwork area stays empty while loading
/// rather than flashing a placeholder colour behind the whole screen.
struct PlozziOSHomeHeroSkeleton: View {
    @Environment(\.themePalette) private var palette
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let style: HeroArtworkStyle

    var body: some View {
        VStack(alignment: style == .compactPortrait ? .center : .leading, spacing: 12) {
            // Metadata line (year · rating · runtime).
            capsule(width: 190, height: 22)
            // Two overview lines.
            capsule(width: style == .compactPortrait ? 260 : 460, height: 16)
            capsule(width: style == .compactPortrait ? 200 : 360, height: 16)
            // Action row: the Play pill plus the icon buttons beside it.
            HStack(spacing: 12) {
                capsule(width: 150, height: 50)
                capsule(width: 50, height: 50)
                capsule(width: 50, height: 50)
                capsule(width: 50, height: 50)
            }
            .padding(.top, 4)
        }
        .frame(
            maxWidth: .infinity,
            minHeight: PlozziOSHeroMetrics.height(
                style: style,
                surfaceRole: .home,
                dynamicTypeSize: dynamicTypeSize
            ),
            alignment: style == .compactPortrait ? .bottom : .bottomLeading
        )
        .padding(.horizontal, PlozziOSPageLayout.horizontalInset(for: style))
        .padding(.bottom, 28)
        // Shimmer only the placeholder shapes, never a full-bleed backdrop.
        .shimmering()
        .accessibilityHidden(true)
    }

    private func capsule(width: CGFloat, height: CGFloat) -> some View {
        Capsule(style: .continuous)
            .fill(palette.fill)
            .frame(width: width, height: height)
    }
}
#endif
