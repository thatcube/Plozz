import Foundation
#if canImport(OSLog)
import OSLog
#endif

/// On-device **episode hand-off / bring-up** telemetry. Makes the next-episode
/// prefetch, engine routing, and time-to-first-frame visible on the Apple TV so
/// the hand-off can be measured and tuned on real hardware (which can't be
/// reproduced locally — remote sources, HDMI mode switches, real decode latency).
///
/// Every line is tagged `PLZXHAND` (a deliberately unique token so it never
/// collides with Apple's own logging) under subsystem `com.plozz.app`, category
/// `handoff`. Search `PLZXHAND` in Console.app, or launch the app with
/// `PLZXHAND_STDOUT=1` in its environment (via
/// `DEVICECTL_CHILD_PLZXHAND_STDOUT=1 devicectl device process launch --console`)
/// to mirror each line to stdout for a live off-device stream.
///
/// Design constraints (must hold):
///  - **Never delay or alter playback.** Emitting is fire-and-forget `os_log` plus
///    cheap string building; nothing blocks, throws, or feeds back into bring-up.
///  - **Secret-safe.** Only item ids, provider kinds, engine kinds, and timings —
///    never tokens/URLs with credentials.
///  - **Toggleable & free in release.** Debug builds keep a bounded local trace so
///    intermittent failures can be inspected without relaunching the app; release
///    builds remain off unless explicitly launched with `PLZXHAND_STDOUT=1`.
///  - **Linux-safe.** `OSLog` is guarded so pure logic modules still compile on CI.
public enum HandoffDiagnostics {
    private static let gate = Gate()

    /// Whether hand-off telemetry is currently emitted.
    public static var isEnabled: Bool { gate.isEnabled }

    /// Enables/disables emission at runtime (e.g. mirrors a diagnostics setting).
    public static func setEnabled(_ enabled: Bool) { gate.setEnabled(enabled) }

    #if canImport(OSLog)
    private static let logger = Logger(subsystem: "com.plozz.app", category: "handoff")
    #endif

    /// When launched with `PLZXHAND_STDOUT=1`, each line is ALSO written to stdout,
    /// which `devicectl device process launch --console` forwards off-device (the
    /// unified log isn't remotely readable on this toolchain). Opt-in, read once.
    private static let mirrorsStandardOut: Bool =
        ProcessInfo.processInfo.environment["PLZXHAND_STDOUT"] == "1"
    private static let recorder = LocalRecorder()

    /// Emits one already-formatted telemetry line (the `PLZXHAND ` prefix is added).
    /// No-op when disabled.
    public static func emit(_ line: String) {
        guard gate.isEnabled else { return }
        #if canImport(OSLog)
        // `.notice` so Console.app shows it without the "Include Info Messages"
        // toggle and it persists to the log store (retrievable via `log show`).
        logger.notice("PLZXHAND \(line, privacy: .public)")
        #endif
        recorder.append(line)
        if mirrorsStandardOut {
            try? FileHandle.standardOutput.write(contentsOf: Data(("PLZXHAND " + line + "\n").utf8))
        }
    }

    /// Milliseconds between two dates, formatted for a log line.
    public static func ms(_ from: Date, _ to: Date = Date()) -> String {
        String(format: "%.0fms", to.timeIntervalSince(from) * 1000)
    }

    public static func errorCode(_ error: AppError) -> String {
        switch error {
        case .serverUnreachable: return "serverUnreachable"
        case .invalidResponse: return "invalidResponse"
        case .unauthorized: return "unauthorized"
        case .invalidCredentials: return "invalidCredentials"
        case .notFound: return "notFound"
        case .conflict: return "conflict"
        case .quickConnectUnavailable: return "quickConnectUnavailable"
        case .quickConnectExpired: return "quickConnectExpired"
        case .cancelled: return "cancelled"
        case .decoding: return "decoding"
        case .unknown: return "unknown"
        }
    }

    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var enabled: Bool = {
            #if DEBUG
            true
            #else
            ProcessInfo.processInfo.environment["PLZXHAND_STDOUT"] == "1"
            #endif
        }()
        var isEnabled: Bool { lock.lock(); defer { lock.unlock() }; return enabled }
        func setEnabled(_ value: Bool) { lock.lock(); enabled = value; lock.unlock() }
    }

    /// Debug-only bounded trace at `Library/Caches/Plozz/playback-trace.log`.
    /// Writes run on a utility queue and never block playback.
    private final class LocalRecorder: @unchecked Sendable {
        private let queue = DispatchQueue(
            label: "com.thatcube.Plozz.HandoffDiagnostics",
            qos: .utility
        )
        private let maximumBytes = 64 * 1024

        func append(_ line: String) {
            #if DEBUG
            queue.async {
                guard let url = Self.traceURL() else { return }
                var data = (try? Data(contentsOf: url)) ?? Data()
                data.append(Data(("PLZXHAND \(line)\n").utf8))
                if data.count > self.maximumBytes {
                    data = Data(data.suffix(self.maximumBytes))
                }
                try? FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try? data.write(to: url, options: .atomic)
            }
            #endif
        }

        private static func traceURL() -> URL? {
            FileManager.default.urls(
                for: .cachesDirectory,
                in: .userDomainMask
            ).first?
                .appendingPathComponent("Plozz", isDirectory: true)
                .appendingPathComponent("playback-trace.log")
        }
    }
}
