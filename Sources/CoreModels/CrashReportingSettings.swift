import Foundation
import Observation

/// Which release channel this build is running as. Used to pick a sensible
/// default for privacy-sensitive plumbing (crash reporting) that captures beta
/// feedback automatically while keeping the shipping App Store build opt-in.
///
/// Mirrors the environment detection in `CrashReporting.detectEnvironment()`,
/// duplicated here because CoreModels sits below the CrashReporting module and
/// cannot depend on it. Keep the two in sync.
public enum AppReleaseChannel: Sendable {
    case debug
    case testflight
    case production

    public static var current: AppReleaseChannel {
        #if DEBUG
        return .debug
        #else
        if let receiptURL = Bundle.main.appStoreReceiptURL,
           receiptURL.lastPathComponent == "sandboxReceipt" {
            return .testflight
        }
        return .production
        #endif
    }

    /// Debug + TestFlight are "beta": builds still under active testing. The App
    /// Store / production build is not.
    public var isBeta: Bool { self != .production }
}

/// Opt-in consent for sending anonymised crash reports off-device.
///
/// **Default depends on the release channel.** During beta (Debug + TestFlight)
/// crash reporting defaults **ON** so tester crashes are captured without each
/// person hunting for a toggle; the shipping **App Store build defaults OFF**
/// (explicit opt-in). Either way, nothing is sent unless the build was also
/// configured with a crash-reporting endpoint (DSN), and the user can flip the
/// switch at any time — an explicit choice is always honoured over the default.
///
/// This is an **app-wide / household** setting, deliberately NOT per-profile:
/// crash reporting is about the app and the device, and a profile is non-secret
/// presentation metadata that must never gate privacy-sensitive plumbing (same
/// reasoning as the app-wide Transparency preference — see AGENTS.local.md
/// "Per-profile vs app-wide settings").
public struct CrashReportingSettings: Codable, Equatable, Sendable {
    /// Whether the user has opted in to sending crash reports.
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
    /// The persisted value, or `nil` when the user has never made a choice. Lets
    /// callers distinguish "unset" (apply the channel default) from an explicit
    /// opt-out that must be respected.
    func loadStored() -> CrashReportingSettings?
    func save(_ settings: CrashReportingSettings)
}

public final class CrashReportingSettingsStore: CrashReportingSettingsStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "com.plozz.crashReportingSettings"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> CrashReportingSettings {
        loadStored() ?? .default
    }

    public func loadStored() -> CrashReportingSettings? {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(CrashReportingSettings.self, from: data) else {
            return nil
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

    /// - Parameter defaultConsentWhenUnset: consent to assume when the user has
    ///   made no explicit choice yet. Defaults to the release-channel default
    ///   (beta → on, production → off). The default is **not** persisted, so a
    ///   tester who upgrades a never-touched install from TestFlight to the App
    ///   Store correctly reverts to opt-in.
    public init(
        store: CrashReportingSettingsStoring = CrashReportingSettingsStore(),
        defaultConsentWhenUnset: Bool = AppReleaseChannel.current.isBeta
    ) {
        self.store = store
        self.settings = store.loadStored()
            ?? CrashReportingSettings(isEnabled: defaultConsentWhenUnset)
    }
}
