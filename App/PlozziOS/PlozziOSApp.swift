import AppShelliOS
import CoreUI
import SwiftUI
import UIKit

private final class PlozziOSAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions:
            [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        PlozziOSBackgroundSessionBridge.activate()
        return true
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        PlozziOSBackgroundSessionBridge.handleEvents(
            identifier: identifier,
            completionHandler: completionHandler
        )
    }
}

@main
struct PlozziOSApp: App {
    @UIApplicationDelegateAdaptor(PlozziOSAppDelegate.self) private var appDelegate

    init() {
        URLCache.shared = URLCache(
            memoryCapacity: 64 * 1024 * 1024,
            diskCapacity: 512 * 1024 * 1024,
            directory: nil
        )
    }

    var body: some Scene {
        WindowGroup {
            // Same scope as tvOS so the two shells can't drift on how the
            // language override is applied. See CoreUI.AppLanguageScope.
            AppLanguageScope {
                PlozziOSRootView()
            }
        }
    }
}
