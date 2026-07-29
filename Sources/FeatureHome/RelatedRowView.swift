#if canImport(SwiftUI)
import CoreModels
import CoreUI
import FeatureHomeCore
import SwiftUI

/// The "Related" rail on a detail page: other titles in the viewer's library
/// connected to the one on screen.
///
/// Built on the shared ``MediaRowView`` rather than a hand-rolled rail, so it
/// inherits the focus, scroll and lazy-realisation behaviour every other row has —
/// including the vertical clearance a focused card's lift needs, the absence of
/// which squashed the artwork to a sliver when this was its own `LazyHStack`.
///
/// Every entry is a real library item, verified by external id, so each card
/// behaves exactly like one on Home. A related title the viewer doesn't own never
/// reaches this view: Plozz can't play it, and a poster that does nothing when
/// selected is worse than an absent row.
struct RelatedRowView: View {
    let entries: [RelatedEntry]
    /// Whether resolution has finished. While it hasn't, the row holds its space
    /// with placeholders: results arrive well after first paint, and letting the
    /// row appear late shoved the cast — which the viewer may already be reading —
    /// down the page.
    var hasResolved: Bool = true
    var leadingInset: CGFloat = PlozzTheme.Metrics.screenPadding
    var spoilerSettings: SpoilerSettings = .default
    var onSelect: (MediaItem) -> Void
    var onFocusEntered: (() -> Void)?

    @Environment(\.plozzMetrics) private var metrics

    var body: some View {
        Group {
            if !items.isEmpty {
                MediaRowView(
                    title: Text("Related"),
                    items: items,
                    style: .poster,
                    spoilerSettings: spoilerSettings,
                    leadingInset: leadingInset,
                    onFocusEntered: onFocusEntered,
                    statusCue: { item in
                        continuationItemIDs.contains(item.id) ? "Continues" : nil
                    },
                    onSelect: onSelect
                )
            } else if !hasResolved {
                placeholder
            }
        }
        // Both states carry the same rail rhythm before this cancellation:
        // MediaRowView supplies it through the scroll viewport; `placeholder`
        // mirrors it around its non-scrolling HStack. Keeping this modifier outside
        // the branch makes their title, cards, and total footprint identical.
        .padding(.top, -metrics.railTopPadding)
        .padding(.bottom, -metrics.railVerticalPadding)
        // Resolved and empty: the row collapses. A title with nothing related in
        // this library is rare but real, and permanent placeholders for content
        // that will never arrive are worse than no row.
    }

    /// Same geometry as the loaded row, so filling it shifts nothing.
    private var placeholder: some View {
        VStack(alignment: .leading, spacing: metrics.sectionTitleSpacing) {
            Text("Related")
                .font(.system(size: metrics.sectionHeaderFontSize, weight: .bold))
                .padding(.leading, leadingInset)
            HStack(spacing: metrics.cardSpacing) {
                ForEach(0..<Self.placeholderCount, id: \.self) { _ in
                    // Pinned to the same slot width the loaded row gives a card
                    // (`MediaRowView.cardSlotWidth`). Without it the placeholder
                    // drew at its own intrinsic size, so the row visibly resized
                    // when the real cards arrived — the jump the placeholder is
                    // there to prevent.
                    SkeletonCardView(style: .poster)
                        .frame(width: metrics.posterWidth)
                }
            }
            .padding(.leading, leadingInset)
            // Match MediaRowView's effective scroll-viewport clearance. The loaded
            // row places its cards `railTopPadding` below the title and reserves
            // `railVerticalPadding` below them after its internal shadow padding is
            // cancelled. Without these, the skeleton sat 16pt higher and 40pt
            // shorter, so the episode/Related composition shifted when cards loaded.
            .padding(.top, metrics.railTopPadding)
            .padding(.bottom, metrics.railVerticalPadding)
            // Non-focusable so the focus engine never anchors on a placeholder and
            // strands focus where a card is about to be replaced.
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
    }

    /// Enough to read as a row without measuring the viewport — the placeholders
    /// are clipped at the trailing edge exactly as real cards are.
    private static let placeholderCount = 8

    private var items: [MediaItem] { entries.compactMap(\.libraryItem) }
    private var continuationItemIDs: Set<String> {
        Set(entries.compactMap { entry in
            entry.isContinuation ? entry.libraryItem?.id : nil
        })
    }
}
#endif
