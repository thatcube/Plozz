#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI
import FeatureHome
import FeatureMusic
import FeaturePlayback
import FeatureSearch
import FeatureSettings
import RatingsService
import TraktService

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
    let trakt: TraktService
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
                scrobbler: trakt.scrobbler,
                pendingPlayItemID: $pendingPlayItemID
            )
            .tabItem { Label("Home", systemImage: "house.fill") }

            SearchTab(
                accounts: accounts,
                captionSettings: captionModel.settings,
                spoilerSettings: spoilerModel.settings,
                showDiagnostics: diagnosticsModel.settings.isEnabled,
                themePalette: resolvedPalette,
                ratingsProvider: ratingsProvider,
                scrobbler: trakt.scrobbler
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
                trakt: trakt,
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
    let scrobbler: any TraktScrobbling
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
                    onSelectChild: { navigate($0) }
                )
            }
        }
        .fullScreenCover(item: $playRequest) { request in
            PlayerView(
                viewModel: PlayerViewModel(
                    provider: resolveProvider(request.item.sourceAccountID, in: accounts),
                    itemID: request.item.id,
                    captionSettings: captionSettings,
                    startPosition: request.startPosition,
                    scrobbler: scrobbler
                ),
                showDiagnostics: showDiagnostics,
                themePalette: themePalette
            )
        }
        .resumePrompt(item: $resumePrompt) { item, startPosition in
            playRequest = PlayRequest(item: item, startPosition: startPosition)
        }
        .task(id: pendingPlayItemID) { await handleDeepLink() }
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

    /// Pushes a detail page for any item — movies and episodes get a Movie/Episode
    /// Details page (with a Play button) before playback; series/seasons get their
    /// children list. Immediate playback is reserved for Continue Watching and
    /// the detail page's own Play action.
    private func navigate(_ item: MediaItem) {
        path.append(item)
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
    let scrobbler: any TraktScrobbling

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
                    onSelectChild: { open($0) }
                )
            }
        }
        .fullScreenCover(item: $playRequest) { request in
            PlayerView(
                viewModel: PlayerViewModel(
                    provider: resolveProvider(request.item.sourceAccountID, in: accounts),
                    itemID: request.item.id,
                    captionSettings: captionSettings,
                    startPosition: request.startPosition,
                    scrobbler: scrobbler
                ),
                showDiagnostics: showDiagnostics,
                themePalette: themePalette
            )
        }
        .resumePrompt(item: $resumePrompt) { item, startPosition in
            playRequest = PlayRequest(item: item, startPosition: startPosition)
        }
    }

    /// Playable leaves go straight to the player (in-progress ones prompt
    /// Resume vs Start Over); containers push a detail page.
    private func open(_ item: MediaItem) {
        switch item.kind {
        case .movie, .episode, .video:
            requestPlay(item)
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
