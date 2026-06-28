import Foundation

/// One planned HLS media segment: a keyframe-aligned slice of the title's
/// timeline plus the byte window of the source MKV that backs it.
///
/// `byteStart`/`byteEnd` describe the Cluster byte range (absolute file offsets)
/// that the on-demand remuxer range-reads to produce this segment — the basis of
/// the "single range read per segment" design.
public struct RemuxSegmentPlan: Equatable, Sendable {
    public let index: Int
    public let startTime: Double
    public let duration: Double
    public let byteStart: Int64
    public let byteEnd: Int64

    public init(index: Int, startTime: Double, duration: Double, byteStart: Int64, byteEnd: Int64) {
        self.index = index
        self.startTime = startTime
        self.duration = duration
        self.byteStart = byteStart
        self.byteEnd = byteEnd
    }

    public var endTime: Double { startTime + duration }
    public var byteCount: Int64 { max(0, byteEnd - byteStart) }
}

/// The complete, up-front VOD timeline: every segment's time and byte window,
/// declared from the first frame so AVPlayer's seekable range is the whole movie
/// and a seek-ahead can never 404.
public struct RemuxSegmentTimeline: Equatable, Sendable {
    public let segments: [RemuxSegmentPlan]
    public let targetDuration: Int
    public let totalDuration: Double

    public init(segments: [RemuxSegmentPlan], targetDuration: Int, totalDuration: Double) {
        self.segments = segments
        self.targetDuration = targetDuration
        self.totalDuration = totalDuration
    }

    public var isEmpty: Bool { segments.isEmpty }
    public var count: Int { segments.count }

    /// The segment whose half-open time window `[startTime, endTime)` contains
    /// `seconds`; clamps to the first/last segment outside the range.
    public func segmentIndex(forTime seconds: Double) -> Int? {
        guard !segments.isEmpty else { return nil }
        if seconds <= segments[0].startTime { return 0 }
        for segment in segments where seconds < segment.endTime {
            return segment.index
        }
        return segments.last?.index
    }
}

/// Builds a keyframe-aligned HLS segment timeline from Matroska cues — pure math,
/// fully unit-tested. Every boundary lands on a cue (a Cluster keyframe), so each
/// fMP4 segment begins with an IDR and AVPlayer can switch/seek to it cleanly.
public enum HLSSegmentPlanner {
    public enum PlannerError: Error, Equatable {
        case noCues
    }

    /// - Parameters:
    ///   - cues: Matroska cue points (any order; sorted internally).
    ///   - segmentDataOffset: absolute file offset of the Segment data start,
    ///     used to turn Segment-relative cue positions into absolute byte offsets.
    ///   - timestampScaleNs: TimestampScale (ns per tick).
    ///   - totalDuration: title duration in seconds (from Info/Duration or the
    ///     provider). When `nil`, the last cue time is used as a lower bound.
    ///   - fileSize: total source byte length (for the final segment's `byteEnd`).
    ///   - targetDuration: desired segment length in seconds (~6 s like Apple's
    ///     recommendation); boundaries snap to the next cue at/after this.
    public static func plan(
        cues: [MatroskaCuePoint],
        segmentDataOffset: Int,
        timestampScaleNs: UInt64,
        totalDuration: Double?,
        fileSize: Int64,
        targetDuration: Double = 6.0
    ) -> RemuxSegmentTimeline {
        let target = max(1.0, targetDuration)

        // Map cues → (time, absolute byte offset), sorted and de-duplicated on the
        // backing Cluster so repeated per-track cue points collapse to one boundary.
        var boundaries: [(time: Double, offset: Int64)] = cues
            .map { (
                $0.timeSeconds(timestampScaleNs: timestampScaleNs),
                Int64(segmentDataOffset + $0.clusterPosition)
            ) }
            .sorted { lhs, rhs in
                lhs.0 == rhs.0 ? lhs.1 < rhs.1 : lhs.0 < rhs.0
            }

        boundaries = dedupeByOffset(boundaries)
        guard !boundaries.isEmpty else {
            return RemuxSegmentTimeline(segments: [], targetDuration: Int(target.rounded(.up)), totalDuration: totalDuration ?? 0)
        }

        let endTime = resolveEndTime(boundaries: boundaries, totalDuration: totalDuration, target: target)
        let clampedFileSize = max(fileSize, boundaries.last?.offset ?? 0)

        var segments: [RemuxSegmentPlan] = []
        var index = 0
        var i = 0
        while i < boundaries.count {
            let start = boundaries[i]

            // Find the first later boundary at least `target` seconds away.
            var j = i + 1
            while j < boundaries.count && boundaries[j].time - start.time < target {
                j += 1
            }

            if j < boundaries.count {
                let next = boundaries[j]
                segments.append(
                    RemuxSegmentPlan(
                        index: index,
                        startTime: start.time,
                        duration: max(0, next.time - start.time),
                        byteStart: start.offset,
                        byteEnd: next.offset
                    )
                )
                i = j
            } else {
                // Final segment runs to the title end / file end.
                segments.append(
                    RemuxSegmentPlan(
                        index: index,
                        startTime: start.time,
                        duration: max(0, endTime - start.time),
                        byteStart: start.offset,
                        byteEnd: clampedFileSize
                    )
                )
                break
            }
            index += 1
        }

        let maxSegment = segments.map(\.duration).max() ?? target
        let targetDurationInt = max(1, Int(maxSegment.rounded(.up)))
        return RemuxSegmentTimeline(
            segments: segments,
            targetDuration: targetDurationInt,
            totalDuration: endTime
        )
    }

