import Foundation

/// Produces a ``KeyframeTable`` from Matroska Cues — the Cues fast-path provider
/// for the local-remux pipeline. ~90-95% of titles ship a Cues index readable in
/// two range requests, giving an exact, complete keyframe table at open with no
/// media scan.
///
/// This is the Track A half of the shared provider seam: it is a concrete,
/// dependency-free value that Track C's provider protocol (Cues / cache / scan /
/// server, interchangeable) can wrap so every source emits the same currency.
/// Keeping it pure (the caller owns the ranged byte reads that build the
/// `MatroskaSummary`) means it needs no I/O and is trivially unit-tested.
public struct CuesKeyframeProvider {
    /// A parsed Matroska summary whose `cues` have already been resolved
    /// (header parse → follow SeekHead → parse trailing Cues).
    public let summary: MatroskaSummary
    /// Preferred title duration (e.g. from the media provider). Falls back to the
    /// Matroska `Duration`, then to the last keyframe time.
    public let durationHint: Double?

    public init(summary: MatroskaSummary, durationHint: Double? = nil) {
        self.summary = summary
        self.durationHint = durationHint
    }

    /// Maps each Cue's presentation time (ticks → seconds via TimestampScale) into
    /// the shared keyframe currency, enforcing the table invariants. Because Cues
    /// carry the backing Cluster's byte position, this is a byte-offset-bearing
    /// source: `byteOffsets` is populated (absolute file offset = segment data
    /// offset + the cue's Segment-relative cluster position).
    public func keyframeTable() -> KeyframeTable {
        let times = summary.cues.map { $0.timeSeconds(timestampScaleNs: summary.timestampScaleNs) }
        let offsets = summary.cues.map { Int64(summary.segmentDataOffset + $0.clusterPosition) }
        let duration = durationHint
            ?? summary.durationSeconds
            ?? (times.max() ?? 0)
        return KeyframeTable.normalized(times: times, byteOffsets: offsets, duration: duration)
    }
}

// MARK: - KeyframeTableSource conformance

/// The Cues fast-path is the first concrete ``KeyframeTableSource`` — the highest
/// priority (``KeyframeSourceKind/liveCues``) open-time source. It is "available"
/// only when the parsed summary actually carries Cues; otherwise the selector
/// falls through to the no-Cues walk / cache.
extension CuesKeyframeProvider: KeyframeTableSource {
    public var kind: KeyframeSourceKind { .liveCues }

    public func isAvailable() -> Bool { !summary.cues.isEmpty }

    public func loadKeyframeTable() -> KeyframeTable? {
        guard !summary.cues.isEmpty else { return nil }
        let table = keyframeTable()
        return table.isEmpty ? nil : table
    }
}
