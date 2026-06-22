#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

/// The Search screen: a `.searchable` field over a sectioned poster grid of
/// results (Movies / TV Shows / Episodes), with the standard loading, empty and
/// error states.
public struct SearchView: View {
    @State private var viewModel: SearchViewModel
    private let spoilerSettings: SpoilerSettings
    private let onSelect: (MediaItem) -> Void

    public init(
        viewModel: SearchViewModel,
        spoilerSettings: SpoilerSettings = .default,
        onSelect: @escaping (MediaItem) -> Void
    ) {
        _viewModel = State(initialValue: viewModel)
        self.spoilerSettings = spoilerSettings
        self.onSelect = onSelect
    }

    private let columns = [
        GridItem(
            .adaptive(minimum: PlozzTheme.Metrics.posterWidth, maximum: PlozzTheme.Metrics.posterWidth),
            spacing: PlozzTheme.Metrics.cardSpacing,
            alignment: .leading
        )
    ]

    public var body: some View {
        content
            .searchable(text: $viewModel.query, prompt: "Search movies, shows, and episodes")
            .task(id: viewModel.query) { await viewModel.search() }
            .onReceive(NotificationCenter.default.publisher(for: .mediaItemDidMutate)) { _ in
                Task { await viewModel.search() }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle:
            hint
        default:
            ContentStateView(
                state: viewModel.state,
                emptyMessage: "No results. Try a different search.",
                onRetry: { Task { await viewModel.search() } }
            ) { sections in
                results(sections)
            }
        }
    }

    private var hint: some View {
        VStack(spacing: 24) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 72))
                .foregroundStyle(.secondary)
            Text("Search for movies, shows, and episodes")
                .font(.title2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func results(_ sections: [SearchSection]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: PlozzTheme.Metrics.rowSpacing) {
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: 16) {
                        Text(section.title)
                            .font(.system(size: 32, weight: .bold))
                            .padding(.leading, PlozzTheme.Metrics.screenPadding)

                        LazyVGrid(columns: columns, alignment: .leading, spacing: PlozzTheme.Metrics.cardSpacing) {
                            ForEach(section.items) { item in
                                PosterCardView(item: item, style: .poster, spoilerSettings: spoilerSettings) {
                                    onSelect(item)
                                }
                            }
                        }
                        .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
                        // Give focus room so the lifted card isn't clipped.
                        .padding(.vertical, 24)
                        .focusSection()
                    }
                }
            }
            .padding(.vertical, 40)
        }
        // Never clip a focused card's lift, shadow or border.
        .scrollClipDisabled()
    }
}

#endif
