import Foundation

/// How the app's top-level navigation chrome is presented (pure data model).
///
/// A **per-profile** display preference (each profile keeps its own choice) like
/// `AppTheme` / `CardStyle`: persisted via `NavigationStyleSettingsStore`
/// (namespace-scoped) and rebuilt on profile switch in
/// `AppState.rebuildSettingsModels()`. `MainTabView` reads the model to pick the
/// shell chrome and the Settings ▸ Appearance screen writes it. Foundation-only
/// so it can live in `CoreModels` and be edited without importing SwiftUI.
///
/// `.tabBar` and `.sidebar` are native tvOS 18 `TabView` presentations. The top
/// bar keeps the compact fixed destinations; the sidebar also exposes the active
/// profile and configured library destinations. `.rail` is Plozz's own chrome: a
/// collapsed icon rail that expands over stationary content, lists the viewer's
/// libraries as first-class destinations, and disappears entirely on a detail page.
public enum NavigationStyle: String, CaseIterable, Identifiable, Codable, Sendable {
    /// The native collapsible left sidebar (`.sidebarAdaptable`): tabs collapse
    /// to a rail and expand on left-focus, matching the system TV app.
    case sidebar
    /// Plozz's custom collapsible left rail. Collapsed to icons until focus enters
    /// it, then expands over stationary content; libraries are top-level
    /// destinations and Settings is pinned to the bottom.
    case rail
    /// The classic top tab bar (`.tabBarOnly`): tabs sit in a pill across the
    /// top of every page. This is the app's historical look.
    case tabBar

    public var id: String { rawValue }

    /// Short, user-facing option label for the Settings picker.
    public var displayName: LocalizedStringResource {
        switch self {
        case .tabBar:
            return LocalizedStringResource(
                "navigationStyle.tabBar",
                defaultValue: "Top Bar",
                comment: "Navigation layout option in Settings > Appearance."
            )
        case .sidebar:
            return LocalizedStringResource(
                "navigationStyle.sidebar",
                defaultValue: "Sidebar",
                comment: "Navigation layout option in Settings > Appearance."
            )
        case .rail:
            return LocalizedStringResource(
                "navigationStyle.rail",
                defaultValue: "Pinned Sidebar",
                comment: "Navigation layout option in Settings > Appearance."
            )
        }
    }

    /// SF Symbol shown next to the option in Settings.
    public var symbolName: String {
        switch self {
        case .tabBar: return "rectangle.topthird.inset.filled"
        case .sidebar: return "sidebar.left"
        case .rail: return "sidebar.leading"
        }
    }

    /// One-line explanation shown live beneath the picker as focus moves across
    /// it (mirrors `TransparencyPreference.detail`).
    public var detail: LocalizedStringResource {
        switch self {
        case .tabBar:
            return LocalizedStringResource(
                "navigationStyle.detail.tabBar",
                defaultValue: "Native tabs stay across the top.",
                comment: "One-line explanation shown under the navigation-style picker."
            )
        case .sidebar:
            return LocalizedStringResource(
                "navigationStyle.detail.sidebar",
                defaultValue: "The native sidebar opens from the top left.",
                comment: "One-line explanation shown under the navigation-style picker."
            )
        case .rail:
            return LocalizedStringResource(
                "navigationStyle.detail.rail",
                defaultValue: "The pinned sidebar stays visible on the left.",
                comment: "One-line explanation shown under the navigation-style picker."
            )
        }
    }

    /// Whether this chrome sits along the **leading edge** of the screen, so views
    /// that reach the left edge (the Home hero carousel) hand a Left press to the
    /// chrome instead of wrapping.
    public var hasLeadingEdgeChrome: Bool {
        switch self {
        case .sidebar, .rail: return true
        case .tabBar: return false
        }
    }

    /// Default to the native sidebar while Plozz's pinned rail remains available
    /// as an opt-in in Settings ▸ Appearance ▸ Navigation.
    public static let `default`: NavigationStyle = .sidebar

    /// Persistence key base shared by `MainTabView` (reads the model to choose the
    /// tab style) and Settings (writes it). Per-profile: the default profile reuses
    /// this un-suffixed key; other profiles namespace it via `SettingsKey.scoped`.
    public static let storageKey = "navigationStyle"
}
