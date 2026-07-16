import Foundation
#if canImport(OSLog)
import OSLog
#endif

/// Runtime selection + telemetry for the imperative UIKit hero foreground.
///
/// UIKit is the production default after the on-device A/B showed fewer hitches and
/// no 50ms transition spikes. The complete SwiftUI renderer remains available as a
/// runtime safety fallback with `PLZHERO_UIKIT_FOREGROUND=0`.
enum HeroForegroundConfig {
    /// Read once at startup. UIKit is on unless explicitly disabled with
    /// `PLZHERO_UIKIT_FOREGROUND=0`; `1` remains accepted for existing A/B scripts.
    static let useUIKitForeground: Bool =
        ProcessInfo.processInfo.environment["PLZHERO_UIKIT_FOREGROUND"] != "0"

    /// Independent A/B gate that gives the standard SwiftUI foreground the same
    /// non-sampling flat capsule chrome as the UIKit `clean` style. Default off, so
    /// the production SwiftUI path remains unchanged unless explicitly measured.
    static let useSwiftUIFlatChrome: Bool =
        ProcessInfo.processInfo.environment["PLZHERO_SWIFTUI_FLAT"] == "1"

    /// The idle pill / paging-container background treatment. Chosen because real
    /// Liquid Glass (`UIGlassEffect`) live-re-blurs the moving backdrop **every
    /// transition frame** — the measured 42–49ms hitch we're eliminating. The two
    /// flat styles never sample the backdrop, so both hit the ~17ms/zero-hitch floor;
    /// they differ only in looks, for a live visual A/B:
    ///
    /// * **`clean`** *(default)* — a solid theme-aware semi-transparent capsule with a
    ///   hairline light border. No attempt to mimic glass. Cheapest, calmest.
    /// * **`glassish`** — the same flat capsule plus a subtle top-down highlight
    ///   gradient to fake a glass sheen (still no live sampling, still ~17ms).
    /// * **`glass`** — real live `UIGlassEffect`. Faithful but pays the transition
    ///   hitch; kept only so the regression can be re-measured on demand.
    ///
    /// Select with `PLZHERO_UIKIT_PILLSTYLE=clean|glassish|glass` (default `clean`).
    enum PillStyle: String {
        case clean, glassish, glass
    }

    static let pillStyle: PillStyle = {
        let raw = ProcessInfo.processInfo.environment["PLZHERO_UIKIT_PILLSTYLE"]?
            .lowercased() ?? ""
        return PillStyle(rawValue: raw) ?? .clean
    }()

    /// Convenience: true only for the real live-glass style (drives the shared
    /// `UIVisualEffectView` factory and the dots capsule).
    static var useGlass: Bool { pillStyle == .glass }

    /// Whether the active paging pill runs the live auto-advance **gauge**
    /// (`CADisplayLink` filling the pill across the dwell). Purely cosmetic; costs a
    /// per-frame relayout of one dot. Defaults **on**; `PLZHERO_UIKIT_GAUGE=0`
    /// freezes it to a static full pill so its cost can be isolated.
    static let useGauge: Bool =
        ProcessInfo.processInfo.environment["PLZHERO_UIKIT_GAUGE"] != "0"
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
