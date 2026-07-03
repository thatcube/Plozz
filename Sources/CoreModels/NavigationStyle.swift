import Foundation

/// How the app's top-level navigation chrome is presented (pure data model).
///
/// An **app-wide** (global, not per-profile) preference — the chrome is a
/// structural choice about the whole shell, not a per-viewer aesthetic — so it
/// mirrors `TransparencyPreference`: a single un-namespaced `@AppStorage` key
/// that `MainTabView` reads to pick a `TabViewStyle` and the Settings ▸
/// Appearance screen writes. Foundation-only so it can live in `CoreModels`
/// and be edited without importing SwiftUI.
///
/// Both looks are native tvOS 18 `TabView` presentations over the *same* tabs —
/// the individual pages are byte-for-byte identical regardless of choice, so
/// switching only swaps the surrounding chrome.
public enum NavigationStyle: String, CaseIterable, Identifiable, Codable, Sendable {
    /// The classic top tab bar (`.tabBarOnly`): tabs sit in a pill across the
    /// top of every page. This is the app's historical look.
    case tabBar
    /// The native collapsible left sidebar (`.sidebarAdaptable`): tabs collapse
    /// to a rail and expand on left-focus, matching the system TV app.
    case sidebar

    public var id: String { rawValue }

    /// Short, user-facing option label for the Settings picker.
    public var displayName: String {
        switch self {
        case .tabBar: return "Top Bar"
        case .sidebar: return "Sidebar"
        }
    }

    /// SF Symbol shown next to the option in Settings.
    public var symbolName: String {
        switch self {
        case .tabBar: return "rectangle.topthird.inset.filled"
        case .sidebar: return "sidebar.left"
        }
    }

    /// One-line explanation shown live beneath the picker as focus moves across
    /// it (mirrors `TransparencyPreference.detail`).
    public var detail: String {
        switch self {
        case .tabBar: return "Tabs sit in a bar across the top of each page."
        case .sidebar: return "A collapsible left sidebar that expands on focus."
        }
    }

    /// Default to the more immersive sidebar; the top bar remains available as an
    /// opt-in in Settings ▸ Appearance ▸ Navigation.
    public static let `default`: NavigationStyle = .sidebar

    /// AppStorage key shared by `MainTabView` (reads it to choose the tab style)
    /// and Settings (writes it). App-wide — do not namespace per profile.
    public static let storageKey = "navigationStyle"
}
