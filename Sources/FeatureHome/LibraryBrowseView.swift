#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

/// A paginated, lazily-loaded poster grid for browsing a single library.
///
/// Loads the first page through `ContentStateView` (loading/empty/error/retry),
/// then fetches further pages as cards near the end scroll into view — so large
/// libraries with hundreds of items stay responsive instead of timing out on a
/// single all-items request.
public struct LibraryBrowseView: View {
    @State private var viewModel: LibraryBrowseViewModel
    private let title: String
    private let spoilerSettings: SpoilerSettings
    private let onSelect: (MediaItem) -> Void

    public init(
        viewModel: LibraryBrowseViewModel,
        title: String,
        spoilerSettings: SpoilerSettings = .default,
        onSelect: @escaping (MediaItem) -> Void
    ) {
        _viewModel = State(initialValue: viewModel)
        self.title = title
        self.spoilerSettings = spoilerSettings
        self.onSelect = onSelect
    }

    private let columns = [
        GridItem(
            .adaptive(minimum: PlozzTheme.Metrics.posterWidth),
            spacing: PlozzTheme.Metrics.cardSpacing
        )
    ]

    public var body: some View {
        ContentStateView(
            state: viewModel.state,
            emptyMessage: "This library is empty.",
            onRetry: { Task { await viewModel.loadFirstPage() } }
        ) { items in
            ScrollView {
                LazyVGrid(columns: columns, spacing: PlozzTheme.Metrics.rowSpacing) {
                    ForEach(items) { item in
                        PosterCardView(item: item, spoilerSettings: spoilerSettings) { onSelect(item) }
                            .task { await viewModel.loadMoreIfNeeded(currentItemID: item.id) }
                    }
                }
                .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
                .padding(.vertical, 40)

                footer
            }
        }
        .navigationTitle(title)
        .task { if viewModel.state.value == nil { await viewModel.loadFirstPage() } }
    }

    @ViewBuilder
    private var footer: some View {
        if viewModel.isLoadingNextPage {
            ProgressView()
                .scaleEffect(1.3)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 40)
        } else if viewModel.pageError != nil {
            Button("Load More") { Task { await viewModel.retryNextPage() } }
                .buttonStyle(.borderedProminent)
                .padding(.bottom, 40)
        }
    }
}

#endif
