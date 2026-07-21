#if os(iOS)
import AppRuntime
import CoreModels
import CoreUI
import FeatureHomeCore
import SwiftUI
import UIKit

struct PlozziOSHomeView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(HeroTrailerController.self) private var trailerController
    @State private var viewModel: HomeViewModel
    @State private var featuredItems: [MediaItem] = []
    @State private var heroItems: [MediaItem] = []
    @State private var playbackRequest: PlozziOSPlaybackRequest?
    @State private var heroControlsVisible = true
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
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            if heroControlsVisible {
                if #available(iOS 26.0, *) {
                    ToolbarItem(placement: .topBarTrailing) {
                        PlozziOSHomeHeroControls(
                            showsMute: trailerController.isPlaying,
                            isMuted: appModel.settings.heroBackground.settings
                                .trailerMuted,
                            onToggleMute: {
                                appModel.settings.heroBackground.settings
                                    .trailerMuted.toggle()
                                trailerController.setMuted(
                                    appModel.settings.heroBackground.settings
                                        .trailerMuted
                                )
                            },
                            onShowSettings: onShowSettings
                        )
                    }
                    .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .topBarTrailing) {
                        PlozziOSHomeHeroControls(
                            showsMute: trailerController.isPlaying,
                            isMuted: appModel.settings.heroBackground.settings
                                .trailerMuted,
                            onToggleMute: {
                                appModel.settings.heroBackground.settings
                                    .trailerMuted.toggle()
                                trailerController.setMuted(
                                    appModel.settings.heroBackground.settings
                                        .trailerMuted
                                )
                            },
                            onShowSettings: onShowSettings
                        )
                    }
                }
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
        .fullScreenCover(item: $playbackRequest) { request in
            if let provider = appModel.provider(for: request.item) {
                PlozziOSPlayerView(request: request, provider: provider)
            } else {
                ContentUnavailableView(
                    "Server unavailable",
                    systemImage: "server.rack"
                )
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
        let heroStyle: HeroArtworkStyle = horizontalSizeClass == .compact
            ? .compactPortrait
            : .landscape
        let trailerPauseThreshold = PlozziOSHeroMetrics.height(
            style: heroStyle,
            surfaceRole: .home,
            dynamicTypeSize: dynamicTypeSize
        ) / 2
        let scroll = ScrollView {
            LazyVStack(alignment: .leading, spacing: 30) {
                if !heroItems.isEmpty {
                    PlozziOSHomeHeroCarousel(
                        items: heroItems,
                        autoAdvance: appModel.settings.hero.settings.autoAdvance,
                        autoAdvanceSeconds:
                            appModel.settings.hero.settings.autoAdvanceSeconds,
                        onPlay: play
                    )
                }

                if !featuredItems.isEmpty {
                    PlozziOSFeaturedRow(
                        items: featuredItems,
                        appModel: appModel
                    )
                }

                if content.mergeLibraries {
                    ForEach(rows) { row in
                        PlozziOSHomeRowView(
                            row: row,
                            appModel: appModel
                        )
                    }
                } else {
                    ForEach(rows.filter { $0.kind != .libraries }) { row in
                        PlozziOSHomeRowView(
                            row: row,
                            appModel: appModel
                        )
                    }
                    ForEach(content.librarySections) { group in
                        ForEach(group.sections) { section in
                            PlozziOSHomeMediaRail(
                                title: section.title,
                                items: section.items,
                                style: section.style == .landscape
                                    ? .landscape
                                    : .poster,
                                appModel: appModel
                            )
                        }
                    }
                    if let libraries = rows.first(where: {
                        $0.kind == .libraries
                    }) {
                        PlozziOSHomeRowView(
                            row: libraries,
                            appModel: appModel
                        )
                    }
                }
            }
            .padding(.bottom)
        }
        return Group {
            if heroItems.isEmpty {
                scroll
            } else {
                scroll.ignoresSafeArea(.container, edges: .top)
            }
        }
        .scrollClipDisabled()
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y > 72
        } action: { _, scrolledPastHeroControls in
            withAnimation(.easeOut(duration: 0.18)) {
                heroControlsVisible = !scrolledPastHeroControls
            }
        }
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y > trailerPauseThreshold
        } action: { _, isPastHalfHero in
            trailerController.setPaused(isPastHalfHero)
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

    private func play(_ item: MediaItem) {
        trailerController.stop()
        playbackRequest = PlozziOSPlaybackRequest(
            item: item,
            startPosition: item.resumePosition ?? 0
        )
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
    let continueWatching: [MediaItem]
    let watchlist: [MediaItem]
    let libraries: [AggregatedLibrary]
    let settings: HeroSettings
    let featuredItems: [MediaItem]
    let visibility: HomeLibraryVisibility

    init(
        content: HomeViewModel.Content,
        settings: HeroSettings,
        featuredItems: [MediaItem],
        visibility: HomeLibraryVisibility
    ) {
        // Hero curation never reads latest or per-library section rows. Keeping
        // those large arrays out of task identity avoids deep comparisons and
        // needless curation restarts when unrelated Home rows refresh.
        continueWatching = content.continueWatching
        watchlist = content.watchlist
        libraries = content.libraries
        self.settings = settings
        self.featuredItems = featuredItems
        self.visibility = visibility
    }
}

private struct PlozziOSHomeHeroCarousel: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(HeroTrailerController.self) private var trailerController
    @State private var selectedItemID: String?
    @State private var dwellStart = Date()
    @State private var dragOffset: CGFloat = 0
    @State private var rootItems: [String: MediaItem] = [:]
    @State private var playTargets: [String: MediaItem] = [:]
    @State private var transitionTargetID: String?
    @State private var transitionInProgress = false
    @State private var foregroundVisible = true

    let items: [MediaItem]
    let autoAdvance: Bool
    let autoAdvanceSeconds: Int
    let onPlay: (MediaItem) -> Void

    var body: some View {
        let style: HeroArtworkStyle = horizontalSizeClass == .compact
            ? .compactPortrait
            : .landscape
        let heroHeight = PlozziOSHeroMetrics.height(
            style: style,
            surfaceRole: .home,
            dynamicTypeSize: dynamicTypeSize
        )
        GeometryReader { proxy in
            let progress = min(
                abs(dragOffset) / max(proxy.size.width * 0.45, 1),
                1
            )
            ZStack {
                if let currentItem {
                    PlozziOSHomeStaticBackdrop(
                        item: currentItem,
                        style: style,
                        height: heroHeight
                    )
                    .id(currentItem.id)
                    .opacity(1 - progress)

                    if let dragTargetItem {
                        PlozziOSHomeStaticBackdrop(
                            item: dragTargetItem,
                            style: style,
                            height: heroHeight
                        )
                        .opacity(progress)
                    }

                    PlozziOSStationaryHeroScrim(
                        style: style,
                        height: heroHeight
                    )

                    PlozziOSHomeHeroSlide(
                        item: currentItem,
                        isSelected: true
                    )

                    let rootItem = rootItem(for: currentItem)
                    let playItem = playTarget(for: currentItem) ?? currentItem
                    PlozziOSHomeHeroForeground(
                        item: playItem,
                        detailItem: currentItem,
                        watchlistItem: rootItem,
                        presentation: HeroPresentation(
                            item: rootItem,
                            artworkStyle: style,
                            surface: .home
                        ),
                        style: style,
                        provider: provider(for: currentItem),
                        onPlay: onPlay
                    )
                    .id(currentItem.id)
                    .transition(.opacity)
                    .opacity(
                        (1 - progress)
                            * (foregroundVisible ? 1 : 0)
                    )
                    .frame(
                        maxWidth: PlozziOSPageLayout.heroTextMaxWidth(
                            for: style
                        )
                    )
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: style == .compactPortrait
                            ? .bottom
                            : .bottomLeading
                    )
                    .padding(
                        .horizontal,
                        PlozziOSPageLayout.horizontalInset(for: style)
                    )
                    .padding(.bottom, style == .compactPortrait ? 30 : 42)
                    .animation(
                        .easeInOut(duration: 0.24),
                        value: currentItem.id
                    )

                }
            }
            .contentShape(Rectangle())
            .gesture(
                PlozziOSHorizontalHeroDragGesture(
                    isEnabled: !transitionInProgress,
                    onChanged: { translation in
                        dragOffset = translation.width
                    },
                    onEnded: { translation in
                        finishDrag(translation: translation)
                    }
                )
            )
        }
        .frame(height: heroHeight)
        .overlay(alignment: .bottom) {
            if items.count > 1 {
                PlozziOSHeroPagingIndicator(
                    itemIDs: items.map(\.id),
                    selectedItemID: selectedItemID,
                    autoAdvance: autoAdvance,
                    autoAdvanceSeconds: autoAdvanceSeconds,
                    dwellStart: dwellStart,
                    trailerController: trailerController
                )
                .padding(.horizontal, 20)
                .offset(y: 10)
            }
        }
        .onChange(of: items.map(\.id), initial: true) { _, itemIDs in
            if selectedItemID == nil || !itemIDs.contains(selectedItemID ?? "") {
                selectedItemID = itemIDs.first
                dwellStart = .now
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
            var elapsed = 0
            var countdownItemID = selectedItemID
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
                if countdownItemID != selectedItemID {
                    countdownItemID = selectedItemID
                    elapsed = 0
                }
                if let selectedItemID,
                   trailerController.isShowing(selectedItemID) {
                    continue
                }
                elapsed += 1
                if elapsed >= autoAdvanceSeconds {
                    page(forward: true)
                    countdownItemID = selectedItemID
                    elapsed = 0
                }
            }
        }
        .onChange(of: selectedItemID, initial: true) {
            dwellStart = .now
            installTrailerEndHandler()
        }
        .task(id: selectedItemID) {
            guard let currentItem else { return }
            async let root: Void = resolveRootItem(for: currentItem)
            async let play: Void = resolvePlayTarget(for: currentItem)
            async let art: Void = warmAdjacentArtwork()
            _ = await (root, play, art)
        }
        .onAppear(perform: installTrailerEndHandler)
        .onDisappear {
            trailerController.clearEndHandler(ownerID: endHandlerOwnerID)
        }
    }

    @Environment(PlozziOSAppModel.self) private var appModel

    private var currentItem: MediaItem? {
        guard let selectedItemID else { return items.first }
        return items.first { $0.id == selectedItemID } ?? items.first
    }

    private var dragTargetItem: MediaItem? {
        if let transitionTargetID {
            return items.first { $0.id == transitionTargetID }
        }
        guard dragOffset != 0, items.count > 1 else { return nil }
        return adjacentItem(forward: dragOffset < 0)
    }

    private func provider(for item: MediaItem) -> (any MediaProvider)? {
        if let accountID = item.sourceAccountID {
            return appModel.accountsProviders.provider(forAccountID: accountID)
        }
        return appModel.accountsProviders.primaryProvider
    }

    private func rootItem(for item: MediaItem) -> MediaItem {
        rootItems[item.id] ?? item
    }

    private func playTarget(for item: MediaItem) -> MediaItem? {
        if let resolved = playTargets[item.id] {
            return resolved
        }
        switch item.kind {
        case .movie, .episode, .video:
            let target = bestLibraryItem(for: item)
            return target.hasPlayableLibraryTarget() ? target : nil
        default:
            return nil
        }
    }

    private func resolveRootItem(for item: MediaItem) async {
        guard rootItems[item.id] == nil else { return }
        let target = bestLibraryItem(for: item)
        guard let provider = provider(for: target) else {
            rootItems[item.id] = item
            return
        }
        var hydrated = (try? await provider.item(id: target.id)) ?? target
        if hydrated.sourceAccountID == nil,
           let sourceAccountID = target.sourceAccountID {
            hydrated = hydrated.taggingSource(sourceAccountID)
        }
        let metadataID: String
        if (hydrated.kind == .episode || hydrated.kind == .season),
           let seriesID = hydrated.seriesID {
            metadataID = seriesID
        } else {
            metadataID = hydrated.id
        }

        do {
            var root = try await provider.item(id: metadataID)
            guard !Task.isCancelled else { return }
            if root.sourceAccountID == nil,
               let sourceAccountID = target.sourceAccountID {
                root = root.taggingSource(sourceAccountID)
            }
            rootItems[item.id] = root
        } catch {
            guard !Task.isCancelled else { return }
            rootItems[item.id] = item
        }
    }

    private func resolvePlayTarget(for item: MediaItem) async {
        guard playTargets[item.id] == nil else {
            return
        }
        let selected = bestLibraryItem(for: item)
        guard let provider = provider(for: selected) else { return }
        var hydrated = (try? await provider.item(id: selected.id)) ?? selected
        if hydrated.sourceAccountID == nil,
           let sourceAccountID = selected.sourceAccountID {
            hydrated = hydrated.taggingSource(sourceAccountID)
        }
        guard var target = await HeroPlayTargetResolver.resolve(
            item: hydrated,
            provider: provider
        ) else {
            return
        }
        guard !Task.isCancelled else { return }
        if target.sourceAccountID == nil,
           let sourceAccountID = selected.sourceAccountID {
            target = target.taggingSource(sourceAccountID)
        }
        playTargets[item.id] = target
    }

    private func bestLibraryItem(for item: MediaItem) -> MediaItem {
        PlaybackSourceSelection.bestPlayItem(
            item,
            accounts: appModel.accountsProviders.resolvedActiveAccounts,
            identitySources: appModel.identityIndex.identitySourcesProvider
        )
    }

    private var endHandlerOwnerID: String { "ios-home-carousel" }

    private func installTrailerEndHandler() {
        guard autoAdvance, items.count > 1 else {
            trailerController.clearEndHandler(ownerID: endHandlerOwnerID)
            return
        }
        trailerController.setEndHandler(ownerID: endHandlerOwnerID) {
            page(forward: true)
        }
    }

    private func page(forward: Bool) {
        beginTransition(forward: forward)
    }

    private func adjacentItem(forward: Bool) -> MediaItem? {
        guard items.count > 1 else { return nil }
        let currentIndex = items.firstIndex {
            $0.id == selectedItemID
        } ?? 0
        let targetIndex = forward
            ? (currentIndex + 1) % items.count
            : (currentIndex - 1 + items.count) % items.count
        return items[targetIndex]
    }

    private func finishDrag(translation: CGSize) {
        guard abs(translation.width) > abs(translation.height) * 1.2,
              abs(translation.width) >= 50 else {
            withAnimation(.easeOut(duration: 0.2)) {
                dragOffset = 0
            }
            return
        }
        beginTransition(forward: translation.width < 0)
    }

    private func beginTransition(forward: Bool) {
        guard !transitionInProgress,
              let target = adjacentItem(forward: forward) else {
            return
        }
        transitionInProgress = true
        transitionTargetID = target.id
        withAnimation(.easeInOut(duration: 0.28)) {
            dragOffset = forward ? -1_000 : 1_000
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(280))
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                selectedItemID = target.id
                transitionTargetID = nil
                dragOffset = 0
                foregroundVisible = false
            }
            withAnimation(.easeInOut(duration: 0.24)) {
                foregroundVisible = true
            }
            transitionInProgress = false
        }
    }

    private func warmAdjacentArtwork() async {
        let targets = [currentItem, adjacentItem(forward: true),
                       adjacentItem(forward: false)]
            .compactMap { $0 }
        for target in targets {
            let style: HeroArtworkStyle = horizontalSizeClass == .compact
                ? .compactPortrait
                : .landscape
            let references = HeroPresentation(
                item: target,
                artworkStyle: style,
                surface: .home
            ).artworkReferences
            for reference in references {
                guard !Task.isCancelled else { return }
                if await ArtworkImageCache.shared.image(
                    for: reference,
                    variant: .heroBackdrop,
                    background: true
                ) != nil {
                    break
                }
            }
        }
    }
}

