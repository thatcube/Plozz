import XCTest
@testable import CoreModels

final class ExternalTitleAvailabilityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_900_000_000)
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    func testStreamingOfferWinsOverHistoricalReleaseDate() {
        let availability = ExternalTitleAvailability(
            regionCode: "US",
            releaseEvents: [
                TitleReleaseEvent(
                    kind: .theatrical,
                    date: now.addingTimeInterval(-86_400),
                    regionCode: "US"
                )
            ],
            watchOffers: [
                TitleWatchOffer(
                    providerID: 1,
                    providerName: "Max",
                    kind: .subscription,
                    regionCode: "US"
                )
            ]
        )

        XCTAssertTrue(
            english(availability.primaryLine(
                now: now,
                calendar: calendar,
                locale: Locale(identifier: "en_US")
            ))?.hasPrefix("Streaming on Max") == true
        )
    }

    func testFutureDigitalDateIsNotCalledStreaming() {
        let availability = ExternalTitleAvailability(
            regionCode: "US",
            releaseEvents: [
                TitleReleaseEvent(
                    kind: .digital,
                    date: now.addingTimeInterval(7 * 86_400),
                    regionCode: "US"
                )
            ]
        )

        let line = english(availability.primaryLine(
            now: now,
            calendar: calendar,
            locale: Locale(identifier: "en_US")
        ))
        XCTAssertTrue(line?.hasPrefix("Digital ") == true)
        XCTAssertFalse(line?.localizedCaseInsensitiveContains("streaming") == true)
    }

    func testRentBuyOfferUsesDigitalVocabularyAndProviderName() {
        let availability = ExternalTitleAvailability(
            regionCode: "US",
            watchOffers: [
                TitleWatchOffer(
                    providerID: 2,
                    providerName: "Apple TV",
                    kind: .rent,
                    regionCode: "US"
                )
            ]
        )

        XCTAssertEqual(
            english(availability.primaryLine(
                now: now,
                calendar: calendar,
                locale: Locale(identifier: "en_US")
            )),
            "Digital on Apple TV"
        )
    }

    func testPastTheatricalReleaseWithoutDigitalEvidenceSaysOnlyInTheaters() {
        let availability = ExternalTitleAvailability(
            regionCode: "US",
            releaseEvents: [
                TitleReleaseEvent(
                    kind: .theatrical,
                    date: now.addingTimeInterval(-30 * 86_400),
                    regionCode: "US"
                )
            ]
        )

        XCTAssertEqual(
            english(availability.primaryLine(
                now: now,
                calendar: calendar,
                locale: Locale(identifier: "en_US")
            )),
            "Only in theaters"
        )
    }

    func testPastTheatricalAndFutureDigitalAreCombinedCompactly() {
        let availability = ExternalTitleAvailability(
            regionCode: "US",
            releaseEvents: [
                TitleReleaseEvent(
                    kind: .theatrical,
                    date: now.addingTimeInterval(-14 * 86_400),
                    regionCode: "US"
                ),
                TitleReleaseEvent(
                    kind: .digital,
                    date: now.addingTimeInterval(7 * 86_400),
                    regionCode: "US"
                ),
            ]
        )

        XCTAssertTrue(
            english(availability.primaryLine(
                now: now,
                calendar: calendar,
                locale: Locale(identifier: "en_US")
            ))?.hasPrefix("In theaters · Digital ") == true
        )
    }

    func testTheatricalStateHasNoArbitraryExpiry() {
        let availability = ExternalTitleAvailability(
            regionCode: "US",
            releaseEvents: [
                TitleReleaseEvent(
                    kind: .theatrical,
                    date: now.addingTimeInterval(-180 * 86_400),
                    regionCode: "US"
                )
            ]
        )

        XCTAssertEqual(
            english(availability.primaryLine(
                now: now,
                calendar: calendar,
                locale: Locale(identifier: "en_US")
            )),
            "Only in theaters"
        )
    }

    private func english(_ resource: LocalizedStringResource?) -> String? {
        resource.map { String(localized: $0) }
    }
}
