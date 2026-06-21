import Foundation
import Observation

/// Persists `CaptionSettings` across launches.
public protocol CaptionSettingsStoring: Sendable {
    func load() -> CaptionSettings
    func save(_ settings: CaptionSettings)
}

public final class CaptionSettingsStore: CaptionSettingsStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    /// - Parameter namespace: per-profile scope. `nil` (the default/primary
    ///   profile) uses the legacy un-suffixed key; other profiles pass their
    ///   `Profile.id`.
    public init(defaults: UserDefaults = .standard, namespace: String? = nil) {
        self.defaults = defaults
        self.key = SettingsKey.scoped("com.plozz.captionSettings", namespace: namespace)
    }

    public func load() -> CaptionSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(CaptionSettings.self, from: data) else {
            return .default
        }
        return settings
    }

    public func save(_ settings: CaptionSettings) {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: key)
        }
    }
}

/// Observable wrapper so SwiftUI settings screens can two-way bind and have
/// changes persisted + broadcast to any active player.
@MainActor
@Observable
public final class CaptionSettingsModel {
    public var settings: CaptionSettings {
        didSet { store.save(settings) }
    }

    private let store: CaptionSettingsStoring

    public init(store: CaptionSettingsStoring = CaptionSettingsStore()) {
        self.store = store
        self.settings = store.load()
    }
}
