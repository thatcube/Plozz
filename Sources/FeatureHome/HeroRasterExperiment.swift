import Foundation

/// The `PLZHERO_RASTER_FOREGROUND` experiment gate and its **secret-safe** perf
/// markers.
///
/// The experiment prepares the hero's non-interactive visual foreground (the
/// description column — logo/title, metadata, overview) as a rasterized snapshot
/// during the auto-advance dwell, then O(1)-swaps that prepared `UIImage` in on a
/// slide transition instead of re-laying-out the live SwiftUI foreground on the
/// transition frame (the measured ~25-40ms / ~1.4-hitch cost). The interactive
/// layer — the single live focus/selection/action overlay, the visible pills, the
/// paging dots and accessibility — stays fully live and unchanged.
///
/// **Default OFF.** When the env var is absent/not `1`, `isEnabled` is `false` and
/// every raster code path is skipped, so the standard hero is behaviourally and
/// visually unchanged.
///
/// ## Markers
/// All markers route through ``HomePerfDiagnostics/emitLine(_:)``, which is itself
/// gated on `PLZPERF_STDOUT=1` and streams over `devicectl --console`, reusing the
/// existing `TRANSITION` marker stream so a capture can line up raster HIT/MISS
/// against each transition. Markers carry only durations, byte counts, generation
/// numbers and a **non-reversible fingerprint hash** — never titles, overviews or
/// item ids — so nothing user-identifying is ever logged.
enum HeroRasterExperiment {
    /// Whether the foreground-raster experiment is enabled. Read once at launch.
    static let isEnabled: Bool =
        ProcessInfo.processInfo.environment["PLZHERO_RASTER_FOREGROUND"] == "1"

    /// A prepared snapshot existed for the fronted slide at the transition frame —
    /// the live foreground layout was skipped this frame.
    static func emitHit(fingerprintHash: Int, generation: Int) {
        guard isEnabled else { return }
        HomePerfDiagnostics.emitLine("RASTER HIT fp=\(fingerprintHash) gen=\(generation)")
    }

    /// No prepared snapshot for the fronted slide (paging outran preparation, or a
    /// fresh/invalidated slide) — the live foreground was rendered as a safe
    /// fallback this frame.
    static func emitMiss(fingerprintHash: Int, generation: Int) {
        guard isEnabled else { return }
        HomePerfDiagnostics.emitLine("RASTER MISS fp=\(fingerprintHash) gen=\(generation)")
    }

    /// One foreground snapshot was prepared during dwell: how long the async
    /// resolve + main-thread `ImageRenderer` render took, and its decoded size.
    static func emitPrepared(fingerprintHash: Int, generation: Int, ms: Double, bytes: Int) {
        guard isEnabled else { return }
        HomePerfDiagnostics.emitLine(
            "RASTER PREPARE fp=\(fingerprintHash) gen=\(generation) ms=\(String(format: "%.1f", ms)) bytes=\(bytes)"
        )
    }

    /// The cache/window footprint after a prepare pass settled: resident snapshots
    /// and their total decoded bytes.
    static func emitCacheState(resident: Int, bytes: Int, budget: Int) {
        guard isEnabled else { return }
        HomePerfDiagnostics.emitLine("RASTER CACHE resident=\(resident) bytes=\(bytes) budget=\(budget)")
    }

    /// The prepared set was invalidated (curated set identity changed, or a theme/
    /// spoiler setting that affects every snapshot flipped) — a MISS burst after
    /// this is expected, not a cache underperforming.
    static func emitInvalidated(generation: Int, dropped: Int, reason: String) {
        guard isEnabled else { return }
        HomePerfDiagnostics.emitLine("RASTER INVALIDATE gen=\(generation) dropped=\(dropped) reason=\(reason)")
    }
}
