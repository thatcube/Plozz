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
    public static func startSampler(interval: TimeInterval = 2, label: String) -> Task<Void, Never>? {
        guard isEnabled else { return nil }
        return Task.detached(priority: .utility) {
            let start = Date()
            var tick = 0
            while !Task.isCancelled {
                let mem = PlaybackInstrumentation.memoryFootprintBytes().map { Double($0) / (1024 * 1024) } ?? -1
                let vms = PlaybackInstrumentation.count(.viewModel)
                let eng = PlaybackInstrumentation.count(.nativeEngine)
                let share = ShareBackgroundActivity.snapshot()
                emit(String(
                    format: "sample %@ t=%.0fs mem=%.1fMB vms=%d nativeEng=%d smbScan=%d smbEnrich=%d",
                    label, Date().timeIntervalSince(start), mem, vms, eng, share.scans, share.enrichPasses
                ))
                tick += 1
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }
}

/// Process-wide counters for **SMB background passes** (scan + enrichment), so the
/// browse sampler can correlate scroll/navigation choppiness with an active
/// catalog pass grinding on the cooperative pool. Incremented around each pass in
/// `ProviderShare`; read via `snapshot()`. Cheap atomic-ish counters under a lock.
public enum ShareBackgroundActivity {
    public struct Snapshot: Sendable { public let scans: Int; public let enrichPasses: Int }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var activeScans = 0
    nonisolated(unsafe) private static var activeEnrichPasses = 0

    public static func scanStarted() { lock.lock(); activeScans += 1; lock.unlock() }
    public static func scanFinished() { lock.lock(); activeScans = max(0, activeScans - 1); lock.unlock() }
    public static func enrichStarted() { lock.lock(); activeEnrichPasses += 1; lock.unlock() }
    public static func enrichFinished() { lock.lock(); activeEnrichPasses = max(0, activeEnrichPasses - 1); lock.unlock() }

    public static func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(scans: activeScans, enrichPasses: activeEnrichPasses)
    }
}
