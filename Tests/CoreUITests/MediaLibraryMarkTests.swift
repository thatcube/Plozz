import CoreModels
import XCTest
@testable import CoreUI

#if canImport(SwiftUI)
/// Covers which mark a card wears, because the decision is easy to get subtly
/// wrong in the direction that matters most: the informational mark must survive
/// Seerr being absent, which is the majority case and the reason it exists.
final class MediaLibraryMarkTests: XCTestCase {
    private func item(availability: MediaAvailabilityStatus?) -> MediaItem {
        var item = MediaItem(id: "1", title: "A Title", kind: .movie)
        item.availability = availability
        return item
    }

    func testOrdinaryLibraryItemIsNeverMarked() {
        // No availability at all is an ordinary library title — the overwhelming
        // majority of cards in the app must be untouched by this feature.
        XCTAssertNil(MediaLibraryMark.mark(for: item(availability: nil), seerConnected: false))
        XCTAssertNil(MediaLibraryMark.mark(for: item(availability: nil), seerConnected: true))
    }

    func testOwnedDiscoveryTitlesAreNeverMarked() {
        // A featured/discovery title the viewer DOES own resolves to a real
        // library copy and plays, so marking it would be a lie.
        for availability in [MediaAvailabilityStatus.available, .partiallyAvailable] {
            XCTAssertNil(
                MediaLibraryMark.mark(for: item(availability: availability), seerConnected: false),
                "\(availability) is owned and must not be marked"
            )
            XCTAssertNil(
                MediaLibraryMark.mark(for: item(availability: availability), seerConnected: true),
                "\(availability) is owned and must not be marked"
            )
        }
    }

    func testUnownedTitlesAreMarkedWithoutSeerr() {
        // The case this feature exists for: most people never install Seerr, and
        // an external cast credit still has to say it isn't yours.
        for availability in [MediaAvailabilityStatus.unknown, .pending, .processing, .deleted] {
            XCTAssertEqual(
                MediaLibraryMark.mark(for: item(availability: availability), seerConnected: false),
                .notInLibrary,
                "\(availability) must be flagged even with no Seerr"
            )
        }
    }

    func testSeerrUpgradesTheMarkToRequestable() {
        for availability in [MediaAvailabilityStatus.unknown, .pending, .processing, .deleted] {
            XCTAssertEqual(
                MediaLibraryMark.mark(for: item(availability: availability), seerConnected: true),
                .requestable,
                "\(availability) becomes actionable once Seerr is connected"
            )
        }
    }

    func testMarkAgreesWithTheItemPredicateItIsDerivedFrom() {
        // The mark must never disagree with `isNotInLibraryDiscovery`, which is
        // what suppresses Play/Watchlist/Watched on the detail page. A card
        // promising one thing while the page does another is the bug worth
        // guarding against.
        let cases: [MediaAvailabilityStatus?] = [
            nil, .available, .partiallyAvailable, .unknown, .pending, .processing, .deleted
        ]
        for availability in cases {
            let subject = item(availability: availability)
            XCTAssertEqual(
                MediaLibraryMark.mark(for: subject, seerConnected: false) != nil,
                subject.isNotInLibraryDiscovery,
                "mark presence must track isNotInLibraryDiscovery for \(String(describing: availability))"
            )
        }
    }

    func testIndicatorStateCarriesTheSameDecisionAsTheItem() {
        // Cards render from the narrowed `MediaPlaybackIndicatorState`, not the
        // item, so the two paths have to agree — otherwise the mark depends on
        // which view happens to draw it.
        let cases: [MediaAvailabilityStatus?] = [
            nil, .available, .partiallyAvailable, .unknown, .pending, .processing, .deleted
        ]
        for availability in cases {
            let subject = item(availability: availability)
            let state = MediaPlaybackIndicatorState(subject)
            for connected in [true, false] {
                XCTAssertEqual(
                    state.libraryMark(seerConnected: connected),
                    MediaLibraryMark.mark(for: subject, seerConnected: connected),
                    "state and item disagree for \(String(describing: availability)), seer=\(connected)"
                )
            }
        }
    }

    func testMarkSizeScalesWithTheCardRatherThanBeingFixed() {
        // The in-player cast poster is 167pt against the person page's 280, so a
        // fixed point size cannot serve both. Keep the ratio honest.
        let personPage = MediaLibraryMarkView.size(forCardWidth: 280)
        let playerCast = MediaLibraryMarkView.size(forCardWidth: 167)
        XCTAssertEqual(personPage, 42, "a standard poster keeps the watched badge's 42pt")
        XCTAssertLessThan(playerCast, personPage)
        XCTAssertEqual(playerCast / 167, personPage / 280, accuracy: 0.01)
    }
}
#endif
