import Foundation
#if canImport(OSLog)
import OSLog
#endif

/// On-device **Home / hero performance** instrumentation. Two jobs:
///
///  1. **Instruments signposts.** Wraps the two heaviest async Home operations —
///     hero *curation* and *artwork resolution* — in `OSSignposter` intervals under
///     subsystem `com.plozz.app`, category `homeperf`. Attach Instruments to the
///     Apple TV (os_signpost + Time Profiler + Animation Hitches templates) to see
///     exactly where time goes on real, older hardware.
///  2. **Live timing store.** Records the most recent curate/artwork durations so
///     the on-device ``HomePerfOverlay`` HUD can show them without its own probes.
///
/// Design constraints (same as ``HeroFocusDiagnostics``):
///  - **Cheap.** Signpost begin/end are near-free when Instruments isn't recording;
///    the timing store is a single lock + two doubles. Nothing here mutates view
///    state or touches focus/paging.
///  - **Secret-safe.** Only durations are recorded — never titles, ids, tokens.
///  - **Linux-safe.** `OSLog` is guarded so pure logic modules still compile off
///    Apple toolchains.
public enum HomePerfDiagnostics {
    #if canImport(OSLog)
    private static let signposter = OSSignposter(
        subsystem: "com.plozz.app",
        category: "homeperf"
    )
    private static let logger = Logger(subsystem: "com.plozz.app", category: "homeperf")
    #endif

    private static let store = Store()

    /// When the process is launched with `PLZPERF_STDOUT=1`, the sampler mirrors a
    /// compact perf line to stdout each tick so `devicectl device process launch
    /// --console` can stream it off the (wireless) Apple TV — the only way to read
    /// on-device performance remotely on this toolchain, since the unified log can't
    /// be read over the network here. Off by default; read once at startup.
    public static let isStdoutMirrorEnabled: Bool =
        ProcessInfo.processInfo.environment["PLZPERF_STDOUT"] == "1"

    /// Monotonic clock start so each streamed line carries a relative `t+<ms>` stamp.
    private static let start = DispatchTime.now().uptimeNanoseconds

    /// Emits one perf line (tagged `PLZPERF`, with a `t+<ms>` stamp) to the unified
    /// log and — when the mirror is on — unbuffered stdout for live `--console`
    /// capture. No-op when the mirror is disabled; the line is an `@autoclosure` so
    /// the formatting cost is skipped entirely on shipped runs.
    public static func emitLine(_ line: @autoclosure () -> String) {
        guard isStdoutMirrorEnabled else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let stamp = String(format: "t+%.0fms", Double(now &- start) / 1_000_000)
        let text = "PLZPERF \(stamp) \(line())"
        #if canImport(OSLog)
        logger.notice("\(text, privacy: .public)")
        #endif
        try? FileHandle.standardOutput.write(contentsOf: Data((text + "\n").utf8))
    }

    /// Milliseconds the most recent hero curation took, or `nil` if none yet.
    public static var lastCurateMs: Double? { store.lastCurateMs }
    /// Milliseconds the most recent visible-slide artwork resolve took.
    public static var lastArtworkMs: Double? { store.lastArtworkMs }

    /// Times a hero curation: emits an Instruments signpost interval and records the
    /// elapsed milliseconds for the HUD. Non-throwing (curation returns a value).
    public static func measureCurate<T>(_ body: () async -> T) async -> T {
        #if canImport(OSLog)
        let interval = signposter.beginInterval("HomeHero.curate")
        #endif
        let startNs = DispatchTime.now().uptimeNanoseconds
        let result = await body()
        store.recordCurate(elapsedMs(since: startNs))
        #if canImport(OSLog)
        signposter.endInterval("HomeHero.curate", interval)
        #endif
        return result
    }

    /// Times a visible-slide artwork resolve: signpost interval + HUD timing.
    public static func measureArtwork<T>(_ body: () async -> T) async -> T {
        #if canImport(OSLog)
        let interval = signposter.beginInterval("HomeHero.artwork")
        #endif
        let startNs = DispatchTime.now().uptimeNanoseconds
        let result = await body()
        store.recordArtwork(elapsedMs(since: startNs))
        #if canImport(OSLog)
        signposter.endInterval("HomeHero.artwork", interval)
        #endif
        return result
    }

    private static func elapsedMs(since startNs: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds &- startNs) / 1_000_000
    }

    /// Thread-safe latest-durations holder (strict-concurrency safe, like
    /// ``HeroFocusDiagnostics``'s gate).
    private final class Store: @unchecked Sendable {
        private let lock = NSLock()
        private var _lastCurateMs: Double?
        private var _lastArtworkMs: Double?

        var lastCurateMs: Double? { lock.lock(); defer { lock.unlock() }; return _lastCurateMs }
        var lastArtworkMs: Double? { lock.lock(); defer { lock.unlock() }; return _lastArtworkMs }

        func recordCurate(_ ms: Double) { lock.lock(); _lastCurateMs = ms; lock.unlock() }
        func recordArtwork(_ ms: Double) { lock.lock(); _lastArtworkMs = ms; lock.unlock() }
    }
}
