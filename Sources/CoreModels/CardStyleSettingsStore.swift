import Foundation
import Observation

/// Persists the selected `CardStyle` across launches in standard `UserDefaults`.
///
/// Mirrors `UIDensitySettingsStore` exactly. The style is stored **per profile**
/// (key `com.plozz.cardStyle`, scoped by namespace); the primary profile keeps
/// the legacy un-suffixed key so existing installs upgrade cleanly.
public protocol CardStyleSettingsStoring: Sendable {
    func load() -> CardStyle
    func save(_ style: CardStyle)
}

public final class CardStyleSettingsStore: CardStyleSettingsStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    /// - Parameter namespace: per-profile scope. `nil` (the default/primary
    ///   profile) uses the legacy un-suffixed key; other profiles pass their
    ///   `Profile.id`.
    public init(defaults: UserDefaults = .standard, namespace: String? = nil) {
        self.defaults = defaults
        self.key = SettingsKey.scoped("com.plozz.cardStyle", namespace: namespace)
    }

    public func load() -> CardStyle {
        guard let raw = defaults.string(forKey: key),
              let style = CardStyle(rawValue: raw) else {
            return .default
        }
        return style
    }

    public func save(_ style: CardStyle) {
        defaults.set(style.rawValue, forKey: key)
    }
}

/// Observable wrapper so SwiftUI settings screens can two-way bind and have the
/// chosen style persisted + broadcast to the view tree. Mirrors
/// `UIDensitySettingsModel`.
///
/// Carries the card's **focus** treatment too. The two are one preference in the
/// user's head — "how my cards look" — they're edited in the same Settings pane,
/// and keeping them together means adding a card preference doesn't widen the
/// per-profile settings facet (which is capped; see `tools/arch-guard.py`).
@MainActor
@Observable
public final class CardStyleSettingsModel {
    public var style: CardStyle {
        didSet { store.save(style) }
    }

    /// What focus does to a card: outline it, or grow and glisten it.
    public var focusStyle: CardFocusStyle {
        didSet { focusStore.save(focusStyle) }
    }

    private let store: CardStyleSettingsStoring
    private let focusStore: CardFocusStyleSettingsStoring

    public init(
        store: CardStyleSettingsStoring = CardStyleSettingsStore(),
        focusStore: CardFocusStyleSettingsStoring = CardFocusStyleSettingsStore()
    ) {
        self.store = store
        self.focusStore = focusStore
        self.style = store.load()
        self.focusStyle = focusStore.load()
    }
}
