import Foundation
#if canImport(OSLog)
import OSLog
#endif

/// On-device **library-browse performance** telemetry. Samples process memory,
/// live playback-object counts, and SMB background scan/enrichment activity on a
/// fixed interval while a browse grid is on screen, so scroll/navigation
/// choppiness that only manifests on real hardware (and only against SMB shares)
/// can be attributed to a *cause* — a climbing memory footprint (leak / pressure),
/// a running background pass (CPU/pool starvation), or neither (pure render cost).
///
/// Every line is tagged `PLZXMEM` under subsystem `com.plozz.app`, category
/// `browse`. Search `PLZXMEM` in Console.app, or launch with `PLZXMEM=1` in the
/// environment (via `DEVICECTL_CHILD_PLZXMEM=1 devicectl device process launch
/// --console`) to mirror each line to stdout for a live off-device stream.
///
/// Design constraints (must hold):
///  - **Free when off.** Gated by `PLZXMEM=1`; the sampler task early-returns and
///    never starts when the flag is absent, so shipped/normal runs stay silent.
///  - **Never blocks UI.** Sampling is a cheap Mach `task_info` read plus counter
///    loads on a detached timer; nothing feeds back into rendering.
///  - **Secret-safe.** Only counts, byte totals, and timings — never URLs/tokens.
///  - **Linux-safe.** `OSLog` is guarded so pure logic modules still compile on CI.
public enum BrowseDiagnostics {
    /// Whether browse telemetry is emitted (opt-in via `PLZXMEM=1`).
    public static let isEnabled: Bool =
        ProcessInfo.processInfo.environment["PLZXMEM"] == "1"

    #if canImport(OSLog)
    private static let logger = Logger(subsystem: "com.plozz.app", category: "browse")
    #endif

    /// Emits one already-formatted telemetry line (the `PLZXMEM ` prefix is added).
    /// No-op when disabled.
    public static func emit(_ line: String) {
        guard isEnabled else { return }
        #if canImport(OSLog)
        logger.notice("PLZXMEM \(line, privacy: .public)")
        #endif
        try? FileHandle.standardOutput.write(contentsOf: Data(("PLZXMEM " + line + "\n").utf8))
    }

