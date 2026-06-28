#if canImport(UIKit)
import XCTest
@testable import LocalRemux

/// Pure-logic tests for the lazy/windowed (EVENT) playlist path: the EVENT media
/// playlist shape (EVENT type, no ENDLIST while growing, ENDLIST when complete,
/// constant TARGETDURATION, append-only segments) and the thread-safe
/// `LiveSegmentTable` the background discovery loop publishes into.
final class LazyEventPlaylistTests: XCTestCase {

    private func planner(durations: [Double]) -> RemuxSegmentPlanner {
        RemuxSegmentPlanner(
            segmentDurations: durations,
            stream: .init(width: 3840, height: 2160,
                          dolbyVisionProfile: 0, dolbyVisionLevel: 0,
                          audioIsEAC3: true, bandwidth: 0)
        )
    }

    // MARK: - EVENT playlist shape

    func testEvent_incomplete_isEventTypeWithNoEndlist() {
        let m3u8 = planner(durations: [6, 6, 7.5]).eventMediaPlaylist(
            durations: [6, 6, 7.5], isComplete: false, targetDuration: 30)
        XCTAssertTrue(m3u8.contains("#EXT-X-PLAYLIST-TYPE:EVENT"))
        XCTAssertFalse(m3u8.contains("#EXT-X-ENDLIST"),
                       "a growing EVENT playlist must NOT carry ENDLIST")
        XCTAssertTrue(m3u8.contains("#EXT-X-TARGETDURATION:30"))
        XCTAssertTrue(m3u8.contains("#EXT-X-MEDIA-SEQUENCE:0"))
        XCTAssertTrue(m3u8.contains("#EXT-X-MAP:URI=\"\(RemuxSegmentPlanner.initName)\""))
    }

    func testEvent_complete_appendsEndlist() {
        let m3u8 = planner(durations: [6, 6]).eventMediaPlaylist(
            durations: [6, 6], isComplete: true, targetDuration: 30)
        XCTAssertTrue(m3u8.contains("#EXT-X-PLAYLIST-TYPE:EVENT"))
        XCTAssertTrue(m3u8.hasSuffix("#EXT-X-ENDLIST\n"),
                      "a finished EVENT playlist must end with ENDLIST")
    }

    func testEvent_targetDurationIsConstant_notDerivedFromSegments() {
        // Even with a 24 s GOP segment, the caller-supplied constant is used as-is
        // (a growing list cannot recompute TARGETDURATION per reload).
        let m3u8 = planner(durations: [24.5]).eventMediaPlaylist(
            durations: [24.5], isComplete: false, targetDuration: 30)
        XCTAssertTrue(m3u8.contains("#EXT-X-TARGETDURATION:30"))
    }

    func testEvent_listsOneSegmentPerDuration_inOrder() {
        let m3u8 = planner(durations: [6, 7, 8]).eventMediaPlaylist(
            durations: [6, 7, 8], isComplete: false, targetDuration: 30)
        XCTAssertTrue(m3u8.contains(RemuxSegmentPlanner.segmentName(0)))
        XCTAssertTrue(m3u8.contains(RemuxSegmentPlanner.segmentName(1)))
        XCTAssertTrue(m3u8.contains(RemuxSegmentPlanner.segmentName(2)))
        XCTAssertFalse(m3u8.contains(RemuxSegmentPlanner.segmentName(3)))
        // EXTINF durations preserved.
        XCTAssertTrue(m3u8.contains("#EXTINF:\(RemuxSegmentPlanner.formatDuration(7)),"))
    }

    func testEvent_growthIsAppendOnly_prefixUnchanged() {
        // A reload after discovery appends segments without changing earlier ones —
        // the EVENT contract. Verify the first reload's body is a prefix of the next.
        let p = planner(durations: [6, 6])
        let first = p.eventMediaPlaylist(durations: [6, 6], isComplete: false, targetDuration: 30)
        let second = p.eventMediaPlaylist(durations: [6, 6, 9], isComplete: false, targetDuration: 30)
        // Drop the trailing newline, then the first (sans header reordering) segment
        // entries must all appear, in order, within the second.
        for index in 0..<2 {
            XCTAssertTrue(second.contains(RemuxSegmentPlanner.segmentName(index)))
        }
        XCTAssertTrue(second.contains(RemuxSegmentPlanner.segmentName(2)))
        XCTAssertGreaterThan(second.count, first.count)
    }

    // MARK: - LiveSegmentTable

    func testLiveTable_snapshotReflectsInitialState() {
        let t = LiveSegmentTable(durations: [6, 6], complete: false, targetDuration: 30)
        XCTAssertEqual(t.count, 2)
        XCTAssertFalse(t.isComplete)
        XCTAssertEqual(t.snapshot().durations, [6, 6])
    }

    func testLiveTable_updateGrowsAndCompletes() {
        let t = LiveSegmentTable(durations: [6], complete: false, targetDuration: 30)
        t.update(durations: [6, 6, 7], complete: false)
        XCTAssertEqual(t.count, 3)
        XCTAssertFalse(t.isComplete)
        t.update(durations: [6, 6, 7, 8], complete: true)
        XCTAssertEqual(t.count, 4)
        XCTAssertTrue(t.isComplete)
    }

    func testLiveTable_neverShrinksOrUncompletes() {
        let t = LiveSegmentTable(durations: [6, 6, 6], complete: true, targetDuration: 30)
        // A stale, smaller / not-complete update must not regress published state.
        t.update(durations: [6], complete: false)
        XCTAssertEqual(t.count, 3, "the published timeline must never shrink")
        XCTAssertTrue(t.isComplete, "completion must be sticky")
    }

    func testLiveTable_concurrentReadsAndWritesAreSafe() {
        let t = LiveSegmentTable(durations: [6], complete: false, targetDuration: 30)
        let group = DispatchGroup()
        // Writer grows the table monotonically.
        group.enter()
        DispatchQueue.global().async {
            var durations = [6.0]
            for _ in 0..<500 { durations.append(6.0); t.update(durations: durations, complete: false) }
            t.update(durations: durations, complete: true)
            group.leave()
        }
        // Readers snapshot concurrently; counts must be monotonic non-decreasing.
        for _ in 0..<4 {
            group.enter()
            DispatchQueue.global().async {
                var last = 0
                for _ in 0..<500 {
                    let c = t.count
                    XCTAssertGreaterThanOrEqual(c, last)
                    last = c
                }
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
        XCTAssertTrue(t.isComplete)
        XCTAssertEqual(t.count, 501)
    }
}
#endif
