import Foundation
import Observation

/// Persists `DiagnosticsSettings` across launches.
public protocol DiagnosticsSettingsStoring: Sendable {
    func load() -> DiagnosticsSettings
    func save(_ settings: DiagnosticsSettings)
}

public final class DiagnosticsSettingsStore: DiagnosticsSettingsStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "com.plozz.diagnosticsSettings"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> DiagnosticsSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(DiagnosticsSettings.self, from: data) else {
            return .default
        }
        return settings
    }

    public func save(_ settings: DiagnosticsSettings) {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: key)
        }
    }
}

/// Observable wrapper so SwiftUI settings screens can two-way bind and have
/// changes persisted + broadcast to any active player.
@MainActor
@Observable
public final class DiagnosticsSettingsModel {
    public var settings: DiagnosticsSettings {
        didSet { store.save(settings) }
    }

    private let store: DiagnosticsSettingsStoring

    public init(store: DiagnosticsSettingsStoring = DiagnosticsSettingsStore()) {
        self.store = store
        self.settings = store.load()
    }
}
