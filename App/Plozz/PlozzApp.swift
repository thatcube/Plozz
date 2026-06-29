import SwiftUI
import AppShell
import CoreModels
import Inject

/// Plozz — an open-source tvOS Jellyfin client.
@main
struct PlozzApp: App {
    init() {
        URLCache.shared = URLCache(
            memoryCapacity: 64 * 1024 * 1024,   // 64 MB in memory
            diskCapacity: 512 * 1024 * 1024,    // 512 MB on disk
            directory: nil
        )
        #if DEBUG
        // Live UI hot-reload: load the InjectionNext bundle so saving any SwiftUI
        // file swaps the view in ~1s, no rebuild. On a real Apple TV the bundle is
        // embedded inside the app by copy_bundle.sh (as iOSInjection.bundle); on the
        // Simulator we fall back to InjectionNext.app's prebuilt bundle. No-op unless
        // the InjectionNext server is running. Release builds exclude this entirely.
        for path in [
            Bundle.main.bundlePath + "/iOSInjection.bundle",
            "/Applications/InjectionNext.app/Contents/Resources/tvOSInjection.bundle",
            "/Applications/InjectionNext.app/Contents/Resources/tvOSDevInjection.bundle",
        ] where Bundle(path: path)?.load() == true { break }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .enableInjection()
        }
    }
}
