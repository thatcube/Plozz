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
    @State private var isRequestingHero = false
    @State private var heroRequestStatuses: [String: MediaAvailabilityStatus] = [:]
    @State private var heroPullDistance: CGFloat = 0
    /// When each optimistic override was set. An override may shield the CTA from
    /// an untracked (`.unknown`) poll only briefly — long enough to bridge the gap
    /// until Seerr commits a freshly-created request — after which the authoritative
    /// per-title lookup wins, so a request that actually failed can never stay
    /// stuck on "Requested" forever.
    @State private var heroRequestStatusSetAt: [String: Date] = [:]
    @State private var heroRequestConfirmItem: MediaItem?
    @State private var heroRequestError: String?
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
                    Label(
                        "Unable to load Home",
                        systemImage: "exclamationmark.triangle"
                    )
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
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            if trailerController.isPlaying {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: toggleTrailerMute) {
                        Image(
                            systemName: trailerController.isMuted
                                ? "speaker.slash.fill"
                                : "speaker.wave.2.fill"
                        )
                    }
                    .accessibilityLabel(
                        trailerController.isMuted
                            ? "Unmute trailer"
                            : "Mute trailer"
                    )
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                PlozziOSSettingsAvatarButton(size: 36, action: onShowSettings)
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
        .task(
            id: FeaturedLoadID(
                isConfigured: appModel.seerService.isConfigured,
                settings: appModel.settings.hero.settings
            )
        ) {
            await refreshFeaturedStatusLoop()
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
        .confirmationDialog(
            "Request as Administrator?",
            isPresented: Binding(
                get: { heroRequestConfirmItem != nil },
                set: { if !$0 { heroRequestConfirmItem = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Request as Administrator") {
                guard let item = heroRequestConfirmItem else { return }
                heroRequestConfirmItem = nil
                Task { await requestFromHero(item) }
            }
            Button("Cancel", role: .cancel) { heroRequestConfirmItem = nil }
        } message: {
            Text(
                "This profile isn’t linked to a Seerr user. "
                    + "The request will use the unrestricted administrator account."
            )
        }
        .alert(
            "Request Failed",
            isPresented: Binding(
                get: { heroRequestError != nil },
                set: { if !$0 { heroRequestError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(heroRequestError ?? "")
        }
    }

    private func toggleTrailerMute() {
        // Session-only override — never rewrites the saved mute default.
        trailerController.toggleMuted()
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
                        onPlay: play,
                        isRequesting: isRequestingHero,
                        requestStatus: { heroRequestStatuses[$0.id] },
                        onRequest: beginHeroRequest,
                        pullDistance: heroPullDistance
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
            geometry.contentOffset.y > trailerPauseThreshold
        } action: { _, isPastHalfHero in
            trailerController.setPaused(isPastHalfHero)
        }
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            let topOffset = geometry.contentOffset.y
                + geometry.contentInsets.top
            return max(0, -topOffset)
        } action: { _, pullDistance in
            heroPullDistance = pullDistance
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

    /// Fast cadence while a title is requested but not yet downloading — the
    /// window where the user is waiting to see it *start* — so "Downloading"
    /// appears within a few seconds of the grab actually beginning.
    private static let featuredRefreshFast: Duration = .seconds(4)
    /// Relaxed cadence once every in-flight title is already downloading (its %
    /// only needs coarse updates) or nothing is transitional, to avoid hammering
    /// Seerr with per-title TMDB lookups indefinitely.
    private static let featuredRefreshSlow: Duration = .seconds(20)

    /// Periodically re-fetches featured (Seerr) status and folds each fresh
    /// title's `availability` + `downloadProgress` back onto the matching hero
    /// item **in place**, so the request CTA tracks the server live
    /// (Request → "NN%" → Play) as a download progresses — mirroring tvOS. Only
    /// the two status fields change; item ids and carousel order are untouched,
    /// so the current slide, backdrop, and paging never reset. Polls fast while a
    /// request is still spinning up, then backs off.
    private func refreshFeaturedStatusLoop() async {
        while !Task.isCancelled {
            await refreshFeaturedStatusOnce()
            if Task.isCancelled { return }
            try? await Task.sleep(for: nextFeaturedRefreshDelay())
        }
    }

    /// Fast delay while any hero title is requested/approved but not yet
    /// downloading; relaxed once everything in-flight is downloading or idle.
    private func nextFeaturedRefreshDelay() -> Duration {
        // An outstanding optimistic override means we just requested and are
        // waiting for Seerr to confirm — poll fast until it does.
        if !heroRequestStatuses.isEmpty { return Self.featuredRefreshFast }
        let transitional = heroItems.contains { item in
            guard let availability = item.availability else { return false }
            switch availability {
            case .pending:
                return true
            case .processing:
                return item.downloadProgress == nil
            case .available, .partiallyAvailable, .unknown, .deleted:
                return false
            }
        }
        return transitional ? Self.featuredRefreshFast : Self.featuredRefreshSlow
    }

    /// One status-refresh pass. Re-fetches each in-flight hero title's live
    /// availability + download progress by TMDB lookup (`availability(for:)`),
    /// which — unlike `trending` — keeps reporting a title after it's been
    /// requested and left the trending list, so the CTA doesn't get stuck on
    /// "Requested" while it's actually downloading.
    private func refreshFeaturedStatusOnce() async {
        let hero = appModel.settings.hero.settings
        guard hero.isActive,
              hero.sources.contains(.featured),
              appModel.seerService.isConfigured else {
            return
        }
        let inFlight = heroItems.filter { $0.availability != nil }
        guard !inFlight.isEmpty else { return }

        var statusByID: [String: (MediaAvailabilityStatus?, Double?)] = [:]
        for item in inFlight {
            if let status = await appModel.seerService.availability(for: item) {
                statusByID[item.id] = (status.0, status.1)
            }
        }
        if Task.isCancelled || statusByID.isEmpty { return }
        foldFeaturedStatus(statusByID, into: &heroItems)
        foldFeaturedStatus(statusByID, into: &featuredItems)
    }

    private func foldFeaturedStatus(
        _ statusByID: [String: (MediaAvailabilityStatus?, Double?)],
        into items: inout [MediaItem]
    ) {
        for index in items.indices {
            let id = items[index].id
            guard let status = statusByID[id] else { continue }
            // Don't let a stale/untracked lookup downgrade an optimistic
            // post-request state *immediately* after a request: for a beat, Seerr
            // can still report `.unknown` before it commits the new request row,
            // which would flap the CTA back to "Request". But this shield is
            // time-boxed — once the grace window lapses, the authoritative lookup
            // wins, so a request that genuinely failed can't stay stuck on
            // "Requested" forever.
            if heroRequestStatuses[id] != nil, !Self.isTracked(status.0) {
                let setAt = heroRequestStatusSetAt[id] ?? .distantPast
                if Date().timeIntervalSince(setAt) < Self.heroRequestOverrideGrace {
                    continue
                }
            }
            guard items[index].availability != status.0
                || items[index].downloadProgress != status.1 else {
                // Even when nothing changed, an authoritative tracked/untracked
                // lookup means the override has served its purpose — drop it so it
                // can't linger and shield a later real change.
                heroRequestStatuses[id] = nil
                heroRequestStatusSetAt[id] = nil
                continue
            }
            items[index].availability = status.0
            items[index].downloadProgress = status.1
            heroRequestStatuses[id] = nil
            heroRequestStatusSetAt[id] = nil
        }
    }

    /// How long an optimistic hero-request override may shield the CTA from an
    /// untracked (`.unknown`) poll before the authoritative lookup takes over.
    private static let heroRequestOverrideGrace: TimeInterval = 25

    /// Whether a Seerr availability represents a real, tracked request state
    /// (as opposed to "not tracked"), so it may supersede an optimistic override.
    private static func isTracked(_ status: MediaAvailabilityStatus?) -> Bool {
        switch status {
        case .pending, .processing, .available, .partiallyAvailable:
            return true
        case .unknown, .deleted, nil:
            return false
        }
    }

    private func play(_ item: MediaItem) {
        trailerController.stop()
        playbackRequest = PlozziOSPlaybackRequest(
            item: item,
            startPosition: item.resumePosition ?? 0
        )
    }

    /// One-tap Seerr request from the Home hero, mirroring the detail hero. When
    /// the active profile isn't linked to a Seerr user (and there are multiple
    /// profiles), confirm the admin-account fallback first.
    private func beginHeroRequest(_ item: MediaItem) {
        if appModel.activeSeerrUserID == nil,
           appModel.profiles.profiles.count > 1 {
            heroRequestConfirmItem = item
        } else {
            Task { await requestFromHero(item) }
        }
    }

    private func requestFromHero(_ item: MediaItem) async {
        guard appModel.seerService.isConfigured else {
            heroRequestError = "Connect Overseerr or Jellyseerr in Settings first."
            return
        }
        isRequestingHero = true
        heroRequestError = nil
        defer { isRequestingHero = false }
        let outcome = await appModel.seerService.request(
            item,
            seasons: nil,
            actingUserID: appModel.activeSeerrUserID
        )
        switch outcome {
        case let .success(status):
            heroRequestStatuses[item.id] = status
            heroRequestStatusSetAt[item.id] = Date()
            await refreshFeaturedStatusOnce()
        case .failure(.alreadyRequested):
            // Seerr already tracks this title with a live (pending/approved)
            // request — reflect that as "Requested" immediately, shielded only
            // briefly (see `heroRequestOverrideGrace`) before the authoritative
            // lookup takes over.
            heroRequestStatuses[item.id] = .pending
            heroRequestStatusSetAt[item.id] = Date()
            await refreshFeaturedStatusOnce()
        case let .failure(reason):
            heroRequestError = reason.userMessage
        }
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
    @State private var transitionDirection: CGFloat = 0
    @State private var transitionInProgress = false
    @State private var foregroundVisible = true
    /// Latest hero stage width. A full-width finger drag maps to exactly one
    /// complete transition.
    @State private var stageWidth: CGFloat = 1

    let items: [MediaItem]
    let autoAdvance: Bool
    let autoAdvanceSeconds: Int
    let onPlay: (MediaItem) -> Void
    var isRequesting: Bool = false
    var requestStatus: (MediaItem) -> MediaAvailabilityStatus? = { _ in nil }
    var onRequest: ((MediaItem) -> Void)?
    var pullDistance: CGFloat = 0

    var body: some View {
        let style: HeroArtworkStyle = horizontalSizeClass == .compact
            ? .compactPortrait
            : .landscape
        let heroHeight = PlozziOSHeroMetrics.height(
            style: style,
            surfaceRole: .home,
            dynamicTypeSize: dynamicTypeSize
        )
        let pullScale = 1 + (pullDistance / max(heroHeight, 1))
        let upwardScaleGrowth = (pullScale - 1) * heroHeight / 2
        let pullOffset = max(pullDistance - upwardScaleGrowth, 0)
        GeometryReader { proxy in
            let swipeDistance = max(proxy.size.width, 1)
            let progress = min(abs(dragOffset) / swipeDistance, 1)
            // Parallax slide: the outgoing image drifts up to `slideTravel` in the
            // drag direction (partly off-screen, subtle), while the incoming image
            // enters from the opposite edge and settles into place by the same
            // amount — both tracking the finger via `progress`, in either direction.
            let slideTravel = proxy.size.width * 0.35
            let slideDir: CGFloat = dragOffset == 0
                ? transitionDirection
                : (dragOffset < 0 ? -1 : 1)
            let outgoingX = slideDir * slideTravel * progress
            let incomingX = -slideDir * slideTravel * (1 - progress)
            ZStack {
                if let currentItem {
                    // Images + legibility scrim live in ONE container that carries a
                    // single static dissolve mask, so the fade never shifts during a
                    // swipe (only the image/video underneath crossfades), and the
                    // whole thing melts to the page via ALPHA — the tvOS look — with
                    // no opaque grey wash. The current slide stays fully opaque while
                    // the incoming one fades in on top, so the stack never dips.
                    ZStack {
                        if let dragTargetItem {
                            // TRANSITION: both slides render through the SAME
                            // reflected-stage backdrop as idle. Transition artwork
                            // includes clipped mirrored edge panels beside the sharp
                            // center, so only an exposed edge reveals the reflection;
                            // there is no full blurred duplicate beneath the image.
                            PlozziOSHomeStaticBackdrop(
                                item: dragTargetItem,
                                style: style,
                                height: heroHeight,
                                contentOffsetX: incomingX,
                                showsTrailer: false,
                                usesSlidingArtwork: true,
                                ancestorScale: pullScale
                            )

                            PlozziOSHomeStaticBackdrop(
                                item: currentItem,
                                style: style,
                                height: heroHeight,
                                contentOffsetX: outgoingX,
                                showsTrailer: false,
                                usesSlidingArtwork: true,
                                ancestorScale: pullScale
                            )
                            .opacity(1 - progress)
                        } else {
                            // IDLE: the full backdrop (reflected stage + trailer).
                            PlozziOSHomeStaticBackdrop(
                                item: currentItem,
                                style: style,
                                height: heroHeight,
                                ancestorScale: pullScale
                            )
                            .id(currentItem.id)
                        }

                        PlozziOSStationaryHeroScrim(
                            style: style,
                            height: heroHeight
                        )
                    }
                    .mask { PlozziOSHeroFadeMask() }
                    .scaleEffect(pullScale, anchor: .center)
                    .offset(y: -pullOffset)

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
                        onPlay: onPlay,
                        heroRequest: heroRequest(for: currentItem)
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
                    onEnded: { translation, velocity in
                        finishDrag(
                            translation: translation,
                            velocity: velocity
                        )
                    }
                )
            )
            .onChange(of: proxy.size.width, initial: true) { _, width in
                stageWidth = max(width, 1)
            }
        }
        .frame(height: heroHeight)
        .overlay(alignment: .bottom) {
            if items.count > 1 {
                PlozziOSHeroPagingIndicator(
                    itemIDs: items.map(\.id),
                    // During a committed transition the dot animates to the target
                    // over the same window as the image slide (transitionTargetID is
                    // set outside the disable-animations transaction, unlike
                    // selectedItemID which snaps at the end). Falls back to the
                    // selected id when idle.
                    selectedItemID: transitionTargetID ?? selectedItemID,
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

    /// Request CTA descriptor for a discovery **movie** hero (one-tap request,
    /// like the detail hero). `nil` for in-library items or non-movie discovery,
    /// so those keep the normal Play / More Info actions.
    private func heroRequest(for item: MediaItem) -> PlozziOSHeroRequest? {
        guard let onRequest,
              item.isNotInLibraryDiscovery,
              item.kind == .movie else {
            return nil
        }
        let availability = requestStatus(item) ?? item.availability
        return PlozziOSHeroRequest(
            cta: MediaItem.heroCTA(
                availability: availability,
                downloadProgress: item.downloadProgress,
                seerConnected: appModel.seerService.isConfigured
            ),
            isRequesting: isRequesting,
            actingName: appModel.activeSeerrUserName,
            onRequest: onRequest
        )
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

    private func finishDrag(translation: CGSize, velocity: CGSize) {
        let projectedWidth = translation.width + (velocity.width * 0.15)
        let shouldCommit = abs(translation.width) >= stageWidth * 0.18
            || abs(projectedWidth) >= stageWidth * 0.28
        guard abs(translation.width) > abs(translation.height) * 1.2,
              shouldCommit else {
            withAnimation(.easeOut(duration: 0.2)) {
                dragOffset = 0
            }
            return
        }
        beginTransition(
            forward: translation.width < 0,
            releaseVelocity: velocity.width
        )
    }

    private func beginTransition(
        forward: Bool,
        releaseVelocity: CGFloat? = nil
    ) {
        guard !transitionInProgress,
              let target = adjacentItem(forward: forward) else {
            return
        }
        transitionInProgress = true
        transitionDirection = forward ? -1 : 1
        transitionTargetID = target.id
        let distance = max(stageWidth, 1)
        let currentProgress = min(abs(dragOffset) / distance, 1)
        let remainingProgress = max(1 - currentProgress, 0)
        let animation: Animation
        if let releaseVelocity {
            let velocityProgressPerSecond = abs(releaseVelocity) / distance
            let completionRate = max(velocityProgressPerSecond, 2.8)
            let duration = min(
                0.34,
                max(0.01, remainingProgress / completionRate)
            )
            animation = .easeOut(duration: duration)
        } else {
            animation = .easeInOut(duration: 0.34)
        }
        // Commit the swap on the animation's COMPLETION (not a fixed Task.sleep,
        // which raced the animation and produced a snap when it fired a hair
        // early/late). At completion the incoming image is exactly at rest, so the
        // hard swap to the idle backdrop is seamless — one fluid motion.
        withAnimation(animation) {
            dragOffset = forward ? -distance : distance
        } completion: {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                selectedItemID = target.id
                transitionTargetID = nil
                transitionDirection = 0
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

private struct PlozziOSHorizontalHeroDragGesture:
    UIGestureRecognizerRepresentable {
    let isEnabled: Bool
    let onChanged: (CGSize) -> Void
    let onEnded: (CGSize, CGSize) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func makeUIGestureRecognizer(
        context: Context
    ) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.delegate = context.coordinator
        recognizer.cancelsTouchesInView = false
        recognizer.allowedScrollTypesMask = .continuous
        return recognizer
    }

    func updateUIGestureRecognizer(
        _ recognizer: UIPanGestureRecognizer,
        context: Context
    ) {
        recognizer.isEnabled = isEnabled
    }

    func handleUIGestureRecognizerAction(
        _ recognizer: UIPanGestureRecognizer,
        context: Context
    ) {
        let point = recognizer.translation(in: recognizer.view)
        let translation = CGSize(width: point.x, height: point.y)
        let velocityPoint = recognizer.velocity(in: recognizer.view)
        let velocity = CGSize(width: velocityPoint.x, height: velocityPoint.y)
        switch recognizer.state {
        case .began, .changed:
            onChanged(translation)
        case .ended:
            onEnded(translation, velocity)
        case .cancelled, .failed:
            onEnded(.zero, .zero)
        default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private static let horizontalDominance: CGFloat = 1.35

        func gestureRecognizerShouldBegin(
            _ gestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else {
                return true
            }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x)
                > abs(velocity.y) * Self.horizontalDominance
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer:
                UIGestureRecognizer
        ) -> Bool {
            true
        }
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
