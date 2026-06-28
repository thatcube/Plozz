import Foundation

/// The shared keyframe currency that every local-remux keyframe source emits and
/// the C full-VOD planner consumes — so the live-Cues fast-path, an on-disk
/// cache, a background Cluster scan, and a server-provided index all feed ONE
/// planner path (B7's `plozz_remux_set_full_vod_mode` table front-end) instead of
/// diverging.
///
/// Invariants (guaranteed by ``normalized(times:byteOffsets:duration:)`` and
/// assumed by the planner):
///   - `times` is sorted and strictly increasing (no duplicate boundaries).
///   - `times` is ~0-based (the first keyframe is at/after 0; negatives dropped).
///   - `duration` is the title length in seconds and is `>=` the last keyframe
///     time, so the final segment is well-formed.
///   - `byteOffsets`, when present, is exactly parallel to `times` (same count,
///     same order) — the absolute file offset of each keyframe's Cluster. Present
///     for live Cues (the parser knows the byte positions); `nil` for sources
///     that recover times only (persisted cache, time-only scan).
public struct KeyframeTable: Equatable, Sendable {
    /// Title duration in seconds.
    public var duration: Double
    /// Keyframe presentation times in seconds, sorted and strictly increasing.
    public var times: [Double]
    /// Absolute file byte offset of each keyframe's Cluster, parallel to `times`;
    /// `nil` when the source recovered times only.
    public var byteOffsets: [Int64]?

    /// Direct memberwise init. Prefer ``normalized(times:byteOffsets:duration:)``
    /// for raw inputs; this is for callers that already hold normalized values.
    public init(duration: Double, times: [Double], byteOffsets: [Int64]? = nil) {
        self.duration = duration
        self.times = times
        self.byteOffsets = byteOffsets
    }

    public var isEmpty: Bool { times.isEmpty }
    public var count: Int { times.count }
    /// True when byte offsets are available (live-Cues source) so a byte-range
    /// serving path could read one forward range per segment.
    public var hasByteOffsets: Bool { byteOffsets != nil }

    /// Builds a table that satisfies the invariants from arbitrary raw inputs:
    /// drops non-finite/negative times (and their paired offsets), sorts by time,
    /// collapses non-increasing duplicates, and raises `duration` to the last
    /// keyframe when a rounding skew would otherwise leave the tail keyframe past
    /// the declared duration.
    ///
    /// `byteOffsets`, when supplied, must be parallel to `times`; it is carried
    /// through the same filter/sort/dedupe so the pairing is preserved. A
    /// mismatched-length `byteOffsets` is treated as absent (times-only) rather
    /// than risking a misaligned offset.
    public static func normalized(
        times rawTimes: [Double],
        byteOffsets rawOffsets: [Int64]? = nil,
        duration rawDuration: Double
    ) -> KeyframeTable {
        let offsetsUsable = rawOffsets.map { $0.count == rawTimes.count } ?? false
        let paired: [(time: Double, offset: Int64?)] = rawTimes.enumerated().map { idx, time in
            (time, offsetsUsable ? rawOffsets?[idx] : nil)
        }

        let sorted = paired
            .filter { $0.time.isFinite && $0.time >= 0 }
            .sorted { $0.time < $1.time }

        var times: [Double] = []
        var offsets: [Int64] = []
        times.reserveCapacity(sorted.count)
        offsets.reserveCapacity(sorted.count)
        for entry in sorted {
            if let last = times.last, entry.time <= last { continue }
            times.append(entry.time)
            if offsetsUsable, let offset = entry.offset { offsets.append(offset) }
        }

        let lastKeyframe = times.last ?? 0
        let safeDuration = rawDuration.isFinite ? rawDuration : 0
        let resolvedOffsets: [Int64]? = (offsetsUsable && offsets.count == times.count) ? offsets : nil
        return KeyframeTable(
            duration: max(safeDuration, lastKeyframe),
            times: times,
            byteOffsets: resolvedOffsets
        )
    }
}
