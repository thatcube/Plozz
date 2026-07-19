#if os(iOS)
import CoreModels
import FeatureSearchCore
import SwiftUI

struct PlozziOSSearchView: View {
    @State private var viewModel: SearchViewModel
    private let appModel: PlozziOSAppModel

    init(appModel: PlozziOSAppModel) {
        self.appModel = appModel
        _viewModel = State(
            initialValue: SearchViewModel(accounts: appModel.accountsProviders.homeAccounts)
        )
    }

    var body: some View {
        content
            .navigationTitle("Search")
            .searchable(
                text: $viewModel.query,
                prompt: "Movies, shows, and episodes"
            )
            .task(id: viewModel.query) {
                await viewModel.search()
            }
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
            ContentUnavailableView(
                "Search your libraries",
                systemImage: "magnifyingglass",
                description: Text("Find movies, TV shows, and episodes across your servers.")
            )
        case .loading:
            ProgressView("Searching…")
        case .empty:
            ContentUnavailableView.search(text: viewModel.query)
        case let .failed(error):
            ContentUnavailableView {
                Label("Search unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error.userMessage)
            } actions: {
                Button("Try Again") {
                    Task { await viewModel.search() }
                }
            }
        case let .loaded(sections):
            results(sections)
        }
    }

    private func results(_ sections: [SearchSection]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: 12) {
                        Text(section.title)
                            .font(.title2.bold())

                        LazyVGrid(
                            columns: [
                                GridItem(
                                    .adaptive(
                                        minimum: appModel.settings.density.density.iOSPosterMinimumWidth,
                                        maximum: appModel.settings.density.density.iOSPosterMinimumWidth * 1.55
                                    ),
                                    spacing: 12
                                )
                            ],
                            spacing: 18
                        ) {
                            ForEach(section.items) { item in
                                PlozziOSSearchResultCard(
                                    item: item,
                                    provider: provider(for: item),
                                    cardStyle: appModel.settings.cardStyle.style,
                                    watchIndicator: appModel.settings.watchIndicator.indicator
                                )
                            }
                        }
                    }
                }
            }
            .padding()
        }
    }

    private func provider(for item: MediaItem) -> (any MediaProvider)? {
        if let accountID = item.sourceAccountID {
            return appModel.accountsProviders.provider(forAccountID: accountID)
        }
        return appModel.accountsProviders.primaryProvider
    }
}

private struct PlozziOSSearchResultCard: View {
    let item: MediaItem
    let provider: (any MediaProvider)?
    let cardStyle: CardStyle
    let watchIndicator: WatchStatusIndicator

    var body: some View {
        Group {
            if let provider {
                NavigationLink {
                    PlozziOSItemDetailView(provider: provider, item: item)
                } label: {
                    card
                }
                .buttonStyle(.plain)
            } else {
                card
            }
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 6) {
            PlozziOSPosterCard(
                item: item,
                cardStyle: cardStyle,
                watchIndicator: watchIndicator
            )
            if let cue = SearchSection.availabilityCue(for: item) {
                Label(cue, systemImage: "rectangle.stack.badge.plus")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tint)
            }
        }
    }
}
#endif
