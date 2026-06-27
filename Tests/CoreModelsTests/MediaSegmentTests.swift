import XCTest
@testable import CoreModels

final class MediaSegmentTests: XCTestCase {
    func testIsSkippableOnlyIntroAndCredits() {
        XCTAssertTrue(MediaSegment(kind: .intro, start: 0, end: 10).isSkippable)
        XCTAssertTrue(MediaSegment(kind: .credits, start: 100, end: 120).isSkippable)
        XCTAssertFalse(MediaSegment(kind: .recap, start: 0, end: 5).isSkippable)
        XCTAssertFalse(MediaSegment(kind: .preview, start: 0, end: 5).isSkippable)
        XCTAssertFalse(MediaSegment(kind: .commercial, start: 0, end: 5).isSkippable)
        XCTAssertFalse(MediaSegment(kind: .unknown, start: 0, end: 5).isSkippable)
    }

    func testContainsRespectsMargins() {
        let seg = MediaSegment(kind: .intro, start: 30, end: 60)
        XCTAssertTrue(seg.contains(40))
        // Lead-in tolerance: appears slightly before nominal start.
        XCTAssertTrue(seg.contains(29.9))
        // Excluded once within the trailing margin of the end.
        XCTAssertFalse(seg.contains(59.9))
        XCTAssertFalse(seg.contains(70))
    }

    func testActiveSkippablePicksContainingSegment() {
        let segments = [
            MediaSegment(kind: .intro, start: 10, end: 40),
            MediaSegment(kind: .credits, start: 1200, end: 1260),
            MediaSegment(kind: .recap, start: 0, end: 8)
        ]
        XCTAssertEqual(segments.activeSkippable(at: 20)?.kind, .intro)
        XCTAssertEqual(segments.activeSkippable(at: 1230)?.kind, .credits)
        // Inside a non-skippable recap → no skip offered.
        XCTAssertNil(segments.activeSkippable(at: 4))
        // Outside every window.
        XCTAssertNil(segments.activeSkippable(at: 600))
    }

    func testActiveSkippablePrefersEarliestStartOnOverlap() {
        let segments = [
            MediaSegment(kind: .credits, start: 25, end: 80),
            MediaSegment(kind: .intro, start: 20, end: 50)
        ]
        XCTAssertEqual(segments.activeSkippable(at: 30)?.kind, .intro)
    }

    func testSkipActionLabels() {
        XCTAssertEqual(MediaSegment.Kind.intro.skipActionLabel, "Skip Intro")
        XCTAssertEqual(MediaSegment.Kind.credits.skipActionLabel, "Skip Credits")
    }

    func testCodableRoundTrip() throws {
        let seg = MediaSegment(id: "abc", kind: .credits, start: 12.5, end: 99.0)
        let data = try JSONEncoder().encode(seg)
        let decoded = try JSONDecoder().decode(MediaSegment.self, from: data)
        XCTAssertEqual(seg, decoded)
    }
}

final class PlaybackSettingsTests: XCTestCase {
    func testDefaultIsOff() {
        XCTAssertFalse(PlaybackSettings.default.skipIntros)
    }

    func testLenientDecodeOfEmptyPayload() throws {
        let data = Data("{}".utf8)
        let decoded = try JSONDecoder().decode(PlaybackSettings.self, from: data)
        XCTAssertEqual(decoded, .default)
    }

    func testDecodePreservesValue() throws {
        let data = Data(#"{"skipIntros":true}"#.utf8)
        let decoded = try JSONDecoder().decode(PlaybackSettings.self, from: data)
        XCTAssertTrue(decoded.skipIntros)
    }
}
