#if canImport(SwiftUI)
import SwiftUI
import CoreModels

/// The active profile's `NavigationStyle`, injected into the SwiftUI environment
/// at the app root (see `RootView`) alongside `\.plozzCardStyle`. Views that need
/// to adapt to the top-bar-vs-sidebar chrome without threading the model (e.g. the
/// Music now-playing layout) read this, so switching the "Navigation" setting — or
/// switching to a profile with a different choice — updates them live.
private struct PlozzNavigationStyleKey: EnvironmentKey {
    static let defaultValue: NavigationStyle = .default
}

public extension EnvironmentValues {
    /// The live, per-profile navigation chrome (top bar vs. sidebar). Set once at
    /// the app root; read by chrome-sensitive views like the Music player layout.
    var plozzNavigationStyle: NavigationStyle {
        get { self[PlozzNavigationStyleKey.self] }
        set { self[PlozzNavigationStyleKey.self] = newValue }
    }
}
#endif
