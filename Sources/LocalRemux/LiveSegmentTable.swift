import Foundation

/// Thread-safe, growing segment table for **lazy/windowed** remux discovery.
///
/// In lazy mode the keyframe-aligned segment table is not known in full at open:
/// only a short prefix is discovered synchronously (so playback starts in a couple
/// seconds), and a background task extends it window-by-window around the playhead.
/// This object is the shared hand-off point — the background discovery loop calls
/// `update(...)` as the table grows, and `RemuxContentSource` reads `snapshot()` /
/// `count` each time AVPlayer fetches the (unpinned, EVENT) media playlist or a
/// segment, so the served playlist always reflects what has actually been muxed-
/// ready so far.
///
/// The published durations only ever grow and never change for an already-published
/// index (the C planner is prefix-stable), which is exactly the HLS EVENT contract,
/// so a reload can append segments without invalidating ones AVPlayer already holds.
final class LiveSegmentTable: @unchecked Sendable {
    private let lock = NSLock()
    private var durations: [Double]
    private var complete: Bool
    /// Constant `EXT-X-TARGETDURATION` (seconds) — must be `>=` every segment for
    /// the whole title, so it is fixed up front to comfortably exceed the longest
    /// expected GOP rather than recomputed (the spec forbids it changing).
    let targetDuration: Int

    init(durations: [Double], complete: Bool, targetDuration: Int) {
        self.durations = durations
        self.complete = complete
        self.targetDuration = max(1, targetDuration)
    }

    /// Current segment count (what the EVENT playlist currently lists).
    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return durations.count
    }

    /// Whether discovery has reached EOF (the playlist now carries `ENDLIST`).
    var isComplete: Bool {
        lock.lock(); defer { lock.unlock() }
        return complete
    }

    /// Atomic view of the table for rendering the media playlist.
    func snapshot() -> (durations: [Double], complete: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (durations, complete)
    }

    /// Publishes a grown table from the background discovery loop. `durations` must
    /// be a superset-by-prefix of the previous value (the planner guarantees this);
    /// once `complete` is set true it stays true.
    func update(durations: [Double], complete: Bool) {
        lock.lock(); defer { lock.unlock() }
        // Never shrink the published timeline or un-complete it.
        if durations.count >= self.durations.count {
            self.durations = durations
        }
        if complete { self.complete = true }
    }
}
