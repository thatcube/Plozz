import SwiftUI
import AppShell
import CoreModels

/// Plozz — an open-source tvOS Jellyfin client.
@main
struct PlozzApp: App {
    init() {
        // Give artwork a real on-disk cache so backdrops, posters and logos load
        // instantly on revisit instead of being re-fetched every time (the
        // default shared URLCache is only a few MB — far too small for 4K
        // backdrops). AsyncImage and our URLSession-based loader both read
        // through URLCache.shared, so this keeps recently seen art warm the way a
        // dedicated player like Infuse does.
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
