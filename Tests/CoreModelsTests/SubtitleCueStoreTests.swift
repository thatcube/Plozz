import XCTest
@testable import CoreModels

final class SubtitleCueStoreTests: XCTestCase {

    private func textCue(_ id: Int, _ start: Double, _ end: Double,
                         alignment: SubtitleAlignment? = nil) -> SubtitleCue {
        SubtitleCue(id: id, start: start, end: end,
                    body: .text(SubtitleText("cue \(id)", alignment: alignment)))
    }

    // MARK: Indexed query parity with the naive filter

    func testActiveMatchesNaiveAcrossTimeline() {
        let cues = [
            textCue(1, 0.0, 2.0),
            textCue(2, 1.5, 3.0),     // overlaps cue 1
            textCue(3, 3.0, 3.5),     // short cue right after
            textCue(4, 3.0, 9.0),     // long cue spanning many others (back-scan window)
            textCue(5, 5.0, 6.0),
            textCue(6, 8.9, 9.0)
        ]
        let store = SubtitleCueStore(cues: cues)
        // Sweep at fine resolution; the indexed store must agree with the O(n) filter.
        var t = -1.0
        while t <= 10.0 {
            let indexed = store.active(at: t).map(\.id).sorted()
            let naive = cues.active(at: t).map(\.id).sorted()
            XCTAssertEqual(indexed, naive, "mismatch at t=\(t)")
            t += 0.05
        }
    }

    func testStartInclusiveEndExclusive() {
        let store = SubtitleCueStore(cues: [textCue(1, 1.0, 2.0)])
        XCTAssertEqual(store.active(at: 1.0).map(\.id), [1], "start is inclusive")
        XCTAssertEqual(store.active(at: 2.0).map(\.id), [], "end is exclusive")
        XCTAssertEqual(store.active(at: 1.999).map(\.id), [1])
    }

    func testBeforeFirstAndAfterLastAreEmpty() {
        let store = SubtitleCueStore(cues: [textCue(1, 5.0, 6.0), textCue(2, 7.0, 8.0)])
        XCTAssertTrue(store.active(at: 0.0).isEmpty)
        XCTAssertTrue(store.active(at: 100.0).isEmpty)
        XCTAssertTrue(store.active(at: 6.5).isEmpty, "gap between cues")
    }

    func testOffsetShiftsActivation() {
        let store = SubtitleCueStore(cues: [textCue(1, 10.0, 12.0)])
        // Positive offset shows cues later: at t=10 with +2 offset the cue isn't on yet.
        XCTAssertTrue(store.active(at: 10.0, offset: 2.0).isEmpty)
        XCTAssertEqual(store.active(at: 12.0, offset: 2.0).map(\.id), [1])
    }

    func testUnsortedInputIsHandled() {
        let store = SubtitleCueStore(cues: [
            textCue(3, 6.0, 7.0), textCue(1, 1.0, 2.0), textCue(2, 3.0, 4.0)
        ])
        XCTAssertEqual(store.active(at: 1.5).map(\.id), [1])
        XCTAssertEqual(store.active(at: 6.5).map(\.id), [3])
    }

    func testEmptyStore() {
        let store = SubtitleCueStore(cues: [])
        XCTAssertTrue(store.isEmpty)
        XCTAssertTrue(store.active(at: 1.0).isEmpty)
    }

    // MARK: Timeline change detection (cue-boundary crossings)

    @MainActor
    func testTimelineEmitsOnlyOnBoundaryCrossings() {
        let store = SubtitleCueStore(cues: [textCue(1, 1.0, 2.0), textCue(2, 5.0, 6.0)])
        let timeline = SubtitleCueTimeline(store: store)

        XCTAssertTrue(timeline.update(to: 0.0))          // empty → still a first emit
        XCTAssertFalse(timeline.update(to: 0.5))         // still empty, no change
        XCTAssertTrue(timeline.update(to: 1.0))          // cue 1 turns on
        XCTAssertEqual(timeline.active.map(\.id), [1])
        XCTAssertFalse(timeline.update(to: 1.5))         // still cue 1, no change
        XCTAssertTrue(timeline.update(to: 2.0))          // cue 1 turns off
        XCTAssertTrue(timeline.active.isEmpty)
        XCTAssertTrue(timeline.update(to: 5.2))          // cue 2 turns on
        XCTAssertEqual(timeline.active.map(\.id), [2])
    }

    @MainActor
    func testTimelineOffsetChangeForcesRecompute() {
        let store = SubtitleCueStore(cues: [textCue(1, 10.0, 12.0)])
        let timeline = SubtitleCueTimeline(store: store)
        _ = timeline.update(to: 10.5)
        XCTAssertEqual(timeline.active.map(\.id), [1])
        timeline.offset = 2.0                            // now cue starts at 12.0
        XCTAssertTrue(timeline.update(to: 10.5))         // offset change re-emits
        XCTAssertTrue(timeline.active.isEmpty)
    }

    @MainActor
    func testTimelineReplaceClearsSignature() {
        let timeline = SubtitleCueTimeline(store: SubtitleCueStore(cues: [textCue(1, 1.0, 2.0)]))
        _ = timeline.update(to: 1.5)
        XCTAssertEqual(timeline.active.map(\.id), [1])
        timeline.replace(store: SubtitleCueStore(cues: [textCue(9, 1.0, 2.0)]))
        XCTAssertTrue(timeline.update(to: 1.5))
        XCTAssertEqual(timeline.active.map(\.id), [9])
    }
}
