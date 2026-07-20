import CoreModels
import XCTest

final class LibrarySortDefaultsTests: XCTestCase {
    func testNameDefaultsAscending() {
        XCTAssertEqual(SortField.name.defaultDirection, .ascending)
    }

    func testNonNameFieldsDefaultDescending() {
        for field in SortField.allCases where field != .name {
            XCTAssertEqual(
                field.defaultDirection,
                .descending,
                "\(field) should put its highest/newest values first"
            )
        }
    }
}
