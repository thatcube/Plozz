import Foundation
import Observation

public protocol ThemeMusicSettingsStoring: Sendable {
    func load() -> ThemeMusicSettings
    func save(_ settings: ThemeMusicSettings)
}

public final class ThemeMusicSettingsStore: ThemeMusicSettingsStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, namespace: String? = nil) {
        self.defaults = defaults
        self.key = SettingsKey.scoped("com.plozz.themeMusicSettings", namespace: namespace)
    }

    public func load() -> ThemeMusicSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(ThemeMusicSettings.self, from: data) else {
            return .default
        }
        return settings
    }

    public func save(_ settings: ThemeMusicSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}

@MainActor
@Observable
public final class ThemeMusicSettingsModel {
    public var settings: ThemeMusicSettings {
        didSet { store.save(settings) }
    }

    private let store: ThemeMusicSettingsStoring

    public init(store: ThemeMusicSettingsStoring = ThemeMusicSettingsStore()) {
        self.store = store
        settings = store.load()
    }
}
