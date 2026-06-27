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

    func testRemainingCountsDownToZeroAtTrailingMargin() {
        let seg = MediaSegment(kind: .intro, start: 30, end: 90)
        // Near the start, almost the whole window remains.
        XCTAssertEqual(seg.remaining(at: 30), 59.75, accuracy: 0.001)
        XCTAssertEqual(seg.remaining(at: 60), 29.75, accuracy: 0.001)
        // At/after the trailing margin it clamps to zero.
        XCTAssertEqual(seg.remaining(at: 89.75), 0, accuracy: 0.001)
        XCTAssertEqual(seg.remaining(at: 200), 0, accuracy: 0.001)
    }

    func testRemainingFractionSpansOneToZero() {
        let seg = MediaSegment(kind: .credits, start: 100, end: 160)
        // Earliest visible point (start - margin) → full bar.
        XCTAssertEqual(seg.remainingFraction(at: 99.75), 1, accuracy: 0.001)
        XCTAssertEqual(seg.remainingFraction(at: 130), 0.5, accuracy: 0.01)
        XCTAssertEqual(seg.remainingFraction(at: 159.75), 0, accuracy: 0.001)
        // Clamped outside the window.
        XCTAssertEqual(seg.remainingFraction(at: 300), 0, accuracy: 0.001)
    }

    func testRemainingFractionZeroForDegenerateWindow() {
        let seg = MediaSegment(kind: .intro, start: 50, end: 50)
        XCTAssertEqual(seg.window, 0, accuracy: 0.001)
        XCTAssertEqual(seg.remainingFraction(at: 50), 0, accuracy: 0.001)
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
        XCTAssertEqual(PlaybackSettings.default.skipIntros, .off)
        XCTAssertFalse(PlaybackSettings.default.skipIntros.fetchesMarkers)
    }

    func testLenientDecodeOfEmptyPayload() throws {
        let data = Data("{}".utf8)
        let decoded = try JSONDecoder().decode(PlaybackSettings.self, from: data)
        XCTAssertEqual(decoded, .default)
    }

    func testDecodePreservesModeValue() throws {
        let data = Data(#"{"skipIntros":"autoInstant"}"#.utf8)
        let decoded = try JSONDecoder().decode(PlaybackSettings.self, from: data)
        XCTAssertEqual(decoded.skipIntros, .autoInstant)
        XCTAssertTrue(decoded.skipIntros.isAutomatic)
    }

    func testLegacyBooleanTrueMapsToOn() throws {
        let data = Data(#"{"skipIntros":true}"#.utf8)
        let decoded = try JSONDecoder().decode(PlaybackSettings.self, from: data)
        XCTAssertEqual(decoded.skipIntros, .on)
    }

    func testLegacyBooleanFalseMapsToOff() throws {
        let data = Data(#"{"skipIntros":false}"#.utf8)
        let decoded = try JSONDecoder().decode(PlaybackSettings.self, from: data)
        XCTAssertEqual(decoded.skipIntros, .off)
    }

    func testRoundTripEncodeDecode() throws {
        for mode in SkipIntrosMode.allCases {
            let settings = PlaybackSettings(skipIntros: mode)
            let data = try JSONEncoder().encode(settings)
            let decoded = try JSONDecoder().decode(PlaybackSettings.self, from: data)
            XCTAssertEqual(decoded.skipIntros, mode)
        }
    }

    func testModeFlags() {
        XCTAssertFalse(SkipIntrosMode.off.fetchesMarkers)
        XCTAssertTrue(SkipIntrosMode.on.fetchesMarkers)
        XCTAssertFalse(SkipIntrosMode.on.isAutomatic)
        XCTAssertTrue(SkipIntrosMode.autoDelay.isAutomatic)
        XCTAssertTrue(SkipIntrosMode.autoInstant.isAutomatic)
    }
}
