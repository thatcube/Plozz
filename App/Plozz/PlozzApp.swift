import SwiftUI
import AppShell
import CoreModels

/// Plozz — an open-source tvOS client for Jellyfin, Emby, Plex, and media shares.
@main
struct PlozzApp: App {
    init() {
        URLCache.shared = URLCache(
            memoryCapacity: 64 * 1024 * 1024,   // 64 MB in memory
            diskCapacity: 512 * 1024 * 1024,    // 512 MB on disk
            directory: nil
        )
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
