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
/// branch H. Settings exposes account management (add/remove).
struct MainTabView: View {
    let provider: any MediaProvider
    let captionModel: CaptionSettingsModel
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
                pendingPlayItemID: $pendingPlayItemID
            )
            .tabItem { Label("Home", systemImage: "house.fill") }

            SettingsView(
                captions: captionModel,
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

/// Home tab with its own navigation stack: Home → Detail → (Detail) and
/// full-screen player presentation.
private struct HomeTab: View {
    let provider: any MediaProvider
    let captionSettings: CaptionSettings
    @Binding var pendingPlayItemID: String?

    @State private var path: [MediaItem] = []
    @State private var playingItem: MediaItem?

    var body: some View {
        NavigationStack(path: $path) {
            HomeView(
                viewModel: HomeViewModel(provider: provider),
                onSelectItem: { open($0) },
                onSelectLibrary: { library in
                    path.append(MediaItem(id: library.id, title: library.title, kind: library.kind))
                }
            )
            .navigationDestination(for: MediaItem.self) { item in
                ItemDetailView(
                    viewModel: ItemDetailViewModel(provider: provider, itemID: item.id),
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
