#if os(iOS)
import CoreModels
import CoreUI
import FeatureHomeCore
import SwiftUI

/// The "Related" rail on an iOS/iPadOS detail page: other titles in the viewer's
/// library connected to the one on screen.
///
/// Mirrors the tvOS row — same resolution, same id-verified matching, same
/// placement above the cast — rendered with the phone/tablet poster card so it sits
/// with the rest of the page rather than importing a TV-sized rail.
struct PlozziOSRelatedSection: View {
    @Environment(\.plozzCardStyle) private var cardStyle
    @Environment(\.plozzMetrics) private var metrics

    let entries: [RelatedEntry]
    var inset: CGFloat
    var onSelect: (MediaItem) -> Void

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Related")
                    .font(.title3.weight(.bold))
                    .padding(.horizontal, inset)

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: metrics.cardSpacing) {
                        ForEach(items, id: \.stablePresentationID) { item in
                            Button {
                                onSelect(item)
                            } label: {
                                PlozziOSPosterCard(
                                    item: item,
                                    // A sequel to the thing you're looking at is
                                    // the news on this row; ordering alone doesn't
                                    // say so. Matches tvOS.
                                    statusCue: continuationItemIDs.contains(item.id)
                                        ? "Continues"
                                        : nil
                                )
                                .frame(width: cardWidth)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, inset)
                }
                .scrollClipDisabled()
            }
        }
    }

    private var items: [MediaItem] { entries.map(\.item) }
    private var cardWidth: CGFloat {
        metrics.cardSlotWidth(for: .poster, cardStyle: cardStyle)
    }

    /// Library ids of the entries that continue the seed's own story, so the cue
    /// follows the *relation* rather than anything about the matched item.
    private var continuationItemIDs: Set<String> {
        Set(entries.compactMap { $0.isContinuation ? $0.item.id : nil })
    }
}
#endif
