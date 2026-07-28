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
    let entries: [RelatedEntry]
    var inset: CGFloat
    var onSelect: (MediaItem) -> Void

    @ScaledMetric(relativeTo: .body) private var cardWidth: CGFloat = 116

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Related")
                    .font(.title3.weight(.bold))
                    .padding(.horizontal, inset)

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(items) { item in
                            Button {
                                onSelect(item)
                            } label: {
                                PlozziOSPosterCard(item: item)
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

    private var items: [MediaItem] { entries.compactMap(\.libraryItem) }
}
