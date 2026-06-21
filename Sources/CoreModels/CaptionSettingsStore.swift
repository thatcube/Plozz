import Foundation
import Observation

/// Persists `CaptionSettings` across launches.
public protocol CaptionSettingsStoring: Sendable {
    func load() -> CaptionSettings
    func save(_ settings: CaptionSettings)
}

public final class CaptionSettingsStore: CaptionSettingsStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "com.plozz.captionSettings"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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
