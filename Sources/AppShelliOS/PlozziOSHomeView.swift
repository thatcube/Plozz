#if os(iOS)
import CoreModels
import CoreUI
import FeatureHomeCore
import SwiftUI

struct PlozziOSHomeView: View {
    @State private var viewModel: HomeViewModel
    @State private var featuredItems: [MediaItem] = []
    @State private var heroItems: [MediaItem] = []
    private let appModel: PlozziOSAppModel
    private let onAddServer: () -> Void
    private let onShowSettings: () -> Void

    init(
        appModel: PlozziOSAppModel,
        onAddServer: @escaping () -> Void,
        onShowSettings: @escaping () -> Void
    ) {
        self.appModel = appModel
        self.onAddServer = onAddServer
        self.onShowSettings = onShowSettings
        _viewModel = State(
            initialValue: HomeViewModel(
                accounts: appModel.accountsProviders.homeAccounts,
                contentStore: HomeContentStore(
                    namespace: appModel.profiles.activeNamespace
                ),
                identitySources: appModel.identityIndex.identitySourcesProvider,
                currentVisibility: { [weak appModel] in
                    appModel?.settings.homeVisibility.visibility ?? .default
                },
                pendingWatchMutations: { [weak appModel] in
                    await appModel?.pendingWatchMutations() ?? []
                },
                recentlyAppliedRecency: { [weak appModel] in
                    await appModel?.appliedWatchRecency() ?? [:]
                }
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
                    NavigationLink("Add Network Share") {
                        PlozziOSAddShareView(appModel: appModel)
                    }
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
            ToolbarItem(placement: .topBarTrailing) {
                Button(
                    "Settings",
                    systemImage: "gear",
                    action: onShowSettings
                )
            }
        }
        .task(id: appModel.settings.homeVisibility.visibility) {
            await viewModel.loadIfNeeded(
                for: appModel.settings.homeVisibility.visibility
            )
        }
        .task(
            id: FeaturedLoadID(
                isConfigured: appModel.seerService.isConfigured,
                settings: appModel.settings.hero.settings
            )
        ) {
            await loadFeatured()
        }
        .onReceive(NotificationCenter.default.publisher(for: .mediaItemDidMutate)) { note in
            if let mutation = MediaItemMutation.from(note) {
                viewModel.applyWatchedState(mutation)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .identityIndexDidUpdate)) { _ in
            viewModel.scheduleReenrich()
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
                if !heroItems.isEmpty {
                    PlozziOSHomeHeroCarousel(
                        items: heroItems,
                        autoAdvance: appModel.settings.hero.settings.autoAdvance,
                        autoAdvanceSeconds:
                            appModel.settings.hero.settings.autoAdvanceSeconds
                    )
                }

                if !featuredItems.isEmpty {
                    PlozziOSFeaturedRow(
                        items: featuredItems,
                        appModel: appModel
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
            await loadFeatured()
        }
        .task(
            id: PlozziOSHeroLoadID(
                content: content,
                settings: appModel.settings.hero.settings,
                featuredItems: featuredItems,
                visibility: appModel.settings.homeVisibility.visibility
            )
        ) {
            await loadHero(from: content)
        }
    }

    private func loadFeatured() async {
        let hero = appModel.settings.hero.settings
        guard hero.isEnabled,
              appModel.seerService.isConfigured,
              hero.sources.contains(.featured) else {
            featuredItems = []
            return
        }
        let trending = (try? await appModel.seerService.trending(limit: hero.maxItems)) ?? []
        guard !Task.isCancelled else { return }
        featuredItems = trending.filter(\.isNotInLibraryDiscovery)
    }

    private func loadHero(from content: HomeViewModel.Content) async {
        let settings = appModel.settings.hero.settings
        guard settings.isActive else {
            heroItems = []
            return
        }

        let randomLibraries = HeroRandomLibrarySelection.resolve(
            content.libraries,
            settings: settings,
            isVisible: appModel.settings.homeVisibility.isVisibleOnHome
        )
        let providers = Dictionary(
            uniqueKeysWithValues: appModel.accountsProviders.resolvedActiveAccounts.map {
                ($0.account.id, $0.provider)
            }
        )
        let randomProvider: RandomLibraryContentProviding = { libraries, limit in
            await HeroRandomLibraryLoader.load(
                libraries: libraries,
                limit: limit
            ) { library, requestLimit in
                guard let provider = providers[library.accountID],
                      let page = try? await provider.items(
                          in: library.libraryID,
                          kind: library.kind,
                          page: PageRequest(
                              startIndex: 0,
                              limit: requestLimit,
                              sort: CoreModels.SortDescriptor(
                                  field: .random,
                                  direction: .descending
                              )
                          )
                      ) else {
                    return []
                }
                return page.items.map {
                    $0.taggingSource(library.accountID)
                        .taggingLibrary(library.libraryID)
                }
            }
        }
        let featured = featuredItems
        let pendingMutations = await viewModel.pendingHeroWatchMutations()
        let curated = await HeroCurator().curate(
            settings: settings,
            continueWatching: content.continueWatching,
            watchlist: content.watchlist,
            randomLibraries: randomLibraries,
            watchMutations: pendingMutations,
            featuredProvider: { limit in
                Array(featured.prefix(limit))
            },
            randomProvider: randomProvider
        )
        guard !Task.isCancelled else { return }
        heroItems = curated
    }
}

private struct FeaturedLoadID: Equatable {
    let isConfigured: Bool
    let settings: HeroSettings
}

private struct PlozziOSHeroLoadID: Equatable {
    let content: HomeViewModel.Content
    let settings: HeroSettings
    let featuredItems: [MediaItem]
    let visibility: HomeLibraryVisibility
}

private struct PlozziOSHomeHeroCarousel: View {
    @State private var selectedItemID: String?

    let items: [MediaItem]
    let autoAdvance: Bool
    let autoAdvanceSeconds: Int

    var body: some View {
        TabView(selection: $selectedItemID) {
            ForEach(items) { item in
                PlozziOSHomeHero(
                    item: item,
                    provider: provider(for: item)
                )
                .tag(Optional(item.id))
            }
        }
        .tabViewStyle(
            .page(indexDisplayMode: items.count > 1 ? .automatic : .never)
        )
        .aspectRatio(16 / 8.5, contentMode: .fit)
        .padding(.horizontal)
        .onChange(of: items.map(\.id), initial: true) { _, itemIDs in
            if selectedItemID == nil || !itemIDs.contains(selectedItemID ?? "") {
                selectedItemID = itemIDs.first
            }
        }
        .task(
            id: PlozziOSHeroTimerID(
                itemIDs: items.map(\.id),
                autoAdvance: autoAdvance,
                seconds: autoAdvanceSeconds
            )
        ) {
            guard autoAdvance, items.count > 1 else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(autoAdvanceSeconds))
                } catch {
                    return
                }
                withAnimation(.easeInOut(duration: 0.35)) {
                    let currentIndex = items.firstIndex {
                        $0.id == selectedItemID
                    } ?? -1
                    selectedItemID = items[(currentIndex + 1) % items.count].id
                }
            }
        }
    }

