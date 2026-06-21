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
    /// When set, the row scrolls to and moves focus onto the matching item the
    /// first time it appears (used by series/season detail to surface the
    /// "next up" episode). `nil` keeps the platform's default focus behaviour.
    private let initialFocusID: String?
    private let onSelect: (MediaItem) -> Void

    @FocusState private var focusedID: String?
    @State private var didApplyInitialFocus = false

    public init(
        title: String,
        items: [MediaItem],
        style: PosterCardView.Style = .poster,
        spoilerSettings: SpoilerSettings = .default,
        initialFocusID: String? = nil,
        onSelect: @escaping (MediaItem) -> Void
    ) {
        self.title = title
        self.items = items
        self.style = style
        self.spoilerSettings = spoilerSettings
        self.initialFocusID = initialFocusID
        self.onSelect = onSelect
    }

    public var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                Text(title)
                    .font(.title2).bold()
                    .padding(.leading, PlozzTheme.Metrics.screenPadding)

                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: PlozzTheme.Metrics.cardSpacing) {
                            ForEach(items) { item in
                                card(for: item)
                            }
                        }
                        .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
                        // Give the focused card's lift + drop shadow room so it is
                        // never clipped by the scroll view's bounds.
                        .padding(.top, 16)
                        .padding(.bottom, PlozzTheme.Metrics.railVerticalPadding)
                    }
                    .onAppear { applyInitialFocus(using: proxy) }
                }
            }
        }
    }

    @ViewBuilder
    private func card(for item: MediaItem) -> some View {
        let card = PosterCardView(item: item, style: style, spoilerSettings: spoilerSettings) { onSelect(item) }
            .id(item.id)
        if initialFocusID != nil {
            card.focused($focusedID, equals: item.id)
        } else {
            card
        }
    }

    /// Scrolls to and focuses `initialFocusID` exactly once, after the row first
    /// lays out. The focus assignment is deferred a runloop tick so SwiftUI has
    /// installed the focusable cards before we move focus onto one.
    private func applyInitialFocus(using proxy: ScrollViewProxy) {
        guard let target = initialFocusID,
              !didApplyInitialFocus,
              items.contains(where: { $0.id == target }) else { return }
        didApplyInitialFocus = true
        proxy.scrollTo(target, anchor: .leading)
        DispatchQueue.main.async { focusedID = target }
    }
}

#endif
