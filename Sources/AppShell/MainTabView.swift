#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI
import FeatureHome
import FeatureMusic
import FeaturePlayback
import FeatureSearch
import FeatureSettings
import ProviderTrailers
import RatingsService

/// The signed-in experience: Home, Search and Settings tabs, with item-detail
/// navigation and full-screen playback.
///
/// Home and Search are **unified across every active account/provider** via the
/// aggregation seam (`[ResolvedAccount]`). Each merged item/library is tagged
/// with its owning account so a tapped result routes to the correct provider.
/// Settings exposes account management, the customizable Home-libraries
/// checklist, and caption/spoiler/theme settings.
struct MainTabView: View {
    let accounts: [ResolvedAccount]
    let captionModel: CaptionSettingsModel
    let spoilerModel: SpoilerSettingsModel
    let themeModel: ThemeSettingsModel
    let diagnosticsModel: DiagnosticsSettingsModel
    let homeVisibility: HomeLibraryVisibilityModel
    let ratingsProvider: any ExternalRatingsProviding
    let mediaItemActionHandler: any MediaItemActionHandling
    let displayAccounts: [Account]
    let activeAccountID: String?
    let profiles: [Profile]
    let activeProfile: Profile
    @Binding var pendingPlayItemID: String?
    let onAddAccount: () -> Void
    let onRemoveAccount: (Account) -> Void
    let onSignOutAll: () -> Void
    let onSwitchProfile: () -> Void

    @State private var discovery = LibraryDiscoveryModel()
    @State private var audioController = AudioPlaybackController()
    @State private var musicAvailability = MusicAvailabilityModel()
    @Environment(\.colorScheme) private var systemColorScheme

    private var resolvedPalette: ThemePalette {
        ThemePalette.palette(for: themeModel.theme, systemColorScheme: systemColorScheme)
    }

    var body: some View {
        TabView {
            HomeTab(
                accounts: accounts,
                homeVisibility: homeVisibility,
                captionSettings: captionModel.settings,
                spoilerSettings: spoilerModel.settings,
                showDiagnostics: diagnosticsModel.settings.isEnabled,
                themePalette: resolvedPalette,
                ratingsProvider: ratingsProvider,
                pendingPlayItemID: $pendingPlayItemID
            )
            .tabItem { Label("Home", systemImage: "house.fill") }

            SearchTab(
                accounts: accounts,
                captionSettings: captionModel.settings,
                spoilerSettings: spoilerModel.settings,
                showDiagnostics: diagnosticsModel.settings.isEnabled,
                themePalette: resolvedPalette,
                ratingsProvider: ratingsProvider
            )
            .tabItem { Label("Search", systemImage: "magnifyingglass") }

            // Conditional Music tab: present only when at least one signed-in
            // account exposes a music library. Video-only users see no tab and no
            // mini-player — the app is byte-for-byte unchanged for them.
            if musicAvailability.hasMusic {
                MusicTabView(
                    accounts: musicAvailability.detectedAccounts,
                    controller: audioController
                )
                .tabItem { Label("Music", systemImage: "music.note") }
            }

            SettingsView(
                captions: captionModel,
                spoilers: spoilerModel,
                theme: themeModel,
                diagnostics: diagnosticsModel,
                homeVisibility: homeVisibility,
                discoveredLibraries: discovery.state,
                reloadLibraries: { await discovery.load(from: accounts) },
                accounts: displayAccounts,
                activeAccountID: activeAccountID,
                profiles: profiles,
                activeProfile: activeProfile,
                appVersion: AppInfo.version,
                appBuild: AppInfo.build,
                repoURL: AppInfo.repoURLString,
                onAddAccount: onAddAccount,
                onRemoveAccount: onRemoveAccount,
                onSignOutAll: onSignOutAll,
                onSwitchProfile: onSwitchProfile
            )
            .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
        .task(id: accounts.map(\.account.id)) {
            await musicAvailability.probe(accounts: accounts)
        }
        .mediaItemActionHandler(mediaItemActionHandler)
    }
}

/// Resolves the provider that owns `accountID`, falling back to the primary
/// (first) account for untagged items. `accounts` is guaranteed non-empty by the
/// caller (`RootView`).
private func resolveProvider(_ accountID: String?, in accounts: [ResolvedAccount]) -> any MediaProvider {
    if let accountID, let match = accounts.first(where: { $0.account.id == accountID }) {
        return match.provider
    }
    return accounts[0].provider
}

/// Builds the player for a play request. Online (TMDb → YouTube) trailers carry a
/// YouTube video-id marker and have no backing account, so they are routed to
/// ``YouTubeTrailerProvider`` (which extracts a playable stream); every other
/// item resolves through its owning account provider as usual.
@MainActor
private func makePlayerViewModel(
    for request: PlayRequest,
    accounts: [ResolvedAccount],
    captionSettings: CaptionSettings
) -> PlayerViewModel {
    if let videoID = request.item.youTubeTrailerVideoID {
        return PlayerViewModel(
            provider: YouTubeTrailerProvider(item: request.item, videoID: videoID),
            itemID: videoID,
            captionSettings: captionSettings,
            startPosition: request.startPosition,
            engineFactory: HybridPlayback.engineFactory()
        )
    }
    return PlayerViewModel(
        provider: resolveProvider(request.item.sourceAccountID, in: accounts),
        itemID: request.item.id,
        mediaSourceID: request.item.selectedVersionID,
        captionSettings: captionSettings,
        startPosition: request.startPosition,
        engineFactory: HybridPlayback.engineFactory()
    )
}

/// Home tab with its own navigation stack: Home → Library (paged) → Detail and
/// full-screen player presentation. Every destination resolves its provider from
/// the tapped item/library's `sourceAccountID`.
private struct HomeTab: View {
    let accounts: [ResolvedAccount]
    let homeVisibility: HomeLibraryVisibilityModel
    let captionSettings: CaptionSettings
    let spoilerSettings: SpoilerSettings
    let showDiagnostics: Bool
    let themePalette: ThemePalette
    let ratingsProvider: any ExternalRatingsProviding
    @Binding var pendingPlayItemID: String?

