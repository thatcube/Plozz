#if canImport(Sentry)
import Foundation
import Sentry

/// Sentry-backed crash reporter. Configured for **maximum privacy**: crash and
/// hang captures only, with all automatic UI/network telemetry disabled and a
/// hard scrub of anything that could carry PII before it leaves the device.
///
/// What is sent (only when the user has opted in AND a DSN is baked in):
///   • Crash stack traces (the whole point) and watchdog/hang signals.
///   • Coarse tags: app version/build, OS version, device model, provider kinds.
/// What is NOT sent: user identity, IP, server URLs/hostnames, media titles,
/// profile names, network/UI breadcrumbs, or performance traces.
@MainActor
public final class SentryCrashReporter: CrashReporter {
    private let dsn: String
    public private(set) var isActive = false

    public init(dsn: String) {
        self.dsn = dsn
    }

    public func start(context: CrashReportContext) {
        guard !isActive else { return }

        SentrySDK.start { options in
            options.dsn = self.dsn
            options.releaseName = context.releaseName
            options.dist = context.build
            options.environment = context.environment

            // ---- Privacy hardening ----
            // Never attach the device's default PII (IP address, etc.).
            options.sendDefaultPii = false
            // Killing swizzling removes Sentry's automatic UI/network breadcrumbs,
            // which are the main vector for leaking titles/URLs. Crashes are still
            // captured via the signal/mach-exception handlers, not swizzling.
            options.enableSwizzling = false
            // Stack traces on crashes are exactly what we want.
            options.attachStacktrace = true

            // No performance, tracing, or session telemetry.
            options.enableAutoPerformanceTracing = false
            options.tracesSampleRate = NSNumber(value: 0)
            options.enableAutoSessionTracking = false
            options.enableNetworkTracking = false
            options.enableNetworkBreadcrumbs = false
            options.enableCaptureFailedRequests = false

            // Keep the two crash-adjacent signals that are genuinely useful on an
            // Apple TV, where MetricKit is unavailable:
            options.enableWatchdogTerminationTracking = true // approximates jetsam/OOM kills
            options.enableAppHangTracking = true

            // Final belt-and-suspenders scrub of every outgoing event/breadcrumb.
            options.beforeSend = { event in CrashRedaction.scrub(event) }
            options.beforeBreadcrumb = { crumb in CrashRedaction.scrub(crumb) }
        }

        applyScope(context)

        isActive = true
    }

    public func update(context: CrashReportContext) {
        guard isActive else { return }
        applyScope(context)
    }

    public func stop() {
        guard isActive else { return }
        SentrySDK.close()
        isActive = false
    }

    private func applyScope(_ context: CrashReportContext) {
        SentrySDK.configureScope { scope in
            scope.setTag(value: context.version, key: "app.version")
            scope.setTag(value: context.build, key: "app.build")
            scope.setTag(value: context.systemVersion, key: "os.version")
            scope.setTag(value: context.deviceModel, key: "device.model")
            let providers = context.providers.isEmpty
                ? "none"
                : context.providers.joined(separator: "+")
            scope.setTag(value: providers, key: "providers")
        }
    }
}
#endif
