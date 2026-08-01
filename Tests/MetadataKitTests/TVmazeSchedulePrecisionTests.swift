import XCTest
import CoreModels
@testable import MetadataKit

final class TVmazeSchedulePrecisionTests: XCTestCase {
    func testBlankAirtimeTreatsSyntheticNoonStampAsDateOnly() {
        let result = TVmazeClient.scheduleDate(
            airstamp: "2026-08-03T16:00:00+00:00",
            airdate: "2026-08-03",
            airtime: ""
        )
        XCTAssertEqual(result?.precision, .dateOnly)
    }

    func testRealAirtimeMakesAirstampSafeToLocalize() {
        let result = TVmazeClient.scheduleDate(
            airstamp: "2026-08-03T04:01:00+00:00",
            airdate: "2026-08-03",
            airtime: "00:01"
        )
        XCTAssertEqual(result?.precision, .dateAndTime)
    }

    func testMissingStampFallsBackToCalendarDate() {
        let result = TVmazeClient.scheduleDate(
            airstamp: nil,
            airdate: "2026-08-03",
            airtime: "00:01"
        )
        XCTAssertEqual(result?.precision, .dateOnly)
    }
}
