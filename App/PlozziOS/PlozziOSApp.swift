import AppShelliOS
import SwiftUI

@main
struct PlozziOSApp: App {
    init() {
        URLCache.shared = URLCache(
            memoryCapacity: 64 * 1024 * 1024,
            diskCapacity: 512 * 1024 * 1024,
            directory: nil
        )
    }

    var body: some Scene {
        WindowGroup {
            PlozziOSRootView()
        }
    }
}
