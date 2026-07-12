import Foundation

/// Non-secret context attached to every crash report as tags. This is the
/// **only** app data we deliberately send. It must never contain PII, auth
/// tokens, server URLs/hostnames, media titles, or profile names — just the
/// coarse facts needed to triage a crash.
public struct CrashReportContext: Sendable {
    /// Sentry "release" identifier, e.g. `com.thatcube.Plozz@1.4.0+1004`.
    public var releaseName: String
    /// Marketing version, e.g. `1.4.0`.
    public var version: String
    /// Build number, e.g. `1004`.
    public var build: String
    /// `debug` | `testflight` | `production`.
    public var environment: String
    /// e.g. `tvOS 18.5`.
    public var systemVersion: String
    /// Hardware identifier, e.g. `AppleTV14,1`.
    public var deviceModel: String
    /// Which media backends are configured, e.g. `["Jellyfin", "Plex"]`. Names
    /// of the *provider kinds*, never server names/URLs.
    public var providers: [String]

    public init(
        releaseName: String,
        version: String,
        build: String,
        environment: String,
        systemVersion: String,
        deviceModel: String,
        providers: [String]
    ) {
        self.releaseName = releaseName
        self.version = version
        self.build = build
        self.environment = environment
        self.systemVersion = systemVersion
        self.deviceModel = deviceModel
        self.providers = providers
    }

    /// Builds a context from the running process. Callers supply the non-derivable
    /// bits (version/build/bundleID/providers); the rest is read from the device.
    public static func make(
        bundleIdentifier: String,
        version: String,
        build: String,
        providers: [String]
    ) -> CrashReportContext {
        CrashReportContext(
            releaseName: "\(bundleIdentifier)@\(version)+\(build)",
            version: version,
            build: build,
            environment: detectEnvironment(),
            systemVersion: currentSystemVersion(),
            deviceModel: deviceModelIdentifier(),
            providers: providers
        )
    }

    static func detectEnvironment() -> String {
        #if DEBUG
        return "debug"
        #else
        if let receiptURL = Bundle.main.appStoreReceiptURL,
           receiptURL.lastPathComponent == "sandboxReceipt" {
            return "testflight"
        }
        return "production"
        #endif
    }

    static func currentSystemVersion() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "tvOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    static func deviceModelIdentifier() -> String {
        var system = utsname()
        uname(&system)
        let mirror = Mirror(reflecting: system.machine)
        let identifier = mirror.children.reduce(into: "") { partial, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            partial.append(Character(UnicodeScalar(UInt8(value))))
        }
        return identifier.isEmpty ? "unknown" : identifier
    }
}

/// Abstraction so the app can hold a reporter without importing Sentry directly,
/// and so builds without a DSN transparently do nothing.
@MainActor
public protocol CrashReporter: AnyObject {
    var isActive: Bool { get }
    func start(context: CrashReportContext)
    func stop()
}

/// The reporter used when no DSN is baked in (local/dev builds, forks) — does
/// nothing at all.
@MainActor
public final class NoopCrashReporter: CrashReporter {
    public init() {}
    public private(set) var isActive = false
    public func start(context: CrashReportContext) {}
    public func stop() {}
}

/// Owns the concrete reporter and gates it behind (a) a DSN being present in the
/// build and (b) the user's opt-in consent. Safe to call `apply` repeatedly.
@MainActor
public final class CrashReportingController {
    private let reporter: CrashReporter

    /// True when this build shipped with a crash-reporting endpoint (a non-empty
    /// DSN was baked into Info.plist). When false the opt-in UI is shown disabled
    /// with an explanatory note, because there is nowhere to send reports.
    public let isConfigured: Bool

    public init(dsn: String = CrashReportingController.bundleDSN()) {
        let trimmed = dsn.trimmingCharacters(in: .whitespacesAndNewlines)
        #if canImport(Sentry)
        if trimmed.isEmpty {
            self.reporter = NoopCrashReporter()
            self.isConfigured = false
        } else {
            self.reporter = SentryCrashReporter(dsn: trimmed)
            self.isConfigured = true
        }
        #else
        self.reporter = NoopCrashReporter()
        self.isConfigured = false
        #endif
    }

    /// Reconcile the live reporter with the user's current consent. Starts on the
    /// first opt-in, stops on opt-out, and is a no-op when nothing changed or when
    /// the build has no DSN.
    public func apply(enabled: Bool, context: CrashReportContext) {
        guard isConfigured else { return }
        if enabled {
            if !reporter.isActive { reporter.start(context: context) }
        } else if reporter.isActive {
            reporter.stop()
        }
    }

    /// Reads the DSN baked into Info.plist (`PlozzSentryDSN`, injected at project
    /// generation time from the `PLOZZ_SENTRY_DSN` env var). Empty for any build
    /// that wasn't configured with one.
    public static nonisolated func bundleDSN() -> String {
        (Bundle.main.object(forInfoDictionaryKey: "PlozzSentryDSN") as? String) ?? ""
    }
}
