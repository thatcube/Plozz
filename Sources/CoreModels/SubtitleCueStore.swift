import Foundation

/// An indexed, time-queryable view over one subtitle ``SubtitleCueStream``.
///
/// Replaces the O(n) `Sequence.active(at:offset:)` linear scan — fine for the
/// preview harness, but too slow to run every frame over a feature-length track
/// with thousands of cues. Cues are sorted once by start time and `active(at:)`
/// uses a binary search plus a bounded back-scan window to gather only the
/// handful of cues overlapping the query time, in O(log n + k).
///
/// The store is a pure value (no clock, no publishing). ``SubtitleCueTimeline``
/// wraps it to drive a renderer and re-emit only on cue-boundary crossings.
public struct SubtitleCueStore: Sendable {
    public let metadata: SubtitleStreamMetadata

    /// Cues sorted by `start` (then `end`). Parallel `starts` powers the search.
    private let cues: [SubtitleCue]
    private let starts: [Double]
    /// Longest cue duration; bounds how far back an overlapping cue can begin,
    /// so the active window never scans the whole track.
    private let maxDuration: Double

    public init(_ stream: SubtitleCueStream) {
        self.init(cues: stream.cues, metadata: stream.metadata)
    }

    public init(
        cues: [SubtitleCue],
        metadata: SubtitleStreamMetadata = SubtitleStreamMetadata(format: .unknown)
    ) {
        let sorted = cues.sorted { lhs, rhs in
            lhs.start == rhs.start ? lhs.end < rhs.end : lhs.start < rhs.start
        }
        self.cues = sorted
        self.starts = sorted.map(\.start)
        self.metadata = metadata
        self.maxDuration = sorted.reduce(0) { Swift.max($0, $1.end - $1.start) }
    }

    public var isEmpty: Bool { cues.isEmpty }
    public var count: Int { cues.count }

    /// The cues overlapping `time` (seconds) after an optional global `offset`
    /// (positive = show subtitles later). Overlapping cues are allowed (a
    /// positioned sign atop dialogue), returned in start order.
    public func active(at time: Double, offset: Double = 0) -> [SubtitleCue] {
        guard !cues.isEmpty else { return [] }
        let t = time - offset
        // Candidates start in (t - maxDuration, t]; everything earlier has ended,
        // everything from `hi` on hasn't started.
        let hi = upperBound(of: t)                       // first cue with start > t
        guard hi > 0 else { return [] }
        let lo = lowerBound(of: t - maxDuration)         // first cue that could still be active
        var result: [SubtitleCue] = []
        result.reserveCapacity(hi - lo)
        var i = lo
        while i < hi {
            let cue = cues[i]
            if cue.start <= t, t < cue.end { result.append(cue) }
            i += 1
        }
        return result
    }

    // MARK: Binary search over `starts`

    /// First index whose start is `>= value`.
    private func lowerBound(of value: Double) -> Int {
        var low = 0, high = starts.count
        while low < high {
            let mid = (low + high) / 2
            if starts[mid] < value { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// First index whose start is `> value`.
    private func upperBound(of value: Double) -> Int {
        var low = 0, high = starts.count
        while low < high {
            let mid = (low + high) / 2
            if starts[mid] <= value { low = mid + 1 } else { high = mid }
        }
        return low
    }
}

/// Drives a renderer from a ``SubtitleCueStore``, recomputing the active cue set
/// as playback time advances but **only re-emitting when the set changes** (a
/// cue-boundary crossing). A player can call ``update(to:)`` on every 30–60 Hz
/// tick cheaply; SwiftUI only re-renders when `active` actually changes.
@MainActor
public final class SubtitleCueTimeline {
    public private(set) var store: SubtitleCueStore
    /// The cues currently on screen, updated by ``update(to:)``.
    public private(set) var active: [SubtitleCue] = []
    /// Global sync offset in seconds (positive = later). Changing it forces the
    /// next ``update(to:)`` to recompute.
    public var offset: Double {
        didSet { if offset != oldValue { lastActiveIDs = nil } }
    }

    /// Signature of the last emitted set, to detect boundary crossings without
    /// reallocating the cue array each tick. `nil` forces a recompute.
    private var lastActiveIDs: [Int]?

    public init(store: SubtitleCueStore, offset: Double = 0) {
        self.store = store
        self.offset = offset
    }

    public convenience init(stream: SubtitleCueStream, offset: Double = 0) {
        self.init(store: SubtitleCueStore(stream), offset: offset)
    }

    public var metadata: SubtitleStreamMetadata { store.metadata }

    /// Swap in a new stream (e.g. the user picked a different subtitle track),
    /// clearing the change signature so the next ``update(to:)`` re-emits.
    public func replace(store newStore: SubtitleCueStore) {
        store = newStore
        lastActiveIDs = nil
    }

    /// Recompute the active set for `time`. Returns `true` iff the on-screen set
    /// changed (so the caller should republish); `false` means no boundary was
    /// crossed and `active` is unchanged.
    @discardableResult
    public func update(to time: Double) -> Bool {
        let next = store.active(at: time, offset: offset)
        let ids = next.map(\.id)
        if let last = lastActiveIDs, last == ids { return false }
        lastActiveIDs = ids
        active = next
        return true
    }

    /// Clears the active set (e.g. subtitles turned off).
    public func clear() {
        guard !active.isEmpty || lastActiveIDs != nil else { return }
        active = []
        lastActiveIDs = nil
    }
}
