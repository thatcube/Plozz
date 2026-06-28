import Foundation

/// Pure-logic CORRECTNESS ORACLE for keyframe-aligned remux segmentation.
///
/// The remux→AVPlayer pipeline is only A/V-correct when every segment boundary it
/// emits lands on a **real source keyframe** and the segment timeline is
/// **continuous** — each segment's decode time picks up exactly where the previous
/// one ended (a continuous `tfdt`). Two failure modes this oracle exists to catch:
///
///  * A boundary that falls *mid-GOP* forces the muxer's backward-seek-to-keyframe
///    snap to either duplicate a GOP (overlap → the A/V desync we chase) or makes
///    the player decode from a non-IDR frame (stutter/corruption). The historical
///    overlap bug was exactly fixed-cadence boundaries (6/12/18s) snapping back to
///    a shared earlier keyframe.
///  * Segment durations that don't tile the media duration leave a gap/overlap in
///    the timeline → cumulative PTS drift.
///
/// This is the cross-track VERIFICATION HARNESS: it validates, as pure logic with
/// no device and no I/O, that
///   (a) a keyframe TABLE (Cues-derived or probe-derived) is itself well-formed
///       and PTS-correct (`validateTable`), and
///   (b) an emitted segment-cut plan lands every boundary on a real keyframe with a
///       continuous, gapless, non-overlapping timeline (`validateCutTimes` /
///       `validateSegmentPlan`).
///
/// It is **producer-agnostic**: the SAME contract validates B5's Cues `readCues()`
/// table and B6's no-Cues probe table, so a disagreement localises the bug to one
/// producer rather than the muxer. `tablesAgree` / `boundariesAgree` provide the
/// differential cross-check between two independent producers (e.g. the Swift
/// `keyframeBoundary` resolver vs the C `kf_probe_at`).
///
/// The oracle is never wired into the playback path — it carries no behaviour and
/// is exercised only by tests and (optionally, zero-cost) diagnostic assertions.
enum KeyframeCutOracle {

    /// A single contract violation, carrying a human-readable reason suitable for
    /// `--console` log capture so a failed cut is self-describing.
    struct Violation: Equatable, CustomStringConvertible {
        enum Kind: Equatable {
            case emptyTable            // a table with no keyframes
            case nonFiniteValue        // NaN / ±inf in a table or plan
            case negativeTime          // a keyframe/boundary time < 0
            case nonMonotonicTable     // table not strictly increasing
            case timeExceedsDuration   // a keyframe time past the media duration
            case nonPositiveDuration   // media duration <= 0
            case nonPositiveSegment    // an emitted segment with duration <= 0
            case cutOffKeyframe        // a cut boundary not on any real keyframe
            case firstCutNotAtAnchor   // first boundary not at the first keyframe
            case timelineGap           // boundaries don't tile [anchor, duration]
        }
        let kind: Kind
        /// Table/segment index the violation refers to, or -1 when not positional.
        let index: Int
        /// The offending value (seconds), or 0 when not applicable.
        let value: Double
        let detail: String

        var description: String { "[\(kind)] idx=\(index) value=\(value) — \(detail)" }
    }

    /// Default PTS comparison tolerance (seconds). Source PTS round-trips through
    /// the container timecode scale, so a boundary that matches a keyframe to within
    /// this tolerance is treated as ON the keyframe.
    static let defaultTolerance: Double = 1e-3

    // MARK: - (a) Keyframe table well-formedness

    /// Validates that `times` is a well-formed keyframe table for a source of
    /// `duration` seconds: non-empty, all finite, non-negative, strictly increasing,
    /// and bounded by the duration (within `tolerance`). Returns every violation
    /// found (empty array == the table is PTS-correct).
    static func validateTable(times: [Double],
                              duration: Double,
                              tolerance: Double = defaultTolerance) -> [Violation] {
        var out: [Violation] = []

        if !duration.isFinite {
            out.append(.init(kind: .nonFiniteValue, index: -1, value: duration,
                             detail: "media duration is not finite"))
        } else if duration <= 0 {
            out.append(.init(kind: .nonPositiveDuration, index: -1, value: duration,
                             detail: "media duration must be > 0"))
        }

        if times.isEmpty {
            out.append(.init(kind: .emptyTable, index: -1, value: 0,
                             detail: "keyframe table is empty"))
            return out
        }

        var prev = -Double.greatestFiniteMagnitude
        for (i, t) in times.enumerated() {
            if !t.isFinite {
                out.append(.init(kind: .nonFiniteValue, index: i, value: t,
                                 detail: "keyframe time is not finite"))
                continue
            }
            if t < 0 {
                out.append(.init(kind: .negativeTime, index: i, value: t,
                                 detail: "keyframe time is negative"))
            }
            if t <= prev + tolerance && i > 0 {
                out.append(.init(kind: .nonMonotonicTable, index: i, value: t,
                                 detail: "keyframe time not strictly greater than previous (\(prev))"))
            }
            if duration.isFinite && duration > 0 && t > duration + tolerance {
                out.append(.init(kind: .timeExceedsDuration, index: i, value: t,
                                 detail: "keyframe time exceeds media duration (\(duration))"))
            }
            prev = t
        }
        return out
    }

    // MARK: - (b) Cut-plan correctness

