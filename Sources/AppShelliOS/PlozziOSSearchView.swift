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
                                    .adaptive(minimum: 116, maximum: 190),
                                    spacing: 12
                                )
                            ],
                            spacing: 18
                        ) {
                            ForEach(section.items) { item in
                                PlozziOSSearchResultCard(
                                    item: item,
                                    provider: provider(for: item)
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
        VStack(alignment: .leading, spacing: 7) {
            AsyncImage(url: item.posterURL) { image in
                image
                    .resizable()
                    .scaledToFill()
            } placeholder: {
                Rectangle()
                    .fill(.secondary.opacity(0.14))
                    .overlay {
                        Image(systemName: item.kind == .series ? "tv" : "film")
                            .foregroundStyle(.secondary)
                    }
            }
            .aspectRatio(2 / 3, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            Text(item.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)

            if let cue = SearchSection.availabilityCue(for: item) {
                Text(cue)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tint)
            }
        }
    }
}
#endif
