#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI
import FeatureHome
import FeaturePlayback
import FeatureSearch
import FeatureSettings
import RatingsService

/// The signed-in experience: Home and Settings tabs, with item-detail
/// navigation and full-screen playback.
///
/// Home runs against the **primary active** provider in this branch; the
/// multi-account aggregation seam (`resolvedActiveAccounts`) is reserved for
/// branch H. Settings exposes account management (add/remove) plus caption and
/// spoiler settings.
struct MainTabView: View {
    let provider: any MediaProvider
    let captionModel: CaptionSettingsModel
    let spoilerModel: SpoilerSettingsModel
    let themeModel: ThemeSettingsModel
    let diagnosticsModel: DiagnosticsSettingsModel
    let ratingsProvider: any ExternalRatingsProviding
    let accounts: [Account]
    let activeAccountID: String?
    @Binding var pendingPlayItemID: String?
    let onAddAccount: () -> Void
    let onRemoveAccount: (Account) -> Void
    let onSignOutAll: () -> Void

    var body: some View {
        TabView {
            HomeTab(
                provider: provider,
                captionSettings: captionModel.settings,
                spoilerSettings: spoilerModel.settings,
                showDiagnostics: diagnosticsModel.settings.isEnabled,
                ratingsProvider: ratingsProvider,
                pendingPlayItemID: $pendingPlayItemID
            )
            .tabItem { Label("Home", systemImage: "house.fill") }

            SearchTab(
                provider: provider,
                captionSettings: captionModel.settings,
                spoilerSettings: spoilerModel.settings,
                showDiagnostics: diagnosticsModel.settings.isEnabled,
                ratingsProvider: ratingsProvider
            )
            .tabItem { Label("Search", systemImage: "magnifyingglass") }

            SettingsView(
                captions: captionModel,
                spoilers: spoilerModel,
                theme: themeModel,
                diagnostics: diagnosticsModel,
                accounts: accounts,
                activeAccountID: activeAccountID,
                appVersion: AppInfo.version,
                appBuild: AppInfo.build,
                repoURL: AppInfo.repoURLString,
                onAddAccount: onAddAccount,
                onRemoveAccount: onRemoveAccount,
                onSignOutAll: onSignOutAll
            )
            .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
    }
}

/// Home tab with its own navigation stack: Home → Library (paged) → Detail and
/// full-screen player presentation.
private struct HomeTab: View {
    let provider: any MediaProvider
    let captionSettings: CaptionSettings
    let spoilerSettings: SpoilerSettings
    let showDiagnostics: Bool
    let ratingsProvider: any ExternalRatingsProviding
    @Binding var pendingPlayItemID: String?

    @State private var path = NavigationPath()
    @State private var playRequest: PlayRequest?
    @State private var resumePrompt: MediaItem?

    var body: some View {
        NavigationStack(path: $path) {
            HomeView(
                viewModel: HomeViewModel(provider: provider),
                spoilerSettings: spoilerSettings,
                onSelectItem: { open($0) },
                onSelectLibrary: { library in
                    path.append(library)
                }
            )
            .navigationDestination(for: MediaLibrary.self) { library in
                LibraryBrowseView(
                    viewModel: LibraryBrowseViewModel(provider: provider, containerID: library.id, containerKind: library.kind),
                    title: library.title,
                    spoilerSettings: spoilerSettings,
                    onSelect: { open($0) }
                )
            }
            .navigationDestination(for: MediaItem.self) { item in
                ItemDetailView(
                    viewModel: ItemDetailViewModel(provider: provider, itemID: item.id, ratingsProvider: ratingsProvider),
                    spoilerSettings: spoilerSettings,
                    onPlay: { requestPlay($0) },
                    onSelectChild: { open($0) }
                )
            }
        }
        .fullScreenCover(item: $playRequest) { request in
            PlayerView(
                viewModel: PlayerViewModel(
                    provider: provider,
                    itemID: request.item.id,
                    captionSettings: captionSettings,
                    startPosition: request.startPosition
                )
            )
        }
        .resumePrompt(item: $resumePrompt) { item, startPosition in
            playRequest = PlayRequest(item: item, startPosition: startPosition)
        }
        .task(id: pendingPlayItemID) { await handleDeepLink() }
    }

    /// Resolves a deep-linked item id (from a Top Shelf card) and routes to it,
    /// then clears the request so it fires exactly once.
    private func handleDeepLink() async {
        guard let id = pendingPlayItemID else { return }
        pendingPlayItemID = nil
        if let item = try? await provider.item(id: id) {
            open(item)
        }
    }

    /// Playable leaves start playback (via the resume prompt when applicable);
    /// containers push a detail page.
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
/// player presentation, mirroring `HomeTab`'s wiring.
private struct SearchTab: View {
    let provider: any MediaProvider
    let captionSettings: CaptionSettings
    let spoilerSettings: SpoilerSettings
    let showDiagnostics: Bool
    let ratingsProvider: any ExternalRatingsProviding

    @State private var path = NavigationPath()
    @State private var playingItem: MediaItem?

    var body: some View {
        NavigationStack(path: $path) {
            SearchView(
                viewModel: SearchViewModel(provider: provider),
                spoilerSettings: spoilerSettings,
                onSelect: { open($0) }
            )
            .navigationDestination(for: MediaItem.self) { item in
                ItemDetailView(
                    viewModel: ItemDetailViewModel(provider: provider, itemID: item.id, ratingsProvider: ratingsProvider),
                    spoilerSettings: spoilerSettings,
                    onPlay: { playingItem = $0 },
                    onSelectChild: { open($0) }
                )
            }
        }
        .fullScreenCover(item: $playingItem) { item in
            PlayerView(
                viewModel: PlayerViewModel(
                    provider: provider,
                    itemID: item.id,
                    captionSettings: captionSettings
                ),
                showDiagnostics: showDiagnostics
            )
        }
    }

    /// Playable leaves go straight to the player; containers push a detail page.
    private func open(_ item: MediaItem) {
        switch item.kind {
        case .movie, .episode, .video:
            playingItem = item
        default:
            path.append(item)
        }
    }
}

#endif
