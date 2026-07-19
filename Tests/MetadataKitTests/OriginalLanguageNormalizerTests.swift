import XCTest
@testable import MetadataKit

final class OriginalLanguageNormalizerTests: XCTestCase {
    func testPassesThroughISO6391Codes() {
        XCTAssertEqual(OriginalLanguageNormalizer.normalized("en"), "en")
        XCTAssertEqual(OriginalLanguageNormalizer.normalized("JA"), "ja")
    }

    func testFoldsISO6392ToISO6391() {
        XCTAssertEqual(OriginalLanguageNormalizer.normalized("jpn"), "ja")
        XCTAssertEqual(OriginalLanguageNormalizer.normalized("eng"), "en")
        XCTAssertEqual(OriginalLanguageNormalizer.normalized("kor"), "ko")
        XCTAssertEqual(OriginalLanguageNormalizer.normalized("zho"), "zh")
    }

    func testDropsRegionSuffix() {
        XCTAssertEqual(OriginalLanguageNormalizer.normalized("pt-BR"), "pt")
        XCTAssertEqual(OriginalLanguageNormalizer.normalized("en_US"), "en")
    }

    func testMapsDisplayNames() {
        XCTAssertEqual(OriginalLanguageNormalizer.normalized("English"), "en")
        XCTAssertEqual(OriginalLanguageNormalizer.normalized("Japanese"), "ja")
        XCTAssertEqual(OriginalLanguageNormalizer.normalized("Korean"), "ko")
        XCTAssertEqual(OriginalLanguageNormalizer.normalized("Mandarin Chinese"), "zh")
        XCTAssertEqual(OriginalLanguageNormalizer.normalized("Turkish"), "tr")
    }

    func testReturnsNilForUnknownOrEmpty() {
        XCTAssertNil(OriginalLanguageNormalizer.normalized(nil))
        XCTAssertNil(OriginalLanguageNormalizer.normalized(""))
        XCTAssertNil(OriginalLanguageNormalizer.normalized("   "))
        XCTAssertNil(OriginalLanguageNormalizer.normalized("Klingon"))
    }
}
