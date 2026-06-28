import Foundation

/// An **exact, keyframe-cut full-duration** VOD segment plan built from a
/// trustworthy Matroska **Cues** index.
///
/// ## Why this exists (vs `ProvisionalVODPlan`)
/// `ProvisionalVODPlan` advertises the whole timeline at open but ESTIMATES the
/// tail (fixed-cadence) because discovering every no-Cues keyframe is round-trip
/// bound. For the ~90–95% of real movie MKVs that ship a Cues index, we don't need
/// to estimate at all: `MatroskaKeyframeSampler.readCues()` returns the EXACT
/// `(keyframe PTS, cluster byte-offset)` table for the whole programme in ~2 range
/// requests. This plan groups that exact table into ~`targetSeconds` segments cut
/// on real keyframes, so the published playlist is a true **VOD + `EXT-X-ENDLIST`**
/// (seek-anywhere immediately) with **exact `EXTINF`** — no estimation, and no
/// per-segment refinement needed because every boundary is already a real IDR.
///
/// ## Segmentation contract (mirrors the agreed `buildKeyframeSegmentPlan` rule)
/// Anchored at `startPTS = keyframes[0].seconds`, segment *N* ends at the FIRST
/// keyframe whose `(pts - startPTS) >= (N+1) * targetSeconds`. A single long GOP
/// that crosses several `targetSeconds` multiples collapses to ONE boundary (no
/// empty segments). `EXTINF` for each segment is the real spacing between its
/// boundary keyframes; the final segment runs to the programme `totalDuration`, so
/// `segmentDurations.reduce(0,+) == (totalDuration - startPTS)` within rounding —
/// AVPlayer's seek bar and end-of-stream land correctly.
///
/// Pure value type (no I/O) so the grouping math is unit-tested off plain numbers,
/// independent of network/FFmpeg/AVFoundation. Feed `segmentDurations` straight
/// into `RemuxSegmentPlanner.mediaPlaylist()` to emit the VOD+ENDLIST.
struct CuesVODPlan: Equatable, Sendable {

    /// Full-timeline per-segment durations (seconds), in playback order — all
    /// exact (real keyframe spacing), summing to the programme length.
    let segmentDurations: [Double]

    /// The source cluster byte-offset that begins each segment, aligned 1:1 with
    /// `segmentDurations`. A producer can `avio`-seek straight here, skipping a
    /// forward `av_read_frame` GOP walk.
    let segmentByteOffsets: [Int64]

    /// The first keyframe's PTS (seconds) — the 0-based timeline anchor `startPTS`.
    let startPTS: Double

    /// Builds the exact full-duration plan from a sorted Cues keyframe table.
    ///
    /// - Parameters:
    ///   - keyframes: sorted-by-time `(seconds, clusterOffset)` from `readCues()`.
    ///     Must be non-empty; non-finite/out-of-order points are tolerated (the
    ///     boundary walk only advances on strictly increasing time).
    ///   - totalDuration: programme length (from the container `Info/Duration`).
    ///     `<= startPTS` or non-finite falls back to one `targetSeconds` tail so the
    ///     last segment is never zero/negative.
    ///   - targetSeconds: nominal segment length to group keyframes into (default 4 s).
    init(keyframes: [(seconds: Double, clusterOffset: Int64)],
         totalDuration: Double,
         targetSeconds: Double = 4.0) {
        let target = max(0.5, targetSeconds)
        // Sanitize: keep finite, strictly time-increasing points (Cues are sorted,
        // but guard against duplicate timestamps that would make a 0-length segment).
        var clean: [(seconds: Double, clusterOffset: Int64)] = []
        for kf in keyframes where kf.seconds.isFinite {
            if let last = clean.last, kf.seconds <= last.seconds + 1e-9 { continue }
            clean.append(kf)
        }

        guard let first = clean.first else {
            // Degenerate: no usable keyframes — a single target-length segment at 0
            // so the planner never emits an empty playlist.
            self.startPTS = 0
            self.segmentDurations = [target]
            self.segmentByteOffsets = [0]
            return
        }

        let start = first.seconds
        self.startPTS = start

        // Pick the first keyframe crossing each target multiple as a boundary.
        var boundaries: [Int] = [0]
        var threshold = target
        var k = 1
        while k < clean.count {
            let rel = clean[k].seconds - start
            if rel + 1e-9 >= threshold {
                boundaries.append(k)
                // Advance past every multiple this GOP already crossed so a long GOP
                // produces exactly one boundary, not several empty segments.
                let steps = Int((rel / target).rounded(.down)) + 1
                threshold = Double(steps) * target
            }
            k += 1
        }

        let relTimes = boundaries.map { clean[$0].seconds - start }
        var durations: [Double] = []
        durations.reserveCapacity(boundaries.count)
        for i in 0..<boundaries.count {
            if i < boundaries.count - 1 {
                durations.append(relTimes[i + 1] - relTimes[i])
            } else {
                // Final segment runs to programme end. Fall back to the previous
                // segment's spacing (or target) when duration is missing/short so it
                // is always strictly positive.
                let fallbackSpacing = durations.last ?? target
                let endRel = (totalDuration.isFinite && (totalDuration - start) > relTimes[i] + 1e-6)
                    ? (totalDuration - start)
                    : (relTimes[i] + fallbackSpacing)
                durations.append(endRel - relTimes[i])
            }
        }

        self.segmentDurations = durations
        self.segmentByteOffsets = boundaries.map { clean[$0].clusterOffset }
    }

    /// Total advertised duration (sum of all segment durations) — equals
    /// `totalDuration - startPTS` within rounding by construction.
    var totalDuration: Double { segmentDurations.reduce(0, +) }

    /// Advertised start time (seconds, 0-based) of segment `index`.
    func segmentStartTime(_ index: Int) -> Double {
        guard index > 0 else { return 0 }
        let upper = min(index, segmentDurations.count)
        return segmentDurations[0..<upper].reduce(0, +)
    }
}
