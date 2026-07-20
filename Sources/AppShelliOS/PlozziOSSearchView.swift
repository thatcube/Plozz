#if os(iOS)
import CoreModels
import FeatureSearchCore
import SwiftUI

struct PlozziOSSearchView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var viewModel: SearchViewModel
    private let appModel: PlozziOSAppModel
    private let onShowSettings: () -> Void

    init(
        appModel: PlozziOSAppModel,
        onShowSettings: @escaping () -> Void
    ) {
        self.appModel = appModel
        self.onShowSettings = onShowSettings
        _viewModel = State(
            initialValue: SearchViewModel(
                accounts: appModel.accountsProviders.homeAccounts,
                identitySources: appModel.identityIndex.identitySourcesProvider,
                disabledLibraryKeys: { [weak appModel] in
                    appModel?.settings.homeVisibility.visibility.disabledKeys
                        ?? []
                },
                seerSearch: { [seer = appModel.seerService] query in
                    (try? await seer.search(query)) ?? []
                },
                seerRequestAvailability: { [seer = appModel.seerService] item in
                    await seer.requestAvailability(for: item)
                }
            )
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            PlozziOSSearchHeader(
                query: $viewModel.query,
                onShowSettings: onShowSettings
            )
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Compact tabs do not need a second bar above the explicit Search header.
        // Regular-width iPad keeps the bar so the system sidebar toggle remains
        // reachable when the adaptable tab sidebar is collapsed.
        .toolbar(
            horizontalSizeClass == .compact ? .hidden : .visible,
            for: .navigationBar
        )
        .navigationTitle(horizontalSizeClass == .compact ? "" : "Search")
        .navigationBarTitleDisplayMode(.inline)
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
        .onReceive(NotificationCenter.default.publisher(for: .identityIndexDidUpdate)) { _ in
            guard !viewModel.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return
            }
            Task { await viewModel.search() }
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
                            columns: appModel.settings.density.density.iOSPosterGridColumns(
                                horizontalSizeClass: horizontalSizeClass
                            ),
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

/// Explicit top header: a touch-friendly search field that takes all available
/// width with the active-profile settings avatar immediately to its right.
private struct PlozziOSSearchHeader: View {
    @Binding var query: String
    let onShowSettings: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(
                    "Movies, shows, and episodes",
                    text: $query
                )
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .accessibilityLabel("Search your libraries")
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(.thinMaterial, in: Capsule())
            .frame(maxWidth: .infinity)

            PlozziOSSettingsAvatarButton(action: onShowSettings)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }
}

private struct PlozziOSSearchResultCard: View {
    @Environment(PlozziOSAppModel.self) private var appModel
    let item: MediaItem
    let provider: (any MediaProvider)?

    var body: some View {
        Group {
            if let provider {
                NavigationLink {
                    PlozziOSItemDetailView(
                        appModel: appModel,
                        provider: provider,
                        item: item,
                        seerService: appModel.seerService
                    )
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
                item: item
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
