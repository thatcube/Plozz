#if os(iOS)
import CoreModels
import FeatureHomeCore
import SwiftUI

struct PlozziOSHomeView: View {
    @State private var viewModel: HomeViewModel
    private let appModel: PlozziOSAppModel
    private let onAddServer: () -> Void

    init(appModel: PlozziOSAppModel, onAddServer: @escaping () -> Void) {
        self.appModel = appModel
        self.onAddServer = onAddServer
        _viewModel = State(
            initialValue: HomeViewModel(
                accounts: appModel.accountsProviders.homeAccounts,
                contentStore: HomeContentStore()
            )
        )
    }

    var body: some View {
        Group {
            switch viewModel.state {
            case .idle, .loading:
                ProgressView("Loading Home…")
            case .empty:
                ContentUnavailableView {
                    Label("Your Home is empty", systemImage: "house")
                } description: {
                    Text("Add media to your server or connect another source.")
                } actions: {
                    Button("Add Server", action: onAddServer)
                }
            case let .failed(error):
                ContentUnavailableView {
                    Label("Unable to load Home", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error.userMessage)
                } actions: {
                    Button("Try Again") {
                        Task { await viewModel.load() }
                    }
                }
            case let .loaded(content):
                loadedContent(content)
            }
        }
        .navigationTitle("Home")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add Server", systemImage: "plus", action: onAddServer)
            }
        }
        .task(id: appModel.settings.homeVisibility.visibility) {
            await viewModel.loadIfNeeded(
                for: appModel.settings.homeVisibility.visibility
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .mediaItemDidMutate)) { note in
            if let mutation = MediaItemMutation.from(note) {
                viewModel.applyWatchedState(mutation)
            }
        }
    }

    private func loadedContent(_ content: HomeViewModel.Content) -> some View {
        let visibility = appModel.settings.homeVisibility
        let rows = HomeRow.rows(
            for: content,
            isLibraryVisible: visibility.isVisibleOnHome,
            isGlobalRowEnabled: visibility.isGlobalRowEnabled
        )
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 30) {
                if appModel.settings.hero.settings.isEnabled,
                   let heroItem = content.continueWatching.first ?? content.latest.first {
                    PlozziOSHomeHero(
                        item: heroItem,
                        provider: provider(for: heroItem)
                    )
                }

                ForEach(rows) { row in
                    PlozziOSHomeRowView(
                        row: row,
                        appModel: appModel
                    )
                }
            }
            .padding(.vertical)
        }
        .refreshable {
            await viewModel.load()
        }
    }

    private func provider(for item: MediaItem) -> (any MediaProvider)? {
        if let accountID = item.sourceAccountID {
            return appModel.accountsProviders.provider(forAccountID: accountID)
        }
        return appModel.accountsProviders.primaryProvider
    }
}

private struct PlozziOSHomeHero: View {
    let item: MediaItem
    let provider: (any MediaProvider)?

    var body: some View {
        Group {
            if let provider {
                NavigationLink {
                    PlozziOSItemDetailView(provider: provider, item: item)
                } label: {
                    hero
                }
                .buttonStyle(.plain)
            } else {
                hero
            }
        }
        .padding(.horizontal)
    }

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            AsyncImage(url: item.backdropURL ?? item.posterURL) { image in
                image
                    .resizable()
                    .scaledToFill()
            } placeholder: {
                Rectangle()
                    .fill(.secondary.opacity(0.14))
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(16 / 8.5, contentMode: .fit)
            .clipped()

            LinearGradient(
                colors: [.clear, .black.opacity(0.82)],
                startPoint: .center,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 6) {
                if item.resumePosition != nil {
                    Text("CONTINUE WATCHING")
                        .font(.caption2.bold())
                        .foregroundStyle(.white.opacity(0.78))
                }
                Text(item.title)
                    .font(.title.bold())
                    .foregroundStyle(.white)
                    .lineLimit(2)
            }
            .padding()
        }
        .clipShape(RoundedRectangle(cornerRadius: 22))
    }
}

private struct PlozziOSHomeRowView: View {
    let row: HomeRow
    let appModel: PlozziOSAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(row.title)
                .font(.title2.bold())
                .padding(.horizontal)

            if row.kind == .libraries {
                libraryRow
            } else {
                mediaRow
            }
        }
    }

    private var mediaRow: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 14) {
                ForEach(row.items) { item in
                    PlozziOSHomeMediaCard(
                        item: item,
                        isLandscape: row.style == .landscape,
                        provider: provider(for: item),
                        settings: appModel.settings
                    )
                    .frame(width: row.style == .landscape ? 250 : 140)
                }
            }
            .padding(.horizontal)
        }
        .scrollIndicators(.hidden)
    }

    private var libraryRow: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 14) {
                ForEach(row.libraries) { library in
                    if let provider = appModel.accountsProviders.provider(
                        forAccountID: library.accountID
                    ) {
                        NavigationLink {
                            PlozziOSLibraryGridView(
                                viewModel: LibraryBrowseViewModel(
                                    provider: provider,
                                    containerID: library.library.id,
                                    containerKind: library.library.kind,
                                    sourceAccountID: library.accountID
                                ),
                                title: library.library.title,
                                provider: provider,
                                settings: appModel.settings
                            )
                        } label: {
                            PlozziOSHomeLibraryCard(library: library)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal)
        }
        .scrollIndicators(.hidden)
    }

    private func provider(for item: MediaItem) -> (any MediaProvider)? {
        if let accountID = item.sourceAccountID {
            return appModel.accountsProviders.provider(forAccountID: accountID)
        }
        return appModel.accountsProviders.primaryProvider
    }
}

private struct PlozziOSHomeMediaCard: View {
    let item: MediaItem
    let isLandscape: Bool
    let provider: (any MediaProvider)?
    let settings: PlozziOSSettingsModel

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

    @ViewBuilder
    private var card: some View {
        if isLandscape {
            VStack(alignment: .leading, spacing: 7) {
                AsyncImage(url: item.backdropURL ?? item.posterURL) { image in
                    image
                        .resizable()
                        .scaledToFill()
                } placeholder: {
                    Rectangle()
                        .fill(.secondary.opacity(0.14))
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12))

                Text(item.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
            }
        } else {
            PlozziOSPosterCard(
                item: item,
                cardStyle: settings.cardStyle.style,
                watchIndicator: settings.watchIndicator.indicator
            )
        }
    }
}

private struct PlozziOSHomeLibraryCard: View {
    let library: AggregatedLibrary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AsyncImage(url: library.library.imageURL) { image in
                image
                    .resizable()
                    .scaledToFill()
            } placeholder: {
                RoundedRectangle(cornerRadius: 14)
                    .fill(.secondary.opacity(0.14))
                    .overlay {
                        Image(systemName: library.library.kind == .series ? "tv" : "film")
                            .font(.title)
                            .foregroundStyle(.secondary)
                    }
            }
            .frame(width: 220, height: 132)
            .clipShape(RoundedRectangle(cornerRadius: 14))

            Text(library.library.title)
                .font(.headline)
                .lineLimit(1)
            Text(library.serverName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: 220, alignment: .leading)
    }
}
#endif
