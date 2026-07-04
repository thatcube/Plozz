import Foundation
#if canImport(OSLog)
import OSLog
#endif

/// On-device **Home hero focus** telemetry. Makes the exact focus/paging event
/// sequence of the hero carousel visible in the device console so the
/// intermittent "focus lost on a page and returns in the wrong place" bug can be
/// pinpointed on real hardware (it reproduces ~20% of the time and can't be seen
/// in a unit test).
///
/// Every line is tagged `PLZHFOCUS` (a deliberately unique token so it can't
/// collide with Apple's own focus-engine logging) and emitted under subsystem
/// `com.plozz.app`, category `herofocus`. Search `PLZHFOCUS` in Console.app or
/// stream it with `log stream --predicate 'eventMessage CONTAINS "PLZHFOCUS"'`.
///
/// Each line is prefixed with a monotonic `t+<ms>` stamp (relative to the first
/// emit) so the 1–2 second focus-gap the maintainer describes is obvious even in
/// `--console` stdout, which has no per-line timestamp of its own.
///
/// Design constraints (must hold):
///  - **Never blocks or feeds back into focus handling.** Emitting is a
///    fire-and-forget `os_log` plus cheap string building; nothing here mutates
///    view state or touches `@FocusState`.
///  - **Secret-safe.** Only item titles, ids, indices and focus-target names are
///    logged — never tokens/PINs/auth headers.
///  - **Toggleable + silent by default.** Gated by ``isEnabled`` so shipped runs
///    stay silent. Auto-enabled when the process is launched with
///    `PLZHFOCUS_STDOUT=1` (also turns on the stdout mirror for live `--console`
///    streaming) or `PLZHFOCUS=1` (Console-only, no stdout mirror).
///  - **Linux-safe.** `OSLog` is guarded so the pure logic modules still compile
///    on non-Apple toolchains.
///
/// > NOTE: This is temporary debugging instrumentation. Once the root cause of
/// > the hero focus drop is found and fixed, gate it off (or remove it).
public enum HeroFocusDiagnostics {
    /// Thread-safe on/off gate. Default **off**; auto-enabled when the process is
    /// launched with `PLZHFOCUS_STDOUT=1` (stream via `--console`) or `PLZHFOCUS=1`
    /// (Console-only). Flip at runtime via ``setEnabled(_:)``.
    private static let gate = Gate()

    /// Whether hero-focus telemetry is currently emitted.
    public static var isEnabled: Bool { gate.isEnabled }

    /// Enables/disables emission at runtime (e.g. mirrors a diagnostics setting).
    public static func setEnabled(_ enabled: Bool) { gate.setEnabled(enabled) }

    #if canImport(OSLog)
    private static let logger = Logger(subsystem: "com.plozz.app", category: "herofocus")
    #endif

    /// When the process is launched with `PLZHFOCUS_STDOUT=1`, each line is ALSO
    /// written to stdout so `devicectl device process launch --console` can stream
    /// it live off the Apple TV (the unified log can't be read remotely on this
    /// macOS toolchain). Opt-in (read once at startup).
    private static let mirrorsStandardOut: Bool =
        ProcessInfo.processInfo.environment["PLZHFOCUS_STDOUT"] == "1"

    /// Monotonic clock start, captured on first use, so every line carries a
    /// relative `t+<ms>` stamp that makes gaps between events (the focus-loss
    /// window) easy to read.
    private static let start = DispatchTime.now().uptimeNanoseconds

    private static func stamp() -> String {
        let now = DispatchTime.now().uptimeNanoseconds
        let ms = Double(now &- start) / 1_000_000
        return String(format: "t+%.0fms", ms)
    }

    /// Emits one already-formatted telemetry line (the `PLZHFOCUS ` prefix and the
    /// `t+<ms>` stamp are added). No-op when disabled.
    public static func emit(_ line: String) {
        guard gate.isEnabled else { return }
        let stamped = "\(stamp()) \(line)"
        #if canImport(OSLog)
        // `.notice` (OSLogType.default) so Console.app shows these WITHOUT the
        // "Include Info Messages" toggle and `log stream` shows them by default.
        logger.notice("PLZHFOCUS \(stamped, privacy: .public)")
        #endif
        if mirrorsStandardOut {
            // Unbuffered write so `devicectl --console` sees each line immediately.
            try? FileHandle.standardOutput.write(contentsOf: Data(("PLZHFOCUS " + stamped + "\n").utf8))
        }
    }

    /// A thread-safe boolean holder (the module targets strict concurrency, so a
    /// plain mutable static isn't `Sendable`).
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        // Off unless the maintainer launches with one of the debug env vars, so
        // shipped builds stay silent without a Settings toggle.
        private var enabled =
            ProcessInfo.processInfo.environment["PLZHFOCUS_STDOUT"] == "1" ||
            ProcessInfo.processInfo.environment["PLZHFOCUS"] == "1"
        var isEnabled: Bool { lock.lock(); defer { lock.unlock() }; return enabled }
        func setEnabled(_ value: Bool) { lock.lock(); enabled = value; lock.unlock() }
    }
}
