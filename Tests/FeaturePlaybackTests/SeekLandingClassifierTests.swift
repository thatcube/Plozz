import XCTest
import CoreModels
@testable import FeaturePlayback

/// Tests the pure seek-landing classifier extracted from `PlayerViewModel`.
/// These pin the "Option B" grace-window rule: a committed seek that lands just
/// inside a skippable segment still offers a manual Skip button, but a deeper
/// landing is respected as a deliberate jump and the affordance is suppressed.
final class SeekLandingClassifierTests: XCTestCase {
    private func segment(
        id: String = "seg1",
        kind: MediaSegment.Kind = .intro,
        start: TimeInterval,
        end: TimeInterval
    ) -> MediaSegment {
        MediaSegment(id: id, kind: kind, start: start, end: end)
    }

    func testLandingWithinGraceOffersButton() {
        let segs = [segment(start: 100, end: 180)]
        // Land 3s in — within the 5s grace window.
        let landing = SeekLandingClassifier.landing(forTarget: 103, in: segs)
        XCTAssertEqual(landing?.segmentID, "seg1")
        XCTAssertEqual(landing?.isWithinGrace, true)
    }

    func testLandingAtGraceBoundaryIsWithinGrace() {
        let segs = [segment(start: 100, end: 180)]
        // Exactly at the boundary (offset == seekGraceWindow) counts as within.
        let landing = SeekLandingClassifier.landing(
            forTarget: 100 + MediaSegment.seekGraceWindow, in: segs)
        XCTAssertEqual(landing?.isWithinGrace, true)
    }

    func testDeepLandingSuppressesButton() {
        let segs = [segment(start: 100, end: 180)]
        // Land 30s in — well past the grace window.
        let landing = SeekLandingClassifier.landing(forTarget: 130, in: segs)
        XCTAssertEqual(landing?.segmentID, "seg1")
        XCTAssertEqual(landing?.isWithinGrace, false)
    }

    func testLandingOutsideEverySegmentReturnsNil() {
        let segs = [segment(start: 100, end: 180)]
        XCTAssertNil(SeekLandingClassifier.landing(forTarget: 50, in: segs))
        XCTAssertNil(SeekLandingClassifier.landing(forTarget: 500, in: segs))
    }

    func testEmptySegmentsReturnsNil() {
        XCTAssertNil(SeekLandingClassifier.landing(forTarget: 120, in: []))
    }

    func testNonSkippableSegmentIsIgnored() {
        // A recap is detected but not skippable, so a landing inside it is nil.
        let segs = [segment(id: "recap", kind: .recap, start: 100, end: 180)]
        XCTAssertNil(SeekLandingClassifier.landing(forTarget: 120, in: segs))
    }

    func testIntroWinsTieOverCredits() {
        let segs = [
            segment(id: "intro", kind: .intro, start: 100, end: 200),
            segment(id: "credits", kind: .credits, start: 100, end: 200)
        ]
        let landing = SeekLandingClassifier.landing(forTarget: 150, in: segs)
        XCTAssertEqual(landing?.segmentID, "intro")
    }
}
