import Foundation
import Observation

/// Persists the selected `NavigationStyle` across launches in standard
/// `UserDefaults`.
///
/// Mirrors `CardStyleSettingsStore` exactly. The style is stored **per profile**
/// (key `navigationStyle`, scoped by namespace); the primary profile keeps the
/// legacy un-suffixed key so existing installs upgrade cleanly and inherit the
/// choice they already made while it was an app-wide setting.
public protocol NavigationStyleSettingsStoring: Sendable {
    func load() -> NavigationStyle
    func save(_ style: NavigationStyle)
}

public final class NavigationStyleSettingsStore: NavigationStyleSettingsStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    /// - Parameter namespace: per-profile scope. `nil` (the default/primary
    ///   profile) uses the legacy un-suffixed key (`NavigationStyle.storageKey`);
    ///   other profiles pass their `Profile.id`.
    public init(defaults: UserDefaults = .standard, namespace: String? = nil) {
        self.defaults = defaults
        self.key = SettingsKey.scoped(NavigationStyle.storageKey, namespace: namespace)
    }

    public func load() -> NavigationStyle {
        guard let raw = defaults.string(forKey: key),
              let style = NavigationStyle(rawValue: raw) else {
            return .default
        }
        return style
    }

    public func save(_ style: NavigationStyle) {
        defaults.set(style.rawValue, forKey: key)
    }
}

/// Observable wrapper so SwiftUI settings screens can two-way bind and have the
/// chosen navigation chrome persisted + broadcast to the view tree. Mirrors
/// `CardStyleSettingsModel`.
///
/// Owns **both** halves of the navigation preference — which chrome, and (for the
/// custom rail) how its library list is arranged. They are one user-facing setting
/// edited on one Settings page, and keeping them together is what lets the rail
/// read a single model rather than widening `ProfileSettingsModel`'s observable
/// surface with a second, always-paired entry.
@MainActor
@Observable
public final class NavigationStyleSettingsModel {
    public var style: NavigationStyle {
        didSet { store.save(style) }
    }

    /// Which optional destinations and libraries navigation shows, plus the library
    /// order. Persisted regardless of style so switching chrome never loses it.
    public private(set) var libraryLayout: NavigationLibraryLayout

    public var showsWatchlist: Bool {
        get { libraryLayout.isVisible(NavigationLibraryLayout.watchlistKey) }
        set { setDestination(newValue, key: NavigationLibraryLayout.watchlistKey) }
    }

    public var showsMusic: Bool {
        get { libraryLayout.isVisible(NavigationLibraryLayout.musicKey) }
        set { setDestination(newValue, key: NavigationLibraryLayout.musicKey) }
    }

    private let store: NavigationStyleSettingsStoring
    private let layoutStore: NavigationLibraryLayoutStoring

    public init(
        store: NavigationStyleSettingsStoring = NavigationStyleSettingsStore(),
        layoutStore: NavigationLibraryLayoutStoring = NavigationLibraryLayoutStore()
    ) {
        self.store = store
        self.layoutStore = layoutStore
        self.style = store.load()
        self.libraryLayout = layoutStore.load()
    }

    /// The editable enabled/hidden split for the Settings reorder control.
    public func librarySections(available: [String]) -> OrderedVisibilityList.Sections<String> {
        libraryLayout.sections(available: available)
    }

    /// Applies an edit from the reorder control and persists it.
    public func applyLibrarySections(
        _ sections: OrderedVisibilityList.Sections<String>,
        available: [String]
    ) {
        var next = libraryLayout
        next.apply(sections, available: available)
        guard next != libraryLayout else { return }
        libraryLayout = next
        layoutStore.save(next)
    }

    /// Restores the default arrangement: every library shown, in discovery order.
    public func resetLibraryLayout() {
        var next = NavigationLibraryLayout.default
        next.hiddenKeys = libraryLayout.hiddenKeys.intersection([
            NavigationLibraryLayout.watchlistKey,
            NavigationLibraryLayout.musicKey,
        ])
        guard libraryLayout != next else { return }
        libraryLayout = next
        layoutStore.save(libraryLayout)
    }

    private func setDestination(_ visible: Bool, key: String) {
        var next = libraryLayout
        next.setVisible(visible, for: key)
        guard next != libraryLayout else { return }
        libraryLayout = next
        layoutStore.save(next)
    }
}
