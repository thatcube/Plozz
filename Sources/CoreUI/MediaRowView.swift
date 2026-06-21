#if canImport(SwiftUI)
import SwiftUI
import CoreModels

/// A horizontally-scrolling, focusable row of media cards with a title.
/// Reused by Home (Continue Watching, Latest) and detail (episodes, related).
public struct MediaRowView: View {
    private let title: String
    private let items: [MediaItem]
    private let style: PosterCardView.Style
    private let spoilerSettings: SpoilerSettings
    private let onSelect: (MediaItem) -> Void

    public init(
        title: String,
        items: [MediaItem],
        style: PosterCardView.Style = .poster,
        spoilerSettings: SpoilerSettings = .default,
        onSelect: @escaping (MediaItem) -> Void
    ) {
        self.title = title
        self.items = items
        self.style = style
        self.spoilerSettings = spoilerSettings
        self.onSelect = onSelect
    }

    public var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                Text(title)
                    .font(.title2).bold()
                    .padding(.leading, PlozzTheme.Metrics.screenPadding)

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: PlozzTheme.Metrics.cardSpacing) {
                        ForEach(items) { item in
                            PosterCardView(item: item, style: style, spoilerSettings: spoilerSettings) { onSelect(item) }
                        }
                    }
                    .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
                    // Give focus room so the lifted card isn't clipped.
                    .padding(.vertical, 24)
                }
            }
        }
    }
}

#endif
