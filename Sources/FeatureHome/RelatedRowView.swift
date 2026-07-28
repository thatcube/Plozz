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
            // `MediaRowView` carries the vertical rhythm a Home screen needs, where
            // rows abut directly. Here the enclosing stack already spaces its
            // sections, so that padding lands on top of it — 96pt between this row
            // and the cast, which pushed the cast off the screen entirely. Cancelled
            // so the stack remains the single source of spacing; the row's *clip*
            // clearance (what keeps a focused card's lift from being cut) is applied
            // separately inside and is untouched.
            .padding(.top, -metrics.railTopPadding)
            .padding(.bottom, -metrics.railVerticalPadding)
        } else if !hasResolved {
            placeholder
        }
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
                    SkeletonCardView(style: .poster)
                }
            }
            .padding(.leading, leadingInset)
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