    @State private var path = NavigationPath()
    @State private var playRequest: PlayRequest?
    @State private var resumePrompt: MediaItem?

    var body: some View {
        NavigationStack(path: $path) {
            HomeView(
                viewModel: HomeViewModel(accounts: accounts),
                visibility: homeVisibility,
                spoilerSettings: spoilerSettings,
                onSelectItem: { navigate($0) },
                onPlayItem: { requestPlay($0) },
                onSelectLibrary: { library in
                    path.append(library)
                }
            )
            .navigationDestination(for: MediaLibrary.self) { library in
                LibraryBrowseView(
                    viewModel: LibraryBrowseViewModel(
                        provider: resolveProvider(library.sourceAccountID, in: accounts),
                        containerID: library.id,
                        containerKind: library.kind,
                        sourceAccountID: library.sourceAccountID
                    ),
                    title: library.title,
                    spoilerSettings: spoilerSettings,
                    onSelect: { navigate($0) }
                )
            }
            .navigationDestination(for: MediaItem.self) { item in
                ItemDetailView(
                    viewModel: ItemDetailViewModel(
                        provider: resolveProvider(item.sourceAccountID, in: accounts),
                        itemID: item.id,
                        ratingsProvider: ratingsProvider,
                        sourceAccountID: item.sourceAccountID
                    ),
                    spoilerSettings: spoilerSettings,
                    onPlay: { requestPlay($0) },
                    onSelectChild: { navigate($0) },
                    initialSeasonID: item.seasonID
                )
            }
            .navigationDestination(for: EpisodeContextRoute.self) { route in
                ItemDetailView(
                    viewModel: ItemDetailViewModel(
                        provider: resolveProvider(route.sourceAccountID, in: accounts),
                        itemID: route.seriesID,
                        ratingsProvider: ratingsProvider,
                        sourceAccountID: route.sourceAccountID
                    ),
                    spoilerSettings: spoilerSettings,
                    onPlay: { requestPlay($0) },
                    onSelectChild: { navigate($0) },
                    initialEpisode: route.episode
                )
            }
            .navigationDestination(for: SeasonContextRoute.self) { route in
                ItemDetailView(
                    viewModel: ItemDetailViewModel(
                        provider: resolveProvider(route.sourceAccountID, in: accounts),
                        itemID: route.seriesID,
                        ratingsProvider: ratingsProvider,
                        sourceAccountID: route.sourceAccountID
                    ),
                    spoilerSettings: spoilerSettings,
                    onPlay: { requestPlay($0) },
                    onSelectChild: { navigate($0) },
                    initialSeasonID: route.season.id
                )
            }
        }
        .fullScreenCover(item: $playRequest) { request in
            PlayerView(
                viewModel: makePlayerViewModel(
                    for: request,
                    accounts: accounts,
                    captionSettings: captionSettings
                ),
                showDiagnostics: showDiagnostics,
                themePalette: themePalette
            )
        }
        .resumePrompt(item: $resumePrompt) { item, startPosition in
            playRequest = PlayRequest(item: item, startPosition: startPosition)
        }
        .task(id: pendingPlayItemID) { await handleDeepLink() }
        .mediaItemNavigator { navigate($0) }
    }