private struct PlozziOSHomeHeroControls: View {
    let showsMute: Bool
    let isMuted: Bool
    let onToggleMute: () -> Void
    let onShowSettings: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if showsMute {
                PlozziOSHomeHeroMuteButton(
                    isMuted: isMuted,
                    action: onToggleMute
                )
                .modifier(PlozziOSCircularHeroControlModifier())
            }
            PlozziOSSettingsAvatarButton(action: onShowSettings)
                .modifier(PlozziOSCircularHeroControlModifier())
        }
        .fixedSize()
        .offset(y: -1)
    }
}

private struct PlozziOSCircularHeroControlModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .frame(width: 44, height: 44)
                .contentShape(Circle())
                .glassEffect(.regular.interactive(), in: Circle())
        } else {
            content
                .frame(width: 44, height: 44)
                .contentShape(Circle())
                .background(.ultraThinMaterial, in: Circle())
                .overlay {
                    Circle()
                        .stroke(.white.opacity(0.14), lineWidth: 1)
                }
        }
    }
}

private struct PlozziOSHomeHeroMuteButton: View {
    let isMuted: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(
                systemName: isMuted
                    ? "speaker.slash.fill"
                    : "speaker.wave.2.fill"
            )
            .font(.subheadline.weight(.semibold))
            .frame(width: 44, height: 44)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .buttonBorderShape(.circle)
        .accessibilityLabel(isMuted ? "Unmute trailer" : "Mute trailer")
    }
}

