import Foundation
import Observation

/// Persists the selected `AppTheme` across launches in standard `UserDefaults`.
///
/// Mirrors `CaptionSettingsStore` / `SpoilerSettingsStore`. The theme is stored
/// locally only (key `com.plozz.appTheme`); there is intentionally no App Group
/// or cross-app sharing.
public protocol ThemeSettingsStoring: Sendable {
    func load() -> AppTheme
    func save(_ theme: AppTheme)
}

public final class ThemeSettingsStore: ThemeSettingsStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "com.plozz.appTheme"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> AppTheme {
        guard let raw = defaults.string(forKey: key),
              let theme = AppTheme(rawValue: raw) else {
            return .default
        }
        return theme
    }

    public func save(_ theme: AppTheme) {
        defaults.set(theme.rawValue, forKey: key)
    }
}

/// Observable wrapper so SwiftUI settings screens can two-way bind and have the
/// chosen theme persisted + broadcast to the view tree. Mirrors
/// `CaptionSettingsModel`.
@MainActor
@Observable
public final class ThemeSettingsModel {
    public var theme: AppTheme {
        didSet { store.save(theme) }
    }

    private let store: ThemeSettingsStoring

    public init(store: ThemeSettingsStoring = ThemeSettingsStore()) {
        self.store = store
        self.theme = store.load()
    }
}
