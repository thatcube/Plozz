#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI
import FeatureHome
import FeaturePlayback
import FeatureSettings

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
                pendingPlayItemID: $pendingPlayItemID
            )
            .tabItem { Label("Home", systemImage: "house.fill") }

            SettingsView(
                captions: captionModel,
                spoilers: spoilerModel,
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
    @Binding var pendingPlayItemID: String?

    @State private var path = NavigationPath()
    @State private var playingItem: MediaItem?

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
                    viewModel: ItemDetailViewModel(provider: provider, itemID: item.id),
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
                )
            )
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
