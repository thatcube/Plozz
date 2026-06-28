import Foundation

/// The shared keyframe currency that every local-remux keyframe source emits and
/// the segment planner consumes — so the Cues fast-path, an on-disk cache, a
/// background Cluster scan, and a server-provided index all feed ONE planner path
/// instead of diverging.
///
/// Invariants (guaranteed by ``normalized(times:duration:)`` and assumed by the
/// planner):
///   - `times` is sorted and strictly increasing (no duplicate boundaries).
///   - `times` is ~0-based (the first keyframe is at/after 0; negatives dropped).
///   - `duration` is the title length in seconds and is `>=` the last keyframe
///     time, so the final segment is well-formed.
public struct KeyframeTable: Equatable, Sendable {
    /// Title duration in seconds.
    public var duration: Double
    /// Keyframe presentation times in seconds, sorted and strictly increasing.
    public var times: [Double]

    /// Direct memberwise init. Prefer ``normalized(times:duration:)`` for raw
    /// inputs; this is for callers that already hold normalized values.
    public init(duration: Double, times: [Double]) {
        self.duration = duration
        self.times = times
    }

    public var isEmpty: Bool { times.isEmpty }
    public var count: Int { times.count }

    /// Builds a table that satisfies the invariants from arbitrary raw inputs:
    /// drops non-finite/negative times, sorts, collapses non-increasing
    /// duplicates, and raises `duration` to the last keyframe when a rounding
    /// skew would otherwise leave the tail keyframe past the declared duration.
    public static func normalized(times rawTimes: [Double], duration rawDuration: Double) -> KeyframeTable {
        let sorted = rawTimes
            .filter { $0.isFinite && $0 >= 0 }
            .sorted()

        var strictlyIncreasing: [Double] = []
        strictlyIncreasing.reserveCapacity(sorted.count)
        for time in sorted {
            if let last = strictlyIncreasing.last, time <= last { continue }
            strictlyIncreasing.append(time)
        }

        let lastKeyframe = strictlyIncreasing.last ?? 0
        let safeDuration = rawDuration.isFinite ? rawDuration : 0
        return KeyframeTable(duration: max(safeDuration, lastKeyframe), times: strictlyIncreasing)
    }
}