    /// Runs a fixed-interval sampler until the returned task is cancelled (call
    /// `.cancel()` in the browse view's `onDisappear`). No-op — returns `nil` —
    /// when disabled, so callers add nothing when the flag is off.
    ///
    /// `artworkCacheStats` (optional) lets a caller with access to the decoded
    /// image cache (which lives above this module) report its live count + cost so
    /// a memory climb can be attributed to the cache vs. render surfaces / view
    /// backing stores — the two have different fixes.
    public static func startSampler(
        interval: TimeInterval = 2,
        label: String,
        artworkCacheStats: (@Sendable () -> (count: Int, costMB: Double))? = nil
    ) -> Task<Void, Never>? {
        guard isEnabled else { return nil }
        return Task.detached(priority: .utility) {
            let start = Date()
            var tick = 0
            while !Task.isCancelled {
                let mem = PlaybackInstrumentation.memoryFootprintBytes().map { Double($0) / (1024 * 1024) } ?? -1
                let vms = PlaybackInstrumentation.count(.viewModel)
                let eng = PlaybackInstrumentation.count(.nativeEngine)
                let share = ShareBackgroundActivity.snapshot()
                let art = artworkCacheStats?()
                let artStr = art.map { String(format: " artCount=%d artMB=%.1f", $0.count, $0.costMB) } ?? ""
                emit(String(
                    format: "sample %@ t=%.0fs mem=%.1fMB vms=%d nativeEng=%d shareScan=%d listers=%d peakListers=%d shareEnrich=%d%@",
                    label, Date().timeIntervalSince(start), mem, vms, eng,
                    share.scans, share.activeListers, share.peakListers, share.enrichPasses, artStr
                ))
                tick += 1
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    /// Continuously measures how long it takes to hop onto the **main actor** from
    /// a background task — a direct proxy for main-thread busyness. When the main
    /// thread is idle the hop is ~instant; when it's jammed (SwiftUI diffing under
    /// CPU contention from a background scan) the hop stalls, which is exactly the
    /// "the interface lags while shares scan" symptom.
    ///
    /// Emits a `hitch` line whenever a single hop exceeds `hitchThresholdMs`
    /// (annotated with the live scan/lister counts so a stall can be pinned on an
    /// active pass), plus a rolling `mainhop` max/hitch summary every 5s. Runs for
    /// the app lifetime; gated by `PLZXMEM=1` so shipped runs never start it.
    public static func startMainThreadHitchProbe(
        sampleInterval: TimeInterval = 0.1,
        hitchThresholdMs: Double = 100
    ) -> Task<Void, Never>? {
        guard isEnabled else { return nil }
        return Task.detached(priority: .utility) {
            var windowStart = DispatchTime.now()
            var maxHopMs = 0.0
            var hitches = 0
            while !Task.isCancelled {
                let t0 = DispatchTime.now()
                // Time from t0 (off-main) until this closure actually runs ON main
                // = how long the main thread made us wait.
                let hopMs: Double = await MainActor.run {
                    Double(DispatchTime.now().uptimeNanoseconds &- t0.uptimeNanoseconds) / 1_000_000
                }
                if hopMs > maxHopMs { maxHopMs = hopMs }
                if hopMs >= hitchThresholdMs {
                    hitches += 1
                    let s = ShareBackgroundActivity.snapshot()
                    emit(String(
                        format: "hitch mainHop=%.0fms shareScan=%d listers=%d peakListers=%d shareEnrich=%d",
                        hopMs, s.scans, s.activeListers, s.peakListers, s.enrichPasses
                    ))
                }
                let windowMs = Double(DispatchTime.now().uptimeNanoseconds &- windowStart.uptimeNanoseconds) / 1_000_000
                if windowMs >= 5_000 {
                    emit(String(format: "mainhop window=5s maxHop=%.0fms hitches=%d", maxHopMs, hitches))
                    maxHopMs = 0
                    hitches = 0
                    windowStart = DispatchTime.now()
                }
                try? await Task.sleep(nanoseconds: UInt64(sampleInterval * 1_000_000_000))
            }
        }
    }
}

/// Process-wide counters for **SMB background passes** (scan + enrichment), so the
/// browse sampler can correlate scroll/navigation choppiness with an active
/// catalog pass grinding on the cooperative pool. Incremented around each pass in
/// `ProviderShare`; read via `snapshot()`. Cheap atomic-ish counters under a lock.
public enum ShareBackgroundActivity {
    public struct Snapshot: Sendable {
        public let scans: Int
        public let enrichPasses: Int
        /// Directory listings in flight right now, across ALL shares.
        public let activeListers: Int
        /// High-watermark of concurrent listings since launch — reveals the true
        /// scan parallelism (e.g. 2 shares × 4-wide pools peaking near 8).
        public let peakListers: Int
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var activeScans = 0
    nonisolated(unsafe) private static var activeEnrichPasses = 0
    nonisolated(unsafe) private static var activeListers = 0
    nonisolated(unsafe) private static var peakListers = 0

    public static func scanStarted() { lock.lock(); activeScans += 1; lock.unlock() }
    public static func scanFinished() { lock.lock(); activeScans = max(0, activeScans - 1); lock.unlock() }
    public static func enrichStarted() { lock.lock(); activeEnrichPasses += 1; lock.unlock() }
    public static func enrichFinished() { lock.lock(); activeEnrichPasses = max(0, activeEnrichPasses - 1); lock.unlock() }

    /// Bracket one directory listing (across any share) so the diagnostics can
    /// report live + peak concurrent listings. Cheap; safe to call unconditionally.
    public static func listStarted() {
        lock.lock()
        activeListers += 1
        peakListers = max(peakListers, activeListers)
        lock.unlock()
    }
    public static func listFinished() { lock.lock(); activeListers = max(0, activeListers - 1); lock.unlock() }

    public static func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(
            scans: activeScans,
            enrichPasses: activeEnrichPasses,
            activeListers: activeListers,
            peakListers: peakListers
        )
    }
}
