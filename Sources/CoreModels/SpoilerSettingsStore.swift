import Foundation
import Observation

/// Persists `SpoilerSettings` across launches.
public protocol SpoilerSettingsStoring: Sendable {
    func load() -> SpoilerSettings
    func save(_ settings: SpoilerSettings)
}

public final class SpoilerSettingsStore: SpoilerSettingsStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    /// - Parameter namespace: per-profile scope. `nil` (the default/primary
    ///   profile) uses the legacy un-suffixed key so upgrading installs keep
    ///   their settings; other profiles pass their `Profile.id`.
    public init(defaults: UserDefaults = .standard, namespace: String? = nil) {
        self.defaults = defaults
        self.key = SettingsKey.scoped("com.plozz.spoilerSettings", namespace: namespace)
    }

    public func load() -> SpoilerSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(SpoilerSettings.self, from: data) else {
            return .default
        }
        return settings
    }

    public func save(_ settings: SpoilerSettings) {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: key)
        }
    }
}

/// Observable wrapper so SwiftUI settings screens can two-way bind and have
/// changes persisted + broadcast to the browsing UI.
@MainActor
@Observable
public final class SpoilerSettingsModel {
    public var settings: SpoilerSettings {
        didSet { store.save(settings) }
    }

    private let store: SpoilerSettingsStoring

    public init(store: SpoilerSettingsStoring = SpoilerSettingsStore()) {
        self.store = store
        self.settings = store.load()
    }
}