private struct PlozziOSHorizontalHeroDragGesture:
    UIGestureRecognizerRepresentable {
    let isEnabled: Bool
    let onChanged: (CGSize) -> Void
    let onEnded: (CGSize) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func makeUIGestureRecognizer(
        context: Context
    ) -> PlozziOSHorizontalHeroPanGestureRecognizer {
        let recognizer = PlozziOSHorizontalHeroPanGestureRecognizer()
        recognizer.delegate = context.coordinator
        recognizer.cancelsTouchesInView = false
        return recognizer
    }

    func updateUIGestureRecognizer(
        _ recognizer: PlozziOSHorizontalHeroPanGestureRecognizer,
        context: Context
    ) {
        recognizer.isEnabled = isEnabled
    }

    func handleUIGestureRecognizerAction(
        _ recognizer: PlozziOSHorizontalHeroPanGestureRecognizer,
        context: Context
    ) {
        switch recognizer.state {
        case .began, .changed:
            onChanged(recognizer.translation)
        case .ended:
            onEnded(recognizer.translation)
        case .cancelled, .failed:
            onEnded(.zero)
        default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer:
                UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}

private final class PlozziOSHorizontalHeroPanGestureRecognizer:
    UIGestureRecognizer {
    private static let minimumDistance: CGFloat = 12
    private static let horizontalDominance: CGFloat = 1.35

    private var initialLocation: CGPoint?
    private(set) var translation: CGSize = .zero

    override func touchesBegan(
        _ touches: Set<UITouch>,
        with event: UIEvent
    ) {
        guard touches.count == 1, let touch = touches.first else {
            state = .failed
            return
        }
        initialLocation = touch.location(in: view)
        translation = .zero
    }

    override func touchesMoved(
        _ touches: Set<UITouch>,
        with event: UIEvent
    ) {
        guard let initialLocation, let touch = touches.first else {
            state = .failed
            return
        }
        let location = touch.location(in: view)
        translation = CGSize(
            width: location.x - initialLocation.x,
            height: location.y - initialLocation.y
        )

        if state == .possible {
            let horizontalDistance = abs(translation.width)
            let verticalDistance = abs(translation.height)
            guard hypot(horizontalDistance, verticalDistance)
                >= Self.minimumDistance else {
                return
            }
            guard horizontalDistance
                > verticalDistance * Self.horizontalDominance else {
                state = .failed
                return
            }
            state = .began
        } else if state == .began || state == .changed {
            state = .changed
        }
    }

    override func touchesEnded(
        _ touches: Set<UITouch>,
        with event: UIEvent
    ) {
        if state == .began || state == .changed {
            state = .ended
        } else {
            state = .failed
        }
    }

    override func touchesCancelled(
        _ touches: Set<UITouch>,
        with event: UIEvent
    ) {
        state = .cancelled
    }

    override func reset() {
        initialLocation = nil
        translation = .zero
        super.reset()
    }
}

private struct PlozziOSHeroTimerID: Equatable {
    let itemIDs: [String]
    let autoAdvance: Bool
    let seconds: Int
}

private struct PlozziOSFeaturedRow: View {
    @Environment(\.plozzCardStyle) private var cardStyle
    @Environment(\.plozzMetrics) private var metrics
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let items: [MediaItem]
    let appModel: PlozziOSAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Trending")
                .font(.title2.bold())
                .padding(
                    .horizontal,
                    PlozziOSPageLayout.horizontalInset(for: horizontalSizeClass)
                )

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
            }
            .contentMargins(
                .horizontal,
                PlozziOSPageLayout.horizontalInset(for: horizontalSizeClass),
                for: .scrollContent
            )
            .scrollIndicators(.hidden)
        }
    }
}

