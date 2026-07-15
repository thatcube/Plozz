import Foundation
#if canImport(OSLog)
import OSLog
#endif

/// Env-gate + telemetry for the **imperative UIKit hero foreground** proof-of-concept.
///
/// The whole feature is off unless the process is launched with
/// `PLZHERO_UIKIT_FOREGROUND=1`. When off, `HomeHeroView` renders its normal
/// SwiftUI foreground unchanged — the standard path is never touched — so this is
/// a fully reversible A/B lever for measuring whether an imperatively-updated
/// UIKit visual foreground removes the SwiftUI page-transition hitch.
enum HeroForegroundConfig {
    /// Read once at startup. `true` only when `PLZHERO_UIKIT_FOREGROUND=1`.
    static let useUIKitForeground: Bool =
        ProcessInfo.processInfo.environment["PLZHERO_UIKIT_FOREGROUND"] == "1"
}

/// Gated, secret-safe markers for the UIKit foreground renderer: how long an
/// imperative `apply`/`prepare` took, and whether a slide's model was already
/// prepared (a bounded-window **HIT**) or built on the transition (**MISS**).
///
/// Mirrors the design of ``HeroFocusDiagnostics`` / ``HomePerfDiagnostics``:
///  - Silent by default; auto-enabled by `PLZHERO_UIKIT_STDOUT=1` (also mirrors to
///    stdout for `devicectl --console`) or `PLZHERO_UIKIT=1` (Console only).
///  - Never blocks, never mutates view state, never logs secrets — only durations,
///    slide indices/ids and HIT/MISS.
///  - `OSLog` guarded so pure-logic builds stay portable.
enum HeroForegroundDiagnostics {
    /// Whether markers are emitted. Enabled by either env var; read once.
    static let isEnabled: Bool =
        ProcessInfo.processInfo.environment["PLZHERO_UIKIT_STDOUT"] == "1" ||
        ProcessInfo.processInfo.environment["PLZHERO_UIKIT"] == "1"

    private static let mirrorsStandardOut: Bool =
        ProcessInfo.processInfo.environment["PLZHERO_UIKIT_STDOUT"] == "1"

    #if canImport(OSLog)
    private static let logger = Logger(subsystem: "com.plozz.app", category: "heroforeground")
    #endif

    private static let start = DispatchTime.now().uptimeNanoseconds

    private static func stamp() -> String {
        let ms = Double(DispatchTime.now().uptimeNanoseconds &- start) / 1_000_000
        return String(format: "t+%.0fms", ms)
    }

    /// Emits one already-built marker line (tagged `PLZHUIFG`, `t+<ms>` stamped).
    /// The line is an `@autoclosure` so formatting is skipped entirely when off.
    static func emit(_ line: @autoclosure () -> String) {
        guard isEnabled else { return }
        let text = "PLZHUIFG \(stamp()) \(line())"
        #if canImport(OSLog)
        logger.notice("\(text, privacy: .public)")
        #endif
        if mirrorsStandardOut {
            try? FileHandle.standardOutput.write(contentsOf: Data((text + "\n").utf8))
        }
    }

    /// Times an imperative renderer operation and emits its duration (ms). Returns
    /// the body's value. Near-free when disabled (still runs the body, but skips
    /// the clock reads and string build).
    @discardableResult
    static func measure<T>(_ label: String, _ body: () -> T) -> T {
        guard isEnabled else { return body() }
        let startNs = DispatchTime.now().uptimeNanoseconds
        let result = body()
        let ms = Double(DispatchTime.now().uptimeNanoseconds &- startNs) / 1_000_000
        emit(String(format: "%@ %.2fms", label, ms))
        return result
    }
}
