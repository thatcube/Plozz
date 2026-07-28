import Foundation
@testable import CoreModels
import XCTest

final class SubtitleLanguageCatalogTests: XCTestCase {
    func testLanguageNamesUseTheExplicitAppLocale() {
        XCTAssertEqual(
            SubtitleLanguageCatalog.displayName(
                forCode: "en",
                in: Locale(identifier: "es")
            ),
            "inglés"
        )
        XCTAssertEqual(
            SubtitleLanguageCatalog.displayName(
                forCode: "es",
                in: Locale(identifier: "de")
            ),
            "Spanisch"
        )
    }

    func testThreeLetterAndRegionalCodesStillNormalize() {
        XCTAssertEqual(
            SubtitleLanguageCatalog.displayName(
                forCode: "eng",
                in: Locale(identifier: "fr")
            ),
            "anglais"
        )
        XCTAssertEqual(
            SubtitleLanguageCatalog.displayName(
                forCode: "es-MX",
                in: Locale(identifier: "es")
            ),
            "español"
        )
    }
}
