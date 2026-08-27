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
    /// e.g. `tvOS 18.5` or `iOS 18.5`.
    public var systemVersion: String
    /// Hardware identifier, e.g. `AppleTV14,1`.
    public var deviceModel: String
    /// Which media backends are configured, e.g. `["Jellyfin", "Plex"]`. Names
    /// of the *provider kinds*, never server names/URLs.
    public var providers: [String]
    /// `maintainer` when this device is flagged as the maintainer's own, else
    /// `user`. Sent as a tag so a crash the maintainer caused while testing can
    /// be told apart from one a real person hit.
    public var deviceRole: String

    public init(
        releaseName: String,
        version: String,
        build: String,
        environment: String,
        systemVersion: String,
        deviceModel: String,
        providers: [String],
        deviceRole: String = "user"
    ) {
        self.releaseName = releaseName
        self.version = version
        self.build = build
        self.environment = environment
        self.systemVersion = systemVersion
        self.deviceModel = deviceModel
        self.providers = providers
        self.deviceRole = deviceRole
    }

    /// Builds a context from the running process. Callers supply the non-derivable
    /// bits (version/build/bundleID/providers); the rest is read from the device.
    ///
    /// - Parameter isMaintainerDevice: when true the environment is suffixed
    ///   `-dev`, so the maintainer's own testing drops out of the plain
    ///   `testflight` / `production` filter instead of masquerading as a real
    ///   person's crash.
    public static func make(
        bundleIdentifier: String,
        version: String,
        build: String,
        providers: [String],
        isMaintainerDevice: Bool = false
    ) -> CrashReportContext {
        CrashReportContext(
            releaseName: "\(bundleIdentifier)@\(version)+\(build)",
            version: version,
            build: build,
            environment: environmentName(isMaintainerDevice: isMaintainerDevice),
            systemVersion: currentSystemVersion(),
            deviceModel: deviceModelIdentifier(),
            providers: providers,
            deviceRole: isMaintainerDevice ? "maintainer" : "user"
        )
    }

    /// The release channel, narrowed to a separate environment when the device is
    /// the maintainer's.
    ///
    /// `debug` is deliberately left alone: a Debug build is already only ever the
    /// maintainer's, so `debug-dev` would add a second name for one thing and
    /// split its history in two.
    static func environmentName(isMaintainerDevice: Bool) -> String {
        environmentName(base: detectEnvironment(), isMaintainerDevice: isMaintainerDevice)
    }

    /// The pure rule, split out so it is testable. `detectEnvironment()` always
    /// answers `debug` under a test run, which would leave the interesting cases
    /// (`testflight` → `testflight-dev`) impossible to assert.
    static func environmentName(base: String, isMaintainerDevice: Bool) -> String {
        guard isMaintainerDevice, base != "debug" else { return base }
        return "\(base)-dev"
    }

    static func detectEnvironment() -> String {
        #if DEBUG
        return "debug"
        #else
        // Keep in sync with `AppReleaseChannel.current` in CoreModels (this module
        // sits below it and can't import it). A channel baked in at build time by
        // tools/generate-project.sh is authoritative; the receipt is only a hint,
        // and on tvOS `appStoreReceiptURL` can be nil entirely.
        if let raw = Bundle.main.object(forInfoDictionaryKey: "PlozzReleaseChannel") as? String {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if trimmed == "testflight" || trimmed == "production" || trimmed == "debug" {
                return trimmed
            }
        }
        if let receiptURL = Bundle.main.appStoreReceiptURL,
           receiptURL.lastPathComponent == "sandboxReceipt" {
            return "testflight"
        }
        return "production"
        #endif
    }

    static func currentSystemVersion() -> String {  // l10n:content — crash-report tag metadata, never displayed to users
        let v = ProcessInfo.processInfo.operatingSystemVersion
        #if os(tvOS)
        let platform = "tvOS"
        #elseif os(iOS)
        let platform = "iOS"
        #else
        let platform = "Apple OS"
        #endif
        return "\(platform) \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
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
    func update(context: CrashReportContext)
    func stop()
}

/// The reporter used when no DSN is baked in (local/dev builds, forks) — does
/// nothing at all.
@MainActor
public final class NoopCrashReporter: CrashReporter {
    public init() {}
    public private(set) var isActive = false
    public func start(context: CrashReportContext) {}
    public func update(context: CrashReportContext) {}
    public func stop() {}
}

/// Owns the concrete reporter and gates it behind (a) a DSN being present in the
/// build and (b) the user's opt-in consent. Safe to call `apply` repeatedly.
@MainActor
public final class CrashReportingController {
    private let reporter: CrashReporter
    /// The environment the live reporter was STARTED with. Sentry reads
    /// `options.environment` once, at `start`, and never again — so re-tagging the
    /// scope cannot move an already-running reporter between `testflight` and
    /// `testflight-dev`. Toggling the maintainer marker has to restart it, and
    /// this is how we notice it changed.
    private var activeEnvironment: String?

    /// True when this build shipped with a crash-reporting endpoint (a non-empty
    /// DSN was baked into Info.plist). When false the opt-in UI is shown disabled
    /// with an explanatory note, because there is nowhere to send reports.
    public let isConfigured: Bool

    public init(dsn: String = CrashReportingController.bundleDSN()) {
        let trimmed = dsn.trimmingCharacters(in: .whitespacesAndNewlines)
        let isUnresolvedBuildSetting =
            trimmed.hasPrefix("$(") && trimmed.hasSuffix(")")
        #if canImport(Sentry)
        if trimmed.isEmpty || isUnresolvedBuildSetting {
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

    /// Test seam: inject a reporter directly. The DSN-based initializer decides
    /// *which* reporter to build; the lifecycle rules below (start/stop/restart on
    /// an environment change) are independent of that choice and need asserting.
    init(reporter: CrashReporter, isConfigured: Bool) {
        self.reporter = reporter
        self.isConfigured = isConfigured
    }

    /// Reconcile the live reporter with the user's current consent. Starts on the
    /// first opt-in, stops on opt-out, and is a no-op when nothing changed or when
    /// the build has no DSN.
    public func apply(enabled: Bool, context: CrashReportContext) {
        guard isConfigured else { return }
        if enabled {
            if reporter.isActive {
                if activeEnvironment != context.environment {
                    // Environment is start-time only — restart to move channels.
                    reporter.stop()
                    reporter.start(context: context)
                    activeEnvironment = context.environment
                } else {
                    reporter.update(context: context)
                }
            } else {
                reporter.start(context: context)
                activeEnvironment = context.environment
            }
        } else if reporter.isActive {
            reporter.stop()
            activeEnvironment = nil
        }
    }

    /// Reads the DSN baked into Info.plist (`PlozzSentryDSN`, injected at project
    /// generation time from the `PLOZZ_SENTRY_DSN` env var). Empty for any build
    /// that wasn't configured with one.
    public static nonisolated func bundleDSN() -> String {
        (Bundle.main.object(forInfoDictionaryKey: "PlozzSentryDSN") as? String) ?? ""
    }
}
