import Foundation
import Observation

/// Opt-in consent for sending anonymised crash reports off-device.
///
/// **Default OFF** — nothing leaves the Apple TV unless the user turns this on
/// *and* the build was configured with a crash-reporting endpoint (DSN). This is
/// an **app-wide / household** setting, deliberately NOT per-profile: crash
/// reporting is about the app and the device, and a profile is non-secret
/// presentation metadata that must never gate privacy-sensitive plumbing (same
/// reasoning as the app-wide Transparency preference — see AGENTS.local.md
/// "Per-profile vs app-wide settings").
public struct CrashReportingSettings: Codable, Equatable, Sendable {
    /// Whether the user has opted in to sending crash reports. Off by default.
    public var isEnabled: Bool

    public init(isEnabled: Bool = false) {
        self.isEnabled = isEnabled
    }

    public static let `default` = CrashReportingSettings()
}

/// Persists `CrashReportingSettings`. Uses a single un-namespaced key so the
/// choice is shared by the whole household (never scoped to a profile).
public protocol CrashReportingSettingsStoring: Sendable {
    func load() -> CrashReportingSettings
    func save(_ settings: CrashReportingSettings)
}

public final class CrashReportingSettingsStore: CrashReportingSettingsStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "com.plozz.crashReportingSettings"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> CrashReportingSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(CrashReportingSettings.self, from: data) else {
            return .default
        }
        return settings
    }

    public func save(_ settings: CrashReportingSettings) {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: key)
        }
    }
}

/// Observable wrapper so the Settings toggle can two-way bind and the app root
/// can react to opt-in/opt-out to start or stop the reporter.
@MainActor
@Observable
public final class CrashReportingSettingsModel {
    public var settings: CrashReportingSettings {
        didSet { store.save(settings) }
    }

    private let store: CrashReportingSettingsStoring

    public init(store: CrashReportingSettingsStoring = CrashReportingSettingsStore()) {
        self.store = store
        self.settings = store.load()
    }
}
