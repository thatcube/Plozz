import XCTest
@testable import CoreModels

final class ExternalTitleAvailabilityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_900_000_000)
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    /// The hero line is about WHEN a title can be obtained, not where it streams.
    ///
    /// Plozz's audience runs its own server; being told a 2018 show is on Philo is
    /// not what they came to find out, and it crowded out the facts that do change
    /// what they do. The services are still shown, with their marks, under
    /// "Release & Availability".
    func testStreamingOffersAreNotHeroNews() {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let availability = ExternalTitleAvailability(
            regionCode: "US",
            releaseEvents: [
                TitleReleaseEvent(
                    kind: .digital,
                    date: now.addingTimeInterval(-86_400 * 900),
                    regionCode: "US"
                )
            ],
            watchOffers: [
                TitleWatchOffer(
                    providerID: 1,
                    providerName: "Max",
                    kind: .subscription,
                    regionCode: "US"
                ),
                TitleWatchOffer(
                    providerID: 2,
                    providerName: "Apple TV",
                    kind: .buy,
                    regionCode: "US"
                ),
            ]
        )

        XCTAssertNil(availability.primaryLine(
            now: now,
            calendar: calendar,
            locale: Locale(identifier: "en_US")
        ))
    }

    /// One service sold through several storefronts is one service. This is what
    /// keeps the row below from being four Starz tiles and no room for the rest.
    func testStorefrontVariantsCollapseToOneService() {
        for name in [
            "Starz Apple TV Channel",
            "Starz Amazon Channel",
            "Starz Roku Premium Channel",
            "Starz",
        ] {
            XCTAssertEqual(
                ExternalTitleAvailability.collapsedServiceName(name),
                "Starz",
                "\(name) should collapse to Starz"
            )
        }
        // An ad-supported TIER of a subscription is the same service too.
        XCTAssertEqual(
            ExternalTitleAvailability.collapsedServiceName("Amazon Prime Video with Ads"),
            "Amazon Prime Video"
        )
        // But a service whose own name merely ends in "Channel" is not a variant.
        XCTAssertEqual(
            ExternalTitleAvailability.collapsedServiceName("The Roku Channel"),
            "The Roku Channel"
        )
        XCTAssertEqual(ExternalTitleAvailability.collapsedServiceName("Max"), "HBO Max")
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
        XCTAssertTrue(line?.hasPrefix("Available digitally ") == true)
        XCTAssertFalse(line?.localizedCaseInsensitiveContains("streaming") == true)
    }

    /// Nor does a rental. That a decade-old film can be bought on Apple TV is not
    /// a reason to occupy the one line the hero has.
    func testRentBuyOffersAreNotHeroNews() {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let availability = ExternalTitleAvailability(
            regionCode: "US",
            releaseEvents: [],
            watchOffers: [
                TitleWatchOffer(
                    providerID: 2,
                    providerName: "Apple TV",
                    kind: .buy,
                    regionCode: "US"
                )
            ]
        )

        XCTAssertNil(availability.primaryLine(
            now: now,
            calendar: calendar,
            locale: Locale(identifier: "en_US")
        ))
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
            ))?.hasPrefix("In theaters · Available digitally ") == true
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

    /// An older film with no digital release event recorded is not still in
    /// cinemas — the event is simply missing. Anywhere to watch it is proof.
    func testTheatricalClaimYieldsToEvidenceOfDigitalAvailability() {
        let availability = ExternalTitleAvailability(
            regionCode: "US",
            releaseEvents: [
                TitleReleaseEvent(
                    kind: .theatrical,
                    date: now.addingTimeInterval(-14 * 365 * 86_400),
                    regionCode: "US"
                )
            ],
            watchOffers: [
                TitleWatchOffer(
                    providerID: 2,
                    providerName: "Apple TV",
                    kind: .buy,
                    regionCode: "US"
                )
            ]
        )

        XCTAssertNil(availability.primaryLine(
            now: now,
            calendar: calendar,
            locale: Locale(identifier: "en_US")
        ))
    }

}
