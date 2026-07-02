import Foundation
#if canImport(Sentry)
import Sentry
#endif

/// On-demand upload of the user's recent (already-redacted) log buffer to the
/// crash-reporting backend, so the developer can read the full log on a real
/// computer instead of squinting at a TV or trying to scan an impossibly dense
/// QR code.
///
/// This deliberately piggybacks on the existing opt-in Sentry pipe: it only does
/// anything when crash reporting is both **configured** (a DSN was baked into the
/// build) *and* **enabled** (the user turned it on in Help & Diagnostics, so the
/// SDK is actually running). Otherwise it sends nothing and returns `false`, and
/// the caller should tell the user to turn crash reporting on first.
public enum CrashDiagnostics {
    /// Send `logText` to the crash-reporting backend as a single event with the
    /// log attached as a file. Returns `true` when the report was handed off,
    /// `false` when crash reporting is inactive (no DSN, or not opted in).
    @MainActor
    @discardableResult
    public static func send(logText: String, note: String? = nil) -> Bool {
        #if canImport(Sentry)
        guard SentrySDK.isEnabled else { return false }

        let trimmed = logText.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = trimmed.isEmpty ? "(recent activity log was empty)" : trimmed
        let attachment = Attachment(
            data: Data(body.utf8),
            filename: "plozz-recent-activity.log",
            contentType: "text/plain"
        )

        SentrySDK.capture(message: note ?? "User diagnostics report") { scope in
            scope.setLevel(.info)
            scope.setTag(value: "user-diagnostics", key: "report.kind")
            scope.addAttachment(attachment)
        }
        return true
        #else
        return false
        #endif
    }

    /// Whether a diagnostics report can actually be sent right now (the SDK is
    /// live). UIs can use this to enable/disable a "Send to developer" button,
    /// though gating on the crash-reporting consent flag is usually clearer.
    @MainActor
    public static var isAvailable: Bool {
        #if canImport(Sentry)
        return SentrySDK.isEnabled
        #else
        return false
        #endif
    }
}
