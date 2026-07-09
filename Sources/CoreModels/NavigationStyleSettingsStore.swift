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
@MainActor
@Observable
public final class NavigationStyleSettingsModel {
    public var style: NavigationStyle {
        didSet { store.save(style) }
    }

    private let store: NavigationStyleSettingsStoring

    public init(store: NavigationStyleSettingsStoring = NavigationStyleSettingsStore()) {
        self.store = store
        self.style = store.load()
    }
}
