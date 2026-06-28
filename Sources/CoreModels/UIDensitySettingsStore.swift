import Foundation
import Observation

/// Persists the selected `UIDensity` across launches in standard `UserDefaults`.
///
/// Mirrors `ThemeSettingsStore` exactly. The density is stored **per profile**
/// (key `com.plozz.uiDensity`, scoped by namespace); the primary profile keeps
/// the legacy un-suffixed key so existing installs upgrade cleanly.
public protocol UIDensitySettingsStoring: Sendable {
    func load() -> UIDensity
    func save(_ density: UIDensity)
}

public final class UIDensitySettingsStore: UIDensitySettingsStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    /// - Parameter namespace: per-profile scope. `nil` (the default/primary
    ///   profile) uses the legacy un-suffixed key; other profiles pass their
    ///   `Profile.id`.
    public init(defaults: UserDefaults = .standard, namespace: String? = nil) {
        self.defaults = defaults
        self.key = SettingsKey.scoped("com.plozz.uiDensity", namespace: namespace)
    }

    public func load() -> UIDensity {
        guard let raw = defaults.string(forKey: key),
              let density = UIDensity(rawValue: raw) else {
            return .default
        }
        return density
    }

    public func save(_ density: UIDensity) {
        defaults.set(density.rawValue, forKey: key)
    }
}

/// Observable wrapper so SwiftUI settings screens can two-way bind and have the
/// chosen density persisted + broadcast to the view tree. Mirrors
/// `ThemeSettingsModel`.
@MainActor
@Observable
public final class UIDensitySettingsModel {
    public var density: UIDensity {
        didSet { store.save(density) }
    }

    private let store: UIDensitySettingsStoring

    public init(store: UIDensitySettingsStoring = UIDensitySettingsStore()) {
        self.store = store
        self.density = store.load()
    }
}
