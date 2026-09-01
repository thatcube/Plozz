#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI
import FeatureHomeCore

/// A full-grid root for Plozz's universal Watchlist.
///
/// It shares Home's retained model, so opening this destination never creates a
/// second provider fetch or a second interpretation of cross-provider membership.
public struct WatchlistBrowseView: View {
    @State private var viewModel: HomeViewModel
    private let visibility: HomeLibraryVisibility
    private let spoilerSettings: SpoilerSettings
    private let onSelect: (MediaItem) -> Void

    @State private var watchlistIntentRevision = 0
    @Environment(\.mediaItemActionHandler) private var mediaItemActionHandler
    @Environment(\.plozzMetrics) private var metrics
    @Environment(\.plozzNavigationContentInset) private var navigationContentInset

    public init(
        viewModel: HomeViewModel,
        visibility: HomeLibraryVisibility,
        spoilerSettings: SpoilerSettings = .default,
        onSelect: @escaping (MediaItem) -> Void
    ) {
        _viewModel = State(initialValue: viewModel)
        self.visibility = visibility
        self.spoilerSettings = spoilerSettings
        self.onSelect = onSelect
    }

    public var body: some View {
        ContentStateView(
            state: viewModel.state,
            emptyMessage: "Your Watchlist is empty.",
            onRetry: { Task { await viewModel.load() } },
            loadingContent: {
                watchlistContent(
                    [],
                    loadingPlaceholderCount:
                        max(metrics.posterColumns.count * 2, 6)
                )
            }
        ) { content in
            watchlistContent(
                content.watchlist,
                loadingPlaceholderCount:
                    viewModel.watchlistLoadingPlaceholderCount
            )
        }
        .task(id: visibility) {
            await viewModel.loadIfNeeded(for: visibility)
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .universalWatchlistDidChange
            )
        ) { _ in
            viewModel.scheduleDurableWatchlistRefresh()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .universalWatchlistCacheDidLoad
            )
        ) { _ in
            viewModel.scheduleDurableWatchlistRefresh()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .watchlistIntentDidChange
            )
        ) { _ in
            watchlistIntentRevision &+= 1
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .mediaItemDidMutate)
        ) { note in
            if let mutation = MediaItemMutation.from(note) {
                viewModel.applyWatchedState(mutation)
            }
        }
        .onMoveCommand { _ in
            viewModel.noteHomeNavigationInteraction()
        }
        .toolbar(.hidden, for: .tabBar)
    }

    @ViewBuilder
    private func watchlistContent(
        _ items: [MediaItem],
        loadingPlaceholderCount: Int
    ) -> some View {
        if items.isEmpty, loadingPlaceholderCount == 0 {
            ContentUnavailableView {
                Label("Your Watchlist is empty", systemImage: "bookmark")
            } description: {
                Text("Add a movie or show from Plozz or any connected Watchlist.")
            }
        } else {
            ScrollView(.vertical) {
                LazyVStack(
                    alignment: .leading,
                    spacing: metrics.sectionTitleSpacing
                ) {
                    WatchlistBrowseHeader()
                        .padding(.leading, contentLeadingPadding)
                        .padding(.trailing, HomeLayout.horizontalPadding)

                    LazyVGrid(
                        columns: metrics.posterColumns,
                        spacing: metrics.gridSpacing
                    ) {
                        ForEach(items, id: \.stablePresentationID) { item in
                            PosterCardView(
                                item: item,
                                style: .poster,
                                spoilerSettings: spoilerSettings,
                                isPendingRemoval: isPendingRemoval(item)
                            ) {
                                onSelect(item)
                            }
                        }
                        if loadingPlaceholderCount > 0 {
                            ForEach(
                                0..<loadingPlaceholderCount,
                                id: \.self
                            ) { _ in
                                SkeletonCardView(style: .poster)
                            }
                        }
                    }
                    .padding(.leading, contentLeadingPadding)
                    .padding(.trailing, HomeLayout.horizontalPadding)
                    .padding(.bottom, PlozzTheme.Metrics.screenVerticalPadding)
                    .focusSection()
                }
                .padding(.top, PlozzTheme.Spacing.large)
            }
            .scrollClipDisabled()
        }
    }

    private var contentLeadingPadding: CGFloat {
        HomeLayout.horizontalPadding
            + navigationContentInset
            + (navigationContentInset > 0 ? 16 : 0)
    }

    private func isPendingRemoval(_ item: MediaItem) -> Bool {
        _ = watchlistIntentRevision
        guard let mediaItemActionHandler else { return false }
        return mediaItemActionHandler
            .isActivelyRemovingFromWatchlist(item)
    }
}

private struct WatchlistBrowseHeader: View {
    var body: some View {
        Text("Watchlist")
            .font(.largeTitle.bold())
    }
}
#endif
