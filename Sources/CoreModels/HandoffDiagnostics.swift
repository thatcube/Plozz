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
///  - **Toggleable & free when off.** Gated by ``isEnabled`` (default off; auto-on
///    only under `PLZXHAND_STDOUT=1`), so shipped/normal runs stay silent.
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

    /// Emits one already-formatted telemetry line (the `PLZXHAND ` prefix is added).
    /// No-op when disabled.
    public static func emit(_ line: String) {
        guard gate.isEnabled else { return }
        #if canImport(OSLog)
        // `.notice` so Console.app shows it without the "Include Info Messages"
        // toggle and it persists to the log store (retrievable via `log show`).
        logger.notice("PLZXHAND \(line, privacy: .public)")
        #endif
        if mirrorsStandardOut {
            try? FileHandle.standardOutput.write(contentsOf: Data(("PLZXHAND " + line + "\n").utf8))
        }
    }

    /// Milliseconds between two dates, formatted for a log line.
    public static func ms(_ from: Date, _ to: Date = Date()) -> String {
        String(format: "%.0fms", to.timeIntervalSince(from) * 1000)
    }

    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var enabled = ProcessInfo.processInfo.environment["PLZXHAND_STDOUT"] == "1"
        var isEnabled: Bool { lock.lock(); defer { lock.unlock() }; return enabled }
        func setEnabled(_ value: Bool) { lock.lock(); enabled = value; lock.unlock() }
    }
}
