import SwiftUI
import AppShell
import CoreModels
import CoreUI

/// Plozz — an open-source tvOS client for Jellyfin, Emby, Plex, and media shares.
@main
struct PlozzApp: App {
    init() {
        URLCache.shared = URLCache(
            memoryCapacity: 64 * 1024 * 1024,   // 64 MB in memory
            diskCapacity: 512 * 1024 * 1024,    // 512 MB on disk
            directory: nil
        )
        MainActor.assumeIsolated { MainThreadStallProbe.startIfRequested() }
        // At process start, not behind any view. The hero-artwork trace latches so
        // it survives a relaunch, and the switch that turns it back off therefore
        // has to run somewhere that always runs — a tab-change hook does not, when
        // the app opens on the profile picker and never reaches the tabs.
        HeroArtDiagnostics.armLatchIfTracing()
    }

    var body: some Scene {
        WindowGroup {
            // tvOS has no per-app language control in Settings.app, so this is the
            // only way a household can run Plozz in a language other than the
            // device's. See CoreUI.AppLanguageScope.
            AppLanguageScope {
                RootView()
            }
            // Back must never quit the app just because focus hasn't settled —
            // see `TVBackButtonGuard`.
            .tvBackButtonGuard()
        }
    }
}