    /// Resolves a deep-linked item id (from a Top Shelf card) and routes to it,
    /// then clears the request so it fires exactly once. Because the id alone is
    /// provider-ambiguous once content is merged, each active provider is tried
    /// until one resolves the item; the resolved item is tagged with its source.
    private func handleDeepLink() async {
        guard let id = pendingPlayItemID else { return }
        pendingPlayItemID = nil
        for resolved in accounts {
            if let item = try? await resolved.provider.item(id: id) {
                requestPlay(item.taggingSource(resolved.account.id))
                return
            }
        }
    }

    /// Pushes a detail page for any item — movies get a Movie Details page (with a
    /// Play button); series/seasons get their children list. A tapped episode is
    /// redirected to its *series* page (fronting that episode) so the user never
    /// lands on a dead-end single-episode page. Immediate playback is reserved for
    /// Continue Watching and the detail page's own Play action.
    private func navigate(_ item: MediaItem) {
        if item.kind == .episode, item.seriesID != nil {
            path.append(EpisodeContextRoute(episode: item))
        } else if item.kind == .season, item.seriesID != nil {
            path.append(SeasonContextRoute(season: item))
        } else {
            path.append(item)
        }
    }

    /// In-progress items prompt "Resume vs Start Over"; fully-unwatched items
    /// play immediately from the start.
    private func requestPlay(_ item: MediaItem) {
        if let resume = item.resumePosition, resume > 1 {
            resumePrompt = item
        } else {
            playRequest = PlayRequest(item: item, startPosition: 0)
        }
    }
}

/// A fully-resolved request to present the player for an item at an explicit
/// start position (seconds). `startPosition` of `0` means "start over".
private struct PlayRequest: Identifiable, Equatable {
    let item: MediaItem
    let startPosition: TimeInterval
    var id: String { item.id }
}

/// A navigation value for opening a *series* page focused on one of its
/// episodes. Tapping a lone episode (e.g. from "Recently Added") routes through
/// this instead of pushing the episode itself, so the user always lands on the
/// rich series/season page — with the tapped episode fronted in the hero, its
/// season selected, the episode row pre-scrolled to it, and Play focused at the
/// top — rather than a dead-end single-episode page.
private struct EpisodeContextRoute: Hashable {
    let episode: MediaItem
    /// The owning series' id (falls back to the episode id only if unset, which
    /// shouldn't happen for an episode that carries a `seriesID`).
    var seriesID: String { episode.seriesID ?? episode.id }
    var sourceAccountID: String? { episode.sourceAccountID }
}

/// A navigation value for opening a *series* page focused on a specific season.
/// Tapping a season item (e.g. from "Recently Added") routes through this instead
/// of pushing the season itself, so the user always lands on the rich series page —
/// with the tapped season selected, and the "next up" episode for that season
/// fronted in the hero.
private struct SeasonContextRoute: Hashable {
    let season: MediaItem
    /// The owning series' id.
    var seriesID: String { season.seriesID ?? season.id }
    var sourceAccountID: String? { season.sourceAccountID }
}

private extension View {
    /// Presents a "Resume vs Start Over" choice for an in-progress `item`.
    /// `onChoose` receives the chosen start position in seconds (the saved
    /// resume point for Resume, `0` for Start Over).
    func resumePrompt(
        item: Binding<MediaItem?>,
        onChoose: @escaping (MediaItem, TimeInterval) -> Void
    ) -> some View {
        confirmationDialog(
            item.wrappedValue?.title ?? "",
            isPresented: Binding(
                get: { item.wrappedValue != nil },
                set: { if !$0 { item.wrappedValue = nil } }
            ),
            titleVisibility: .visible,
            presenting: item.wrappedValue
        ) { presented in
            // Resume is listed first so it receives default focus.
            Button("Resume from \(PlaybackTimecode.string(from: presented.resumePosition ?? 0))") {
                onChoose(presented, presented.resumePosition ?? 0)
            }
            Button("Start Over") {
                onChoose(presented, 0)
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

/// Search tab with its own navigation stack: Search → Detail and full-screen
/// player presentation, mirroring `HomeTab`'s wiring. Search is aggregated
/// across every active account; results route to their owning provider.
private struct SearchTab: View {
    let accounts: [ResolvedAccount]
    let captionSettings: CaptionSettings
    let spoilerSettings: SpoilerSettings
    let showDiagnostics: Bool
    let themePalette: ThemePalette
    let ratingsProvider: any ExternalRatingsProviding

    @State private var path = NavigationPath()
    @State private var playRequest: PlayRequest?
    @State private var resumePrompt: MediaItem?

    var body: some View {
        NavigationStack(path: $path) {
            SearchView(
                viewModel: SearchViewModel(accounts: accounts),
                spoilerSettings: spoilerSettings,
                onSelect: { open($0) }
            )
            .navigationDestination(for: MediaItem.self) { item in
                ItemDetailView(
                    viewModel: ItemDetailViewModel(
                        provider: resolveProvider(item.sourceAccountID, in: accounts),
                        itemID: item.id,
                        ratingsProvider: ratingsProvider,
                        sourceAccountID: item.sourceAccountID
                    ),
                    spoilerSettings: spoilerSettings,
                    onPlay: { requestPlay($0) },
                    onSelectChild: { open($0) },
                    initialSeasonID: item.seasonID
                )
            }
            .navigationDestination(for: EpisodeContextRoute.self) { route in
                ItemDetailView(
                    viewModel: ItemDetailViewModel(
                        provider: resolveProvider(route.sourceAccountID, in: accounts),
                        itemID: route.seriesID,
                        ratingsProvider: ratingsProvider,
                        sourceAccountID: route.sourceAccountID
                    ),
                    spoilerSettings: spoilerSettings,
                    onPlay: { requestPlay($0) },
                    onSelectChild: { open($0) },
                    initialEpisode: route.episode
                )
            }
            .navigationDestination(for: SeasonContextRoute.self) { route in
                ItemDetailView(
                    viewModel: ItemDetailViewModel(
                        provider: resolveProvider(route.sourceAccountID, in: accounts),
                        itemID: route.seriesID,
                        ratingsProvider: ratingsProvider,
                        sourceAccountID: route.sourceAccountID
                    ),
                    spoilerSettings: spoilerSettings,
                    onPlay: { requestPlay($0) },
                    onSelectChild: { open($0) },
                    initialSeasonID: route.season.id
                )
            }
        }
        .mediaItemNavigator { item in
            if item.kind == .episode, item.seriesID != nil {
                path.append(EpisodeContextRoute(episode: item))
            } else if item.kind == .season, item.seriesID != nil {
                path.append(SeasonContextRoute(season: item))
            } else {
                path.append(item)
            }
        }
        .fullScreenCover(item: $playRequest) { request in
            PlayerView(
                viewModel: makePlayerViewModel(
                    for: request,
                    accounts: accounts,
                    captionSettings: captionSettings
                ),
                showDiagnostics: showDiagnostics,
                themePalette: themePalette
            )
        }
        .resumePrompt(item: $resumePrompt) { item, startPosition in
            playRequest = PlayRequest(item: item, startPosition: startPosition)
        }
    }

    /// Selecting a search result always opens its detail page rather than
    /// playing immediately; episodes/seasons route through their series context
    /// so the detail page has the surrounding show, mirroring `mediaItemNavigator`.
    private func open(_ item: MediaItem) {
        switch item.kind {
        case .episode where item.seriesID != nil:
            path.append(EpisodeContextRoute(episode: item))
        case .season where item.seriesID != nil:
            path.append(SeasonContextRoute(season: item))
        default:
            path.append(item)
        }
    }

    /// In-progress items prompt "Resume vs Start Over"; fully-unwatched items
    /// play immediately from the start.
    private func requestPlay(_ item: MediaItem) {
        if let resume = item.resumePosition, resume > 1 {
            resumePrompt = item
        } else {
            playRequest = PlayRequest(item: item, startPosition: 0)
        }
    }
}

#endif
