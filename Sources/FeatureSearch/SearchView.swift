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

    @Environment(\.plozzMetrics) private var metrics

    public init(
        viewModel: SearchViewModel,
        spoilerSettings: SpoilerSettings = .default,
        onSelect: @escaping (MediaItem) -> Void
    ) {
        _viewModel = State(initialValue: viewModel)
        self.spoilerSettings = spoilerSettings
        self.onSelect = onSelect
    }


    public var body: some View {
        content
            .searchable(text: $viewModel.query, prompt: "Search movies, shows, and episodes")
            .task(id: viewModel.query) { await viewModel.search() }
            .onReceive(NotificationCenter.default.publisher(for: .mediaItemDidMutate)) { note in
                if let mutation = MediaItemMutation.from(note) {
                    viewModel.applyWatchedState(mutation)
                } else {
                    Task { await viewModel.search() }
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle:
            // Before the first search there's nothing to show — keep it clean.
            Color.clear
        case .empty:
            noResults
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

    private var noResults: some View {
        VStack(spacing: 24) {
            Image("PlozzLogoSad")
                .resizable()
                .interpolation(.none)
                .scaledToFit()
                .frame(width: 80, height: 80)
            Text("No results. Try a different search.")
                .font(.title2)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 800)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func results(_ sections: [SearchSection]) -> some View {
        // Shared dense "Browse" wall — identical column count and gutters to the
        // library grid (both from the live density metrics), so Search and
        // Library read as the same surface and scale together.
        let columns = metrics.posterColumns
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: metrics.rowSpacing) {
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: metrics.sectionTitleSpacing) {
                        Text(section.title)
                            .font(.system(size: metrics.sectionHeaderFontSize, weight: .bold))
                            .padding(.leading, PlozzTheme.Metrics.screenPadding)

                        LazyVGrid(columns: columns, alignment: .leading, spacing: metrics.gridSpacing) {
                            ForEach(section.items) { item in
                                PosterCardView(item: item, style: .poster, spoilerSettings: spoilerSettings) {
                                    onSelect(item)
                                }
                            }
                        }
                        .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
                        // Give focus room so the lifted card isn't clipped.
                        .padding(.vertical, metrics.sectionTitleSpacing)
                        .focusSection()
                    }
                }
            }
            .padding(.vertical, PlozzTheme.Metrics.screenVerticalPadding)
        }
        // Never clip a focused card's lift, shadow or border.
        .scrollClipDisabled()
    }
}

#endif
