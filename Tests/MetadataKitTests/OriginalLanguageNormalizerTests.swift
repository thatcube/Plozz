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

    func testMapsProviderAliasCodes() {
        // TMDb's legacy `cn` for Chinese folds to canonical `zh`.
        XCTAssertEqual(OriginalLanguageNormalizer.normalized("cn"), "zh")
        XCTAssertEqual(OriginalLanguageNormalizer.normalized("CN"), "zh")
    }

    func testRejectsNoLanguageSentinels() {
        // TMDb `xx` ("No Language"), ISO `zxx`/`und` must resolve to nil so the
        // caller defers to the container default instead of a bogus track language.
        XCTAssertNil(OriginalLanguageNormalizer.normalized("xx"))
        XCTAssertNil(OriginalLanguageNormalizer.normalized("XX"))
        XCTAssertNil(OriginalLanguageNormalizer.normalized("zxx"))
        XCTAssertNil(OriginalLanguageNormalizer.normalized("und"))
    }

    func testReturnsNilForUnknownOrEmpty() {
        XCTAssertNil(OriginalLanguageNormalizer.normalized(nil))
        XCTAssertNil(OriginalLanguageNormalizer.normalized(""))
        XCTAssertNil(OriginalLanguageNormalizer.normalized("   "))
        XCTAssertNil(OriginalLanguageNormalizer.normalized("Klingon"))
    }
}
