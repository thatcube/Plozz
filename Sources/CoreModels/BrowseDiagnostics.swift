import Foundation
#if canImport(OSLog)
import OSLog
#endif

private final class BrowseDiagnosticsFileSink: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: FileHandle?

    init(enabled: Bool) {
        guard enabled,
              let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return
        }
        let url = caches.appendingPathComponent("plzxmem.log")
        try? FileManager.default.removeItem(at: url)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { return }
        handle = try? FileHandle(forWritingTo: url)
    }

    deinit {
        try? handle?.close()
    }

    func write(_ data: Data) {
        lock.withLock {
            try? handle?.write(contentsOf: data)
        }
    }
}

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
    private static let fileSink = BrowseDiagnosticsFileSink(enabled: isEnabled)

    /// Emits one already-formatted telemetry line (the `PLZXMEM ` prefix is added).
    /// No-op when disabled.
    public static func emit(_ line: String) {
        guard isEnabled else { return }
        #if canImport(OSLog)
        logger.notice("PLZXMEM \(line, privacy: .public)")
        #endif
        let data = Data(("PLZXMEM " + line + "\n").utf8)
        try? FileHandle.standardOutput.write(contentsOf: data)
        fileSink.write(data)
    }

    private static let eventClockFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    /// Emits a timestamped, self-describing `event` line so the log records the
    /// full timeline WITHOUT the tester narrating: screen changes ("screen
    /// Home"), scan lifecycle ("scan+ id=… active=…"), etc. The current live
    /// scan/lister counts are appended so any event can be read in context.
    /// No-op when disabled.
    public static func event(_ what: String) {
        guard isEnabled else { return }
        let s = ShareBackgroundActivity.snapshot()
        emit(String(
            format: "event %@ %@ | scans=%d listers=%d enrich=%d",
            eventClockFmt.string(from: Date()), what, s.scans, s.activeListers, s.enrichPasses
        ))
    }

    /// Runs a fixed-interval sampler until the returned task is cancelled (call
    /// `.cancel()` in the browse view's `onDisappear`). No-op — returns `nil` —
    /// when disabled, so callers add nothing when the flag is off.
    ///
    /// `artworkCacheStats` (optional) lets a caller with access to CoreUI's decoded
    /// and response-byte caches report their live usage.
    public static func startSampler(
        interval: TimeInterval = 2,
        label: String,
        artworkCacheStats: (@Sendable () -> (
            count: Int,
            decodedMB: Double,
            responseMemoryMB: Double,
            responseDiskMB: Double
        ))? = nil
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
                let artStr = art.map {
                    String(
                        format: " artCount=%d artDecodedMB=%.1f artResponseMemMB=%.1f artResponseDiskMB=%.1f",
                        $0.count, $0.decodedMB, $0.responseMemoryMB, $0.responseDiskMB
                    )
                } ?? ""
                emit(String(
                    format: "sample %@ t=%.0fs mem=%.1fMB vms=%d nativeEng=%d shareScan=%d listers=%d peakListers=%d shareEnrich=%d artAssocPasses=%d artAssocRows=%d artAssocMaxRows=%d%@",
                    label, Date().timeIntervalSince(start), mem, vms, eng,
                    share.scans, share.activeListers, share.peakListers, share.enrichPasses,
                    share.artworkAssociationPasses, share.artworkAssociationAssetRows,
                    share.maximumArtworkAssociationRowsPerPass, artStr
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
            let clockFmt = DateFormatter()
            clockFmt.dateFormat = "HH:mm:ss"
            var windowStart = DispatchTime.now()
            // Per-5s-window accumulators, so each summary line is self-describing
            // (idle vs. interacting phases can be told apart purely from the log).
            var samples = 0
            var sumHopMs = 0.0
            var maxHopMs = 0.0
            var n50 = 0, n100 = 0, n250 = 0   // hop-latency distribution buckets
            var scanActiveSamples = 0          // samples taken while a scan was live
            var maxListers = 0                 // peak concurrent listings this window
            while !Task.isCancelled {
                let t0 = DispatchTime.now()
                // Time from t0 (off-main) until this closure actually runs ON main
                // = how long the main thread made us wait.
                let hopMs: Double = await MainActor.run {
                    Double(DispatchTime.now().uptimeNanoseconds &- t0.uptimeNanoseconds) / 1_000_000
                }
                let s = ShareBackgroundActivity.snapshot()
                samples += 1
                sumHopMs += hopMs
                if hopMs > maxHopMs { maxHopMs = hopMs }
                if hopMs >= 50 { n50 += 1 }
                if hopMs >= 100 { n100 += 1 }
                if hopMs >= 250 { n250 += 1 }
                if s.scans > 0 { scanActiveSamples += 1 }
                if s.activeListers > maxListers { maxListers = s.activeListers }
                if hopMs >= hitchThresholdMs {
                    emit(String(
                        format: "hitch %@ mainHop=%.0fms shareScan=%d listers=%d shareEnrich=%d",
                        clockFmt.string(from: Date()), hopMs, s.scans, s.activeListers, s.enrichPasses
                    ))
                }
                let windowMs = Double(DispatchTime.now().uptimeNanoseconds &- windowStart.uptimeNanoseconds) / 1_000_000
                if windowMs >= 5_000 {
                    let avg = samples > 0 ? sumHopMs / Double(samples) : 0
                    let scanPct = samples > 0 ? (scanActiveSamples * 100 / samples) : 0
                    emit(String(
                        format: "window %@ 5s samples=%d avgHop=%.0fms maxHop=%.0fms n50=%d n100=%d n250=%d scanActive=%d%% maxListers=%d",
                        clockFmt.string(from: Date()), samples, avg, maxHopMs, n50, n100, n250, scanPct, maxListers
                    ))
                    samples = 0; sumHopMs = 0; maxHopMs = 0
                    n50 = 0; n100 = 0; n250 = 0
                    scanActiveSamples = 0; maxListers = 0
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
        public let artworkAssociationPasses: Int
        public let artworkAssociationAssetRows: Int
        public let maximumArtworkAssociationRowsPerPass: Int
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var activeScans = 0
    nonisolated(unsafe) private static var activeEnrichPasses = 0
    nonisolated(unsafe) private static var activeListers = 0
    nonisolated(unsafe) private static var peakListers = 0
    nonisolated(unsafe) private static var artworkAssociationPasses = 0
    nonisolated(unsafe) private static var artworkAssociationAssetRows = 0
    nonisolated(unsafe) private static var maximumArtworkAssociationRowsPerPass = 0

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

    public static func artworkAssociationMaterialized(assetRows: Int) {
        lock.lock()
        artworkAssociationPasses += 1
        artworkAssociationAssetRows += assetRows
        maximumArtworkAssociationRowsPerPass = max(maximumArtworkAssociationRowsPerPass, assetRows)
        lock.unlock()
    }

    public static func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(
            scans: activeScans,
            enrichPasses: activeEnrichPasses,
            activeListers: activeListers,
            peakListers: peakListers,
            artworkAssociationPasses: artworkAssociationPasses,
            artworkAssociationAssetRows: artworkAssociationAssetRows,
            maximumArtworkAssociationRowsPerPass: maximumArtworkAssociationRowsPerPass
        )
    }
}
