import XCTest
@testable import FeaturePlayback

final class WebVTTNormalizerTests: XCTestCase {
    func testAlreadyWebVTTPassesThroughWithUnifiedLineEndings() {
        let input = "WEBVTT\r\n\r\n00:00:01.000 --> 00:00:02.000\r\nHello\r\n"
        let output = WebVTTNormalizer.normalize(input)
        XCTAssertTrue(output.hasPrefix("WEBVTT"))
        XCTAssertFalse(output.contains("\r"))
        XCTAssertTrue(output.contains("00:00:01.000 --> 00:00:02.000"))
    }

    func testWebVTTWithLeadingBOMRecognized() {
        let input = "\u{FEFF}WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nHi\n"
        let output = WebVTTNormalizer.normalize(input)
        // Not treated as SRT (no second WEBVTT header prepended).
        XCTAssertEqual(output.components(separatedBy: "WEBVTT").count - 1, 1)
    }

    func testSRTConvertedToWebVTT() {
        let srt = """
        1
        00:00:01,000 --> 00:00:04,000
        Hello, world

        2
        00:00:05,250 --> 00:00:06,500
        Second line
        """
        let output = WebVTTNormalizer.normalize(srt)

        XCTAssertTrue(output.hasPrefix("WEBVTT\n\n"))
        XCTAssertTrue(output.contains("00:00:01.000 --> 00:00:04.000"))
        XCTAssertTrue(output.contains("00:00:05.250 --> 00:00:06.500"))
        // Subtitle text commas are untouched (only timing separators rewritten).
        XCTAssertTrue(output.contains("Hello, world"))
        XCTAssertFalse(output.contains(",000"))
        XCTAssertFalse(output.contains(",250"))
    }

    func testSRTWithCRLFConverted() {
        let srt = "1\r\n00:00:01,000 --> 00:00:02,000\r\nHi\r\n"
        let output = WebVTTNormalizer.normalize(srt)
        XCTAssertTrue(output.hasPrefix("WEBVTT"))
        XCTAssertTrue(output.contains("00:00:01.000 --> 00:00:02.000"))
        XCTAssertFalse(output.contains("\r"))
    }
}
