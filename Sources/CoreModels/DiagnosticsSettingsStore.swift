import Foundation
import Observation

/// Persists `DiagnosticsSettings` across launches.
public protocol DiagnosticsSettingsStoring: Sendable {
    func load() -> DiagnosticsSettings
    func save(_ settings: DiagnosticsSettings)
}

public final class DiagnosticsSettingsStore: DiagnosticsSettingsStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    /// - Parameter namespace: per-profile scope. `nil` (the default/primary
    ///   profile) uses the legacy un-suffixed key; other profiles pass their
    ///   `Profile.id`.
    public init(defaults: UserDefaults = .standard, namespace: String? = nil) {
        self.defaults = defaults
        self.key = SettingsKey.scoped("com.plozz.diagnosticsSettings", namespace: namespace)
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