    @Environment(PlozziOSAppModel.self) private var appModel

    private func provider(for item: MediaItem) -> (any MediaProvider)? {
        if let accountID = item.sourceAccountID {
            return appModel.accountsProviders.provider(forAccountID: accountID)
        }
        return appModel.accountsProviders.primaryProvider
    }
}

private struct PlozziOSHeroTimerID: Equatable {
    let itemIDs: [String]
    let autoAdvance: Bool
    let seconds: Int
}

private struct PlozziOSHomeHero: View {
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
                    hero
                }

                .buttonStyle(.plain)
            } else {
                hero
            }
        }
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

private struct PlozziOSFeaturedRow: View {
    @Environment(\.plozzCardStyle) private var cardStyle
    @Environment(\.plozzMetrics) private var metrics
    let items: [MediaItem]
    let appModel: PlozziOSAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Trending")
                .font(.title2.bold())
                .padding(.horizontal)

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(items) { item in
                        PlozziOSHomeMediaCard(
                            item: item,
                            isLandscape: false,
                            provider: appModel.accountsProviders.primaryProvider
                        )
                        .frame(
                            width: metrics.cardSlotWidth(
                                for: .poster,
                                cardStyle: cardStyle
                            )
                        )
                    }
                }
                .padding(.horizontal)
            }
            .scrollIndicators(.hidden)
        }
    }
}

private struct PlozziOSHomeRowView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.plozzCardStyle) private var cardStyle
    @Environment(\.plozzMetrics) private var metrics
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
                        provider: provider(for: item)
                    )
                    .frame(width: mediaCardWidth)
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
                            PlozziOSHomeLibraryCard(
                                library: library,
                                width: appModel.settings.density.density
                                    .iOSHomeLibraryWidth(
                                        horizontalSizeClass: horizontalSizeClass
                                    )
                            )
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

    private var mediaCardWidth: CGFloat {
        metrics.cardSlotWidth(
            for: row.style == .landscape ? .landscape : .poster,
            cardStyle: cardStyle
        )
    }
}

private struct PlozziOSHomeMediaCard: View {
    @Environment(PlozziOSAppModel.self) private var appModel
    let item: MediaItem
    let isLandscape: Bool
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

    @ViewBuilder
    private var card: some View {
        PlozziOSPosterCard(
            item: item,
            style: isLandscape ? .landscape : .poster
        )
    }
}

private struct PlozziOSHomeLibraryCard: View {
    @Environment(\.plozzCardStyle) private var cardStyle
    @Environment(\.plozzMetrics) private var metrics
    let library: AggregatedLibrary
    let width: CGFloat

    @ViewBuilder
    var body: some View {
        if cardStyle == .framed {
            content
                .plozzFramedMediaCard(
                    innerCornerRadius: PlozzTheme.Metrics.mediumMediaCornerRadius
                )
                .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
        } else {
            content
        }
    }

    private var content: some View {
        VStack(
            alignment: .leading,
            spacing: metrics.landscapeCaptionTopSpacing
        ) {
            AsyncImage(url: library.library.imageURL) { image in
                image
                    .resizable()
                    .scaledToFill()
            } placeholder: {
                RoundedRectangle(
                    cornerRadius: PlozzTheme.Metrics.mediumMediaCornerRadius
                )
                    .fill(.secondary.opacity(0.14))
                    .overlay {
                        Image(systemName: library.library.kind == .series ? "tv" : "film")
                            .font(.title)
                            .foregroundStyle(.secondary)
                    }
            }
            .frame(width: width, height: width * 0.6)
            .clipShape(
                RoundedRectangle(
                    cornerRadius: PlozzTheme.Metrics.mediumMediaCornerRadius,
                    style: .continuous
                )
            )
            .plozzMediaEdge(
                cornerRadius: PlozzTheme.Metrics.mediumMediaCornerRadius
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(library.library.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(library.serverName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, metrics.landscapeCaptionInset)
            .padding(
                .bottom,
                cardStyle == .framed ? metrics.landscapeCaptionInset : 0
            )
        }
        .frame(width: width, alignment: .leading)
    }
}
#endif
