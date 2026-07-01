#if canImport(UIKit)
import Foundation
import QuartzCore

/// Lightweight, env-gated probe that measures how SMOOTH a single scrub gesture
/// actually was, so we diagnose choppiness with numbers instead of guesses.
///
/// Enable by launching with `SCRUB_DIAG=1` and capturing stdout via
/// `devicectl device process launch --console` — the same off-device telemetry
/// pattern as `PLZREMUX` / `PLZXFAN` / `PLZBOOT` (os_log isn't readable off a
/// network-paired Apple TV on this toolchain). One `PLZSCRUB scrub-diag:` line
/// is emitted per scrub session (begin → commit/cancel), covering the whole
/// multi-swipe traversal.
///
/// How to read the fields — each isolates one stage of the pipeline:
///  * `frames` / `fps` / `hitches` / `worstFrame` — did the DISPLAY keep up?
///    Hitches with a cheap `handler` cost point at SwiftUI render cost (the
///    overlay re-rendering per sample), not our gesture code.
///  * `samples` / `sampleDt` — did pan input arrive smoothly, or did UIKit
///    coalesce touches (large/irregular `sampleDt`) because the main thread was
///    busy? The Siri Remote samples ~60 Hz, so healthy `sampleDt` ≈ 16 ms.
///  * `handler avg/worst` — how long OUR per-sample work (advance + thumbnail
///    lookup) held the main thread. If this is high, the cost is in our code.
///  * `cache hit/miss` — trickplay readiness. Lots of misses == "fighting the
///    thumbnails until they load" (each miss spawns an async fetch).
@MainActor
final class ScrubDiagnostics {
    /// Gate the whole probe on an env var so it's zero-cost in normal builds.
    static let enabled = ProcessInfo.processInfo.environment["SCRUB_DIAG"] == "1"

    /// **Experimental** gate (`SCRUB_FORCE_60=1`): force the display to 60 Hz
    /// during a scrub for smooth scrubbing on 24/25 fps content, restoring the
    /// content-matched refresh on commit. Seamless on QMS-capable TVs; a brief
    /// HDMI re-sync otherwise — hence opt-in while we evaluate it on real
    /// hardware.
    static let forceScrubRefresh = ProcessInfo.processInfo.environment["SCRUB_FORCE_60"] == "1"

    private var link: CADisplayLink?
    private var startTime: CFTimeInterval = 0

    // Display-frame timing (via CADisplayLink on the main runloop — a late
    // callback is a direct proxy for a visible hitch).
    private var lastFrameTs: CFTimeInterval = 0
    private var frames = 0
    private var hitches = 0
    private var worstFrameMs = 0.0

    // Pan-sample cadence.
    private var samples = 0
    private var lastSampleTs: CFTimeInterval = 0
    private var minSampleDtMs = Double.greatestFiniteMagnitude
    private var maxSampleDtMs = 0.0

    // Per-sample handler cost on the main thread.
    private var totalHandlerMs = 0.0
    private var worstHandlerMs = 0.0

    // Thumbnail readiness.
    private var cacheHits = 0
    private var cacheMisses = 0

    /// Starts a fresh measurement window for one scrub session.
    func begin() {
        guard Self.enabled else { return }
        reset()
        startTime = CACurrentMediaTime()
        let l = CADisplayLink(target: self, selector: #selector(onFrame(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    /// Records one processed pan `.changed` sample: how long our handler took and
    /// whether the preview thumbnail was already in memory.
    func recordSample(handlerMs: Double, cacheHit: Bool) {
        guard Self.enabled, link != nil else { return }
        let now = CACurrentMediaTime()
        if lastSampleTs != 0 {
            let dt = (now - lastSampleTs) * 1000
            minSampleDtMs = min(minSampleDtMs, dt)
            maxSampleDtMs = max(maxSampleDtMs, dt)
        }
        lastSampleTs = now
        samples += 1
        totalHandlerMs += handlerMs
        worstHandlerMs = max(worstHandlerMs, handlerMs)
        if cacheHit { cacheHits += 1 } else { cacheMisses += 1 }
    }

    /// Closes the window and emits the summary line.
    func end(_ reason: String) {
        guard Self.enabled, link != nil else { return }
        link?.invalidate()
        link = nil
        let durMs = (CACurrentMediaTime() - startTime) * 1000
        let fps = durMs > 0 ? Double(frames) / (durMs / 1000) : 0
        let avgHandler = samples > 0 ? totalHandlerMs / Double(samples) : 0
        let minDt = minSampleDtMs == .greatestFiniteMagnitude ? 0 : minSampleDtMs
        let line = String(
            format: "scrub-diag: %@ dur=%.0fms frames=%d fps=%.1f hitches=%d worstFrame=%.1fms "
                + "samples=%d sampleDt[min/max]=%.1f/%.1fms handler[avg/worst]=%.2f/%.2fms cache[hit/miss]=%d/%d",
            reason, durMs, frames, fps, hitches, worstFrameMs,
            samples, minDt, maxSampleDtMs, avgHandler, worstHandlerMs, cacheHits, cacheMisses)
        // Unbuffered write so `devicectl --console` sees the line immediately.
        try? FileHandle.standardOutput.write(contentsOf: Data(("PLZSCRUB " + line + "\n").utf8))
    }

    private func reset() {
        startTime = 0
        lastFrameTs = 0; frames = 0; hitches = 0; worstFrameMs = 0
        samples = 0; lastSampleTs = 0
        minSampleDtMs = .greatestFiniteMagnitude; maxSampleDtMs = 0
        totalHandlerMs = 0; worstHandlerMs = 0
        cacheHits = 0; cacheMisses = 0
    }

    /// One-off stdout note (same `PLZSCRUB` channel as the per-scrub summary), for
    /// tracing things that aren't per-frame — e.g. which engine handled a scrub
    /// and whether the refresh boost actually engaged. No-op unless `SCRUB_DIAG=1`.
    static func note(_ message: String) {
        guard enabled else { return }
        try? FileHandle.standardOutput.write(contentsOf: Data(("PLZSCRUB " + message + "\n").utf8))
    }

    @objc private func onFrame(_ link: CADisplayLink) {
        let now = link.timestamp
        if lastFrameTs != 0 {
            let dtMs = (now - lastFrameTs) * 1000
            // The display's expected per-frame cadence (≈16.6 ms at 60 Hz).
            let expectedMs = (link.targetTimestamp - link.timestamp) * 1000
            frames += 1
            worstFrameMs = max(worstFrameMs, dtMs)
            // A frame that took >1.5× the expected interval is a dropped/late
            // frame the eye reads as a stutter.
            if expectedMs > 0, dtMs > expectedMs * 1.5 { hitches += 1 }
        }
        lastFrameTs = now
    }
}
#endif
