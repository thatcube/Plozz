import Foundation

/// A **full-duration provisional** segment table for the instant-open, full-seek
/// VOD remux path.
///
/// ## Why this exists
/// On-device we proved the growing **EVENT** playlist shape is disqualified:
/// AVPlayer plays it in-sync but **clamps far-seek to the last advertised
/// segment** (a viewer could only skip ~3 min ahead — the discovered frontier).
/// Full-timeline seek is a hard requirement, so the open playlist must advertise
/// the **whole timeline up front** as a VOD list with `EXT-X-ENDLIST`, which lets
/// AVPlayer permit seek-anywhere immediately.
///
/// But discovering every real keyframe boundary at open is too slow on a
/// feature-length 4K no-Cues MKV (it is round-trip-bound regardless of how few
/// bytes each probe reads). So this plan advertises a **provisional** table at
/// open: the segments already discovered exactly (the synchronous prefix) are
/// kept verbatim, and the remainder of the timeline is filled with an
/// estimated fixed-cadence tail derived from the prefix's measured GOP cadence.
/// AVPlayer maps a seek time → segment index via these `EXTINF` durations; the
/// *bytes* served for a touched segment are then snapped to the source's real
/// keyframe (cheaply, per-segment, via `MatroskaKeyframeSampler.keyframeBoundary`)
/// so playback stays in sync even though the advertised boundary was an estimate.
/// A small declared-vs-real seek imprecision is acceptable; A/V *desync* is not,
/// and is avoided because every served segment still starts on a real IDR.
///
/// ## Estimation contract (the part that must be correct)
/// * `segmentDurations.reduce(0,+) == totalDuration` (within `1e-6`) so the
///   advertised timeline length matches the real programme — AVPlayer's seek bar
///   and end-of-stream land in the right place.
/// * The real prefix is preserved byte-for-byte (those segments are already
///   keyframe-exact); only the tail is estimated.
/// * Every duration is `> 0` and the count is deterministic, so the playlist is
///   stable across reloads (AVPlayer may re-fetch a VOD playlist).
///
/// Pure value type (no I/O) so the estimation math is unit-tested off plain
/// numbers, independent of the network, FFmpeg, or AVFoundation.
struct ProvisionalVODPlan: Equatable, Sendable {

    /// Full-timeline per-segment durations (seconds), in playback order:
    /// `realPrefix` verbatim followed by the estimated fixed-cadence tail.
    let segmentDurations: [Double]

    /// Number of leading segments that are real (keyframe-exact) — the rest of
    /// the table is the provisional tail awaiting per-segment refinement.
    let realPrefixCount: Int

    /// The GOP cadence (seconds) used to size the provisional tail — the measured
    /// mean of the real prefix, floored at `targetSeconds`.
    let cadence: Double

    /// Builds the provisional full-duration table.
    ///
    /// - Parameters:
    ///   - totalDuration: the source's real programme duration (seconds).
    ///   - realPrefix: the exact, keyframe-cut segment durations discovered
    ///     synchronously at open (may be empty if nothing was discovered yet).
    ///   - targetSeconds: the nominal segment target (e.g. 6 s); also the floor
    ///     for the estimated cadence so the tail never uses a pathologically
    ///     small GOP estimate that explodes the segment count.
    init(totalDuration: Double, realPrefix: [Double], targetSeconds: Double) {
        let target = max(0.5, targetSeconds)
        // Sanitize the prefix: drop non-positive/non-finite entries that would
        // corrupt the sum or the cadence estimate.
        let prefix = realPrefix.filter { $0.isFinite && $0 > 0 }
        let prefixSum = prefix.reduce(0, +)

        // Cadence = mean real GOP, floored at the target so a few short opening
        // GOPs can't inflate the tail into thousands of tiny segments.
        let estimated = prefix.isEmpty ? target : max(target, prefixSum / Double(prefix.count))
        self.cadence = estimated
        self.realPrefixCount = prefix.count

        let total = (totalDuration.isFinite && totalDuration > 0) ? totalDuration : prefixSum
        let remaining = total - prefixSum

        var durations = prefix
        if remaining > 1e-6 {
            // Whole provisional segments at the estimated cadence, plus a final
            // remainder so the table sums EXACTLY to the real duration.
            let whole = max(0, Int((remaining / estimated).rounded(.down)))
            if whole > 0 {
                durations.append(contentsOf: Array(repeating: estimated, count: whole))
            }
            let tailRemainder = remaining - Double(whole) * estimated
            if tailRemainder > 1e-6 {
                durations.append(tailRemainder)
            } else if whole == 0 {
                // remaining is a sub-cadence sliver — one short tail segment.
                durations.append(remaining)
            }
        } else if durations.isEmpty {
            // Degenerate input (no prefix, no usable duration): a single segment
            // so the planner never emits an empty playlist.
            durations.append(target)
        }

        self.segmentDurations = durations
    }

    /// Total advertised duration (sum of all segment durations) — equals the real
    /// `totalDuration` within rounding by construction.
    var totalDuration: Double { segmentDurations.reduce(0, +) }

    /// The advertised start time (seconds) of segment `index` — the running sum of
    /// all earlier segment durations. This is the time AVPlayer associates with
    /// the segment, and the input to per-segment real-keyframe resolution.
    func segmentStartTime(_ index: Int) -> Double {
        guard index > 0 else { return 0 }
        let upper = min(index, segmentDurations.count)
        return segmentDurations[0..<upper].reduce(0, +)
    }

    /// A constant `EXT-X-TARGETDURATION` (seconds, integer) that is `>=` every
    /// segment for the whole title — required by HLS to be fixed for the playlist.
    /// Sized off the longest advertised segment with a small margin so a real GOP
    /// that lands a little longer than its estimate can't violate the ceiling.
    var targetDurationCeiling: Int {
        let longest = segmentDurations.max() ?? cadence
        return max(1, Int(longest.rounded(.up)) + 1)
    }
}
