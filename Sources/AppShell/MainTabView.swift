#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI
import FeatureHome
import FeaturePlayback
import FeatureSettings

/// The signed-in experience: Home and Settings tabs, with item-detail
/// navigation and full-screen playback.
struct MainTabView: View {
    let provider: any MediaProvider
    let captionModel: CaptionSettingsModel
    let spoilerModel: SpoilerSettingsModel
    @Binding var pendingPlayItemID: String?
    let onSignOut: () -> Void

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
                userName: provider.session.userName,
                serverName: provider.session.server.name,
                serverURL: provider.session.server.baseURL.absoluteString,
                appVersion: AppInfo.version,
                appBuild: AppInfo.build,
                repoURL: AppInfo.repoURLString,
                onSignOut: onSignOut
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
    let spoilerSettings: SpoilerSettings
    @Binding var pendingPlayItemID: String?

    @State private var path: [MediaItem] = []
    @State private var playingItem: MediaItem?

    var body: some View {
        NavigationStack(path: $path) {
            HomeView(
                viewModel: HomeViewModel(provider: provider),
                spoilerSettings: spoilerSettings,
                onSelectItem: { open($0) },
                onSelectLibrary: { library in
                    path.append(MediaItem(id: library.id, title: library.title, kind: library.kind))
                }
            )
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