    /// Validates an emitted set of absolute cut BOUNDARY TIMES against the real
    /// keyframe table. `boundaries` is the planner shape `[anchor, c1, c2, …, end]`:
    /// the segment START times followed by the final segment END.
    ///
    /// Contract enforced:
    ///  * boundaries finite, non-negative, strictly increasing (every segment > 0);
    ///  * the FIRST boundary equals the first keyframe (the anchor / `startPTS`);
    ///  * every INTERIOR boundary (a segment start) lands on a real keyframe — the
    ///    property that makes the muxer's backward snap a no-op and prevents the GOP
    ///    duplication / mid-GOP decode that desyncs A/V;
    ///  * the LAST boundary tiles to the media `duration` (continuous, gapless,
    ///    non-overlapping timeline). The final boundary need NOT be a keyframe — a
    ///    title rarely ends exactly on one.
    static func validateCutTimes(_ boundaries: [Double],
                                 keyframeTimes: [Double],
                                 duration: Double,
                                 tolerance: Double = defaultTolerance) -> [Violation] {
        var out: [Violation] = []

        guard boundaries.count >= 2 else {
            out.append(.init(kind: .nonPositiveSegment, index: -1, value: 0,
                             detail: "a cut plan needs at least a start and an end (>= 2 boundaries)"))
            return out
        }

        // Finite + strictly increasing (each segment has positive duration).
        var prev = -Double.greatestFiniteMagnitude
        for (i, b) in boundaries.enumerated() {
            if !b.isFinite {
                out.append(.init(kind: .nonFiniteValue, index: i, value: b,
                                 detail: "boundary is not finite"))
                continue
            }
            if b < 0 {
                out.append(.init(kind: .negativeTime, index: i, value: b,
                                 detail: "boundary is negative"))
            }
            if i > 0 && b <= prev + tolerance {
                out.append(.init(kind: .nonPositiveSegment, index: i, value: b - prev,
                                 detail: "segment \(i - 1) has non-positive duration (boundary \(b) <= previous \(prev))"))
            }
            prev = b
        }

        // First boundary must be the anchor keyframe.
        if let anchor = keyframeTimes.first, let first = boundaries.first,
           abs(first - anchor) > tolerance {
            out.append(.init(kind: .firstCutNotAtAnchor, index: 0, value: first,
                             detail: "first boundary \(first) is not the first keyframe / anchor (\(anchor))"))
        }

        // Every interior boundary (segment START) must land on a real keyframe.
        if !keyframeTimes.isEmpty {
            for i in 0..<(boundaries.count - 1) {
                let b = boundaries[i]
                guard b.isFinite else { continue }
                if !isOnKeyframe(b, in: keyframeTimes, tolerance: tolerance) {
                    out.append(.init(kind: .cutOffKeyframe, index: i, value: b,
                                     detail: "segment start \(b) does not land on a real keyframe (mid-GOP cut)"))
                }
            }
        }

        // Final boundary tiles to the media duration (continuous timeline).
        if duration.isFinite && duration > 0, let last = boundaries.last, last.isFinite,
           abs(last - duration) > tolerance {
            out.append(.init(kind: .timelineGap, index: boundaries.count - 1, value: last,
                             detail: "last boundary \(last) does not reach media duration \(duration) — timeline gap/overlap"))
        }

        return out
    }

    /// Validates a planner segment-duration table (the `[Double]` shape consumed by
    /// `RemuxSegmentPlanner`) by expanding it to absolute boundaries anchored at
    /// `startPTS`, then applying `validateCutTimes`. This is the exact shape
    /// `cuesVODPlan()` / the no-Cues plan emit, so the oracle validates the real
    /// producer output without re-deriving it.
    static func validateSegmentPlan(segmentDurations: [Double],
                                    startPTS: Double,
                                    keyframeTimes: [Double],
                                    duration: Double,
                                    tolerance: Double = defaultTolerance) -> [Violation] {
        guard !segmentDurations.isEmpty else {
            return [.init(kind: .nonPositiveSegment, index: -1, value: 0,
                          detail: "segment-duration table is empty")]
        }
        var boundaries: [Double] = [startPTS]
        boundaries.reserveCapacity(segmentDurations.count + 1)
        var acc = startPTS
        for d in segmentDurations {
            acc += d
            boundaries.append(acc)
        }
        return validateCutTimes(boundaries, keyframeTimes: keyframeTimes,
                                duration: duration, tolerance: tolerance)
    }

    // MARK: - Differential cross-check between two independent producers

    /// True iff every keyframe in `a` has a counterpart in `b` within `tolerance`
    /// and the two tables have the same count — the differential oracle for two
    /// INDEPENDENT full-table producers (e.g. B5's Cues table vs a probe-built full
    /// table). A mismatch localises a parser bug to one producer.
    static func tablesAgree(_ a: [Double], _ b: [Double],
                            tolerance: Double = defaultTolerance) -> Bool {
        guard a.count == b.count else { return false }
        for (x, y) in zip(a, b) where abs(x - y) > tolerance { return false }
        return true
    }

    /// True iff two independent at-or-before resolvers agree on the boundary for the
    /// same target T (the Swift `keyframeBoundary` / `cueAtOrBefore` vs the C
    /// `kf_probe_at`). Disagreement beyond `tolerance` is a resolver bug in one side.
    static func boundariesAgree(_ a: Double, _ b: Double,
                                tolerance: Double = defaultTolerance) -> Bool {
        a.isFinite && b.isFinite && abs(a - b) <= tolerance
    }

    // MARK: - Helpers

    /// O(log n) membership test: does `t` coincide (within `tolerance`) with any
    /// entry of the ascending-sorted `sortedTimes`?
    static func isOnKeyframe(_ t: Double, in sortedTimes: [Double],
                             tolerance: Double = defaultTolerance) -> Bool {
        guard !sortedTimes.isEmpty else { return false }
        var lo = 0, hi = sortedTimes.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let v = sortedTimes[mid]
            if abs(v - t) <= tolerance { return true }
            if v < t { lo = mid + 1 } else { hi = mid - 1 }
        }
        return false
    }
}
