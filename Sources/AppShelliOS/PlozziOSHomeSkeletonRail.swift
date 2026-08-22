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

    let title: Text
    let style: PosterCardView.Style
    /// Enough cards to fill the widest supported screen; the rail clips the rest.
    var cardCount: Int = 8
    /// Matches the caption-less Continue Watching card, so the placeholder is the
    /// same height as the card replacing it.
    var showsCaption: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            title
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
                        SkeletonCardView(
                            style: style == .landscape ? .landscape : .poster,
                            showsCaption: showsCaption
                        )
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
                PlozziOSHomeSkeletonRail(title: Text(verbatim: " "), style: .landscape)
                PlozziOSHomeSkeletonRail(title: Text(verbatim: " "), style: .poster)
                PlozziOSHomeSkeletonRail(title: Text(verbatim: " "), style: .poster)
            }
        }
        .scrollDisabled(true)
        .accessibilityLabel("Loading Home")
    }
}

/// Placeholder for the Home hero, mirroring tvOS's `HomeHeroSkeletonView`.
///
/// Placement comes from `PlozziOSHeroForegroundPlacement`, the same modifier the
/// real foreground uses, so the two cannot drift as screen sizes change — an
/// earlier version copied the constants by hand and sat visibly lower and
/// further indented than the content it stood in for. Only the hero's height is
/// applied here, from the same `PlozziOSHeroMetrics.height` the carousel uses.
///
/// No backdrop: the artwork area stays empty while loading rather than flashing
/// a placeholder colour across the screen, and the shimmer is confined to the
/// small shapes — both as tvOS does it.
struct PlozziOSHomeHeroSkeleton: View {
    @Environment(\.themePalette) private var palette
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let style: HeroArtworkStyle

    private var isCompact: Bool { style == .compactPortrait }

    var body: some View {
        // Establish the stage FIRST, then place the column inside it — mirroring
        // the real carousel, where the ZStack holding the foreground is what
        // carries `.frame(height: heroHeight)`. Applying the height *after* the
        // placement instead left the placement's `maxHeight: .infinity` resolving
        // against an unbounded scroll proposal, so the column was sized to its
        // content and then re-centred rather than pinned to the hero's bottom.
        Color.clear
            .frame(
                height: PlozziOSHeroMetrics.height(
                    style: style,
                    surfaceRole: .home,
                    dynamicTypeSize: dynamicTypeSize
                )
            )
            .overlay {
                column
                    // The SAME placement the real foreground uses — not a copy of
                    // its numbers. See `PlozziOSHeroForegroundPlacement`.
                    .plozziOSHeroForegroundPlacement(style: style)
            }
            .shimmering()
            .accessibilityHidden(true)
    }

    /// Mirrors `PlozziOSHomeHeroForeground`: the metadata block, then the action
    /// row, in a 12pt VStack.
    private var column: some View {
        VStack(alignment: isCompact ? .center : .leading, spacing: 12) {
            metadataBlock
            actionRow
        }
    }

    /// Mirrors `PlozziOSHeroMetadata`'s 9pt VStack: title/logo, genres line,
    /// overview.
    private var metadataBlock: some View {
        VStack(alignment: isCompact ? .center : .leading, spacing: 9) {
            // Title block — the real hero shows a logo capped at this height, or
            // a two-line .largeTitle. Reserve the same box.
            bar(width: isCompact ? 260 : 380, height: isCompact ? 95 : 130)
            // Genres — .subheadline, one line.
            textBar(font: .subheadline, width: isCompact ? 220 : 300)
            // Overview — .subheadline, up to three lines.
            textBar(font: .subheadline, width: isCompact ? 300 : 460)
            textBar(font: .subheadline, width: isCompact ? 280 : 430)
            textBar(font: .subheadline, width: isCompact ? 200 : 320)
        }
    }

    /// Mirrors the action row: pills whose height is driven by the same
    /// `.headline` label plus `PlozziOSHeroActionButtonStyle`'s 12pt vertical
    /// padding and 48pt floor, so the row grows with Dynamic Type exactly as the
    /// real buttons do.
    private var actionRow: some View {
        HStack(spacing: 12) {
            pill(width: 150)
            pill(width: 48)
            pill(width: 48)
            pill(width: 48)
        }
    }

    /// A bar sized to a real font's line height, so Dynamic Type scales the
    /// placeholder exactly like the text it stands in for. Fixed point heights
    /// were what made the content jump when the real hero replaced it — they
    /// only matched at the smallest text size.
    private func textBar(font: Font, width: CGFloat) -> some View {
        Text(verbatim: " ")
            .font(font)
            .hidden()
            .frame(width: width)
            .background {
                Capsule(style: .continuous).fill(palette.fill)
            }
    }

    private func pill(width: CGFloat) -> some View {
        Text(verbatim: " ")
            .font(.headline.weight(.semibold))
            .hidden()
            .padding(.vertical, 12)
            .frame(width: width)
            .frame(minHeight: 48)
            .background {
                Capsule(style: .continuous).fill(palette.fill)
            }
    }

    private func bar(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(palette.fill)
            .frame(width: width, height: height)
    }

    private func capsule(width: CGFloat, height: CGFloat) -> some View {
        Capsule(style: .continuous)
            .fill(palette.fill)
            .frame(width: width, height: height)
    }
}
#endif