    // MARK: - Helpers

    /// Plans directly from the shared ``KeyframeTable`` currency (time-only) — the
    /// convergent feed shared by the Cues provider, cache, background scan, and
    /// server index. Because the segment muxer seeks by time (`make_segment` takes
    /// `start`/`end` seconds and `-c copy`s the window), no source byte offsets are
    /// needed; `byteStart`/`byteEnd` are left 0 here (they back only the byte-aware
    /// `plan(cues:)` overload).
    ///
    /// Boundary math matches `plan(cues:)`: each segment begins on a keyframe and
    /// runs to the first later keyframe at least `targetDuration` away, with the
    /// final segment running to the title duration.
    public static func plan(
        keyframeTable table: KeyframeTable,
        targetDuration: Double = 6.0
    ) -> RemuxSegmentTimeline {
        let target = max(1.0, targetDuration)
        let times = table.times
        guard !times.isEmpty else {
            return RemuxSegmentTimeline(
                segments: [],
                targetDuration: Int(target.rounded(.up)),
                totalDuration: table.duration
            )
        }

        // `KeyframeTable.normalized` guarantees duration >= last keyframe; when the
        // duration is strictly past the last keyframe use it, otherwise extend one
        // target window so the final segment is non-empty (mirrors resolveEndTime).
        let lastKeyframe = times[times.count - 1]
        let endTime = table.duration > lastKeyframe ? table.duration : lastKeyframe + target

        var segments: [RemuxSegmentPlan] = []
        var index = 0
        var i = 0
        while i < times.count {
            let start = times[i]
            var j = i + 1
            while j < times.count && times[j] - start < target {
                j += 1
            }
            if j < times.count {
                segments.append(
                    RemuxSegmentPlan(
                        index: index,
                        startTime: start,
                        duration: max(0, times[j] - start),
                        byteStart: 0,
                        byteEnd: 0
                    )
                )
                i = j
            } else {
                segments.append(
                    RemuxSegmentPlan(
                        index: index,
                        startTime: start,
                        duration: max(0, endTime - start),
                        byteStart: 0,
                        byteEnd: 0
                    )
                )
                break
            }
            index += 1
        }

        let maxSegment = segments.map(\.duration).max() ?? target
        return RemuxSegmentTimeline(
            segments: segments,
            targetDuration: max(1, Int(maxSegment.rounded(.up))),
            totalDuration: endTime
        )
    }

    private static func dedupeByOffset(_ boundaries: [(time: Double, offset: Int64)]) -> [(time: Double, offset: Int64)] {
        var result: [(time: Double, offset: Int64)] = []
        result.reserveCapacity(boundaries.count)
        for boundary in boundaries {
            if let last = result.last, last.offset == boundary.offset {
                continue // same Cluster — keep the earliest cue time
            }
            if let last = result.last, boundary.offset < last.offset {
                continue // non-monotonic byte offset — ignore the out-of-order cue
            }
            result.append(boundary)
        }
        return result
    }

    private static func resolveEndTime(
        boundaries: [(time: Double, offset: Int64)],
        totalDuration: Double?,
        target: Double
    ) -> Double {
        let lastCueTime = boundaries.last?.time ?? 0
        if let totalDuration, totalDuration > lastCueTime {
            return totalDuration
        }
        // Without a trustworthy duration, assume the tail runs one target window
        // past the last keyframe so the final segment is non-empty.
        return lastCueTime + target
    }
}