private struct PlozziOSHomeRowView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let row: HomeRow
    let appModel: PlozziOSAppModel

    var body: some View {
        Group {
            if row.kind == .libraries {
                VStack(alignment: .leading, spacing: 12) {
                    Text(row.title)
                        .font(.title2.bold())
                        .padding(
                            .horizontal,
                            PlozziOSPageLayout.horizontalInset(
                                for: horizontalSizeClass
                            )
                        )
                    libraryRow
                }
            } else {
                PlozziOSHomeMediaRail(
                    title: row.title,
                    items: row.items,
                    style: row.style == .landscape ? .landscape : .poster,
                    appModel: appModel
                )
            }
        }
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
        }
        .contentMargins(
            .horizontal,
            PlozziOSPageLayout.horizontalInset(for: horizontalSizeClass),
            for: .scrollContent
        )
        .scrollIndicators(.hidden)
    }

}

private struct PlozziOSHomeMediaRail: View {
    @Environment(\.plozzCardStyle) private var cardStyle
    @Environment(\.plozzMetrics) private var metrics
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let title: String
    let items: [MediaItem]
    let style: PosterCardView.Style
    let appModel: PlozziOSAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title2.bold())
                .padding(
                    .horizontal,
                    PlozziOSPageLayout.horizontalInset(for: horizontalSizeClass)
                )

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(items) { item in
                        PlozziOSHomeMediaCard(
                            item: item,
                            isLandscape: style == .landscape,
                            provider: provider(for: item)
                        )
                        .frame(
                            width: metrics.cardSlotWidth(
                                for: style,
                                cardStyle: cardStyle
                            )
                        )
                    }
                }
            }
            .contentMargins(
                .horizontal,
                PlozziOSPageLayout.horizontalInset(for: horizontalSizeClass),
                for: .scrollContent
            )
            .scrollIndicators(.hidden)
        }
    }

    private func provider(for item: MediaItem) -> (any MediaProvider)? {
        if let accountID = item.sourceAccountID {
            return appModel.accountsProviders.provider(forAccountID: accountID)
        }
        return appModel.accountsProviders.primaryProvider
    }
}

private struct PlozziOSHomeMediaCard: View {
    @Environment(PlozziOSAppModel.self) private var appModel
    let item: MediaItem
    let isLandscape: Bool
    let provider: (any MediaProvider)?

    var body: some View {
        let detailItem = PlaybackSourceSelection.bestPlayItem(
            item,
            accounts: appModel.accountsProviders.resolvedActiveAccounts,
            identitySources: appModel.identityIndex.identitySourcesProvider
        )
        let detailProvider = appModel.provider(for: detailItem) ?? provider
        Group {
            if let detailProvider {
                NavigationLink {
                    PlozziOSItemDetailView(
                        appModel: appModel,
                        provider: detailProvider,
                        item: detailItem,
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
