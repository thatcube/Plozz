import Foundation
import Observation

/// Persists `PlaybackSettings` across launches (mirrors `SpoilerSettingsStore`).
public protocol PlaybackSettingsStoring: Sendable {
    func load() -> PlaybackSettings
    func save(_ settings: PlaybackSettings)
}

public final class PlaybackSettingsStore: PlaybackSettingsStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    /// - Parameter namespace: per-profile scope. `nil` (the default/primary
    ///   profile) uses the legacy un-suffixed key so upgrading installs keep
    ///   their settings; other profiles pass their `Profile.id`.
    public init(defaults: UserDefaults = .standard, namespace: String? = nil) {
        self.defaults = defaults
        self.key = SettingsKey.scoped("com.plozz.playbackSettings", namespace: namespace)
    }

    public func load() -> PlaybackSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(PlaybackSettings.self, from: data) else {
            return .default
        }
        return settings
    }

    public func save(_ settings: PlaybackSettings) {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: key)
        }
    }
}

/// Observable wrapper so SwiftUI settings screens can two-way bind and have
/// changes persisted + read by the player.
@MainActor
@Observable
public final class PlaybackSettingsModel {
    public var settings: PlaybackSettings {
        didSet { store.save(settings) }
    }

    private let store: PlaybackSettingsStoring

    public init(store: PlaybackSettingsStoring = PlaybackSettingsStore()) {
        self.store = store
        self.settings = store.load()
    }
}
