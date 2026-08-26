import Foundation
import Observation

/// Persists the selected `CardFocusStyle` across launches in standard
/// `UserDefaults`.
///
/// Mirrors `CardStyleSettingsStore` exactly. The style is stored **per profile**
/// (key `com.plozz.cardFocusStyle`, scoped by namespace); the primary profile
/// keeps the un-suffixed key.
public protocol CardFocusStyleSettingsStoring: Sendable {
    func load() -> CardFocusStyle
    func save(_ style: CardFocusStyle)
}

public final class CardFocusStyleSettingsStore: CardFocusStyleSettingsStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    /// - Parameter namespace: per-profile scope. `nil` (the default/primary
    ///   profile) uses the un-suffixed key; other profiles pass their
    ///   `Profile.id`.
    public init(defaults: UserDefaults = .standard, namespace: String? = nil) {
        self.defaults = defaults
        self.key = SettingsKey.scoped("com.plozz.cardFocusStyle", namespace: namespace)
    }

    public func load() -> CardFocusStyle {
        guard let raw = defaults.string(forKey: key),
              let style = CardFocusStyle(rawValue: raw) else {
            return .default
        }
        return style
    }

    public func save(_ style: CardFocusStyle) {
        defaults.set(style.rawValue, forKey: key)
    }
}
