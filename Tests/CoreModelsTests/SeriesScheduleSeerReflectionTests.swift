import XCTest
@testable import CoreModels

final class SeriesScheduleSeerReflectionTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_000_000_000)

    private func upcoming(season: Int?, precision: AirDatePrecision = .dateAndTime) -> UpcomingEpisode {
        UpcomingEpisode(
            seriesIdentity: .external(source: "tvdb", value: "9"),
            seasonNumber: season, episodeNumber: season.map { _ in 4 },
            airDate: epoch, datePrecision: precision, source: .tvdb, refreshedAt: epoch)
    }

    private func availability(_ seasons: [MediaSeasonRequestState], status: MediaAvailabilityStatus = .partiallyAvailable) -> MediaRequestAvailability {
        MediaRequestAvailability(status: status, seasons: seasons)
    }

    func testNoSeerrConfiguredReflectsNothing() {
        XCTAssertNil(SeriesScheduleSeerReflection.seerStatus(for: upcoming(season: 2), availability: nil))
        XCTAssertNil(SeriesScheduleSeerReflection.requestableMissingSeason(for: upcoming(season: 2), availability: nil))
    }

    func testReflectsRequestedSeasonAsProcessing() {
        let avail = availability([
            MediaSeasonRequestState(number: 1, title: "S1", status: .available),
            MediaSeasonRequestState(number: 2, title: "S2", status: .processing),
        ])
        let status = SeriesScheduleSeerReflection.seerStatus(for: upcoming(season: 2), availability: avail)
        XCTAssertEqual(status, .processing)
        // Feeding through the state machine, an aired+missing episode becomes requested.
        let state = EpisodeReleaseStateMachine.state(
            upcoming: upcoming(season: 2), presence: EpisodePresenceIndex(ownedEpisodes: []),
            seerStatus: status, now: epoch.addingTimeInterval(10 * 3600))
        XCTAssertEqual(state, .requested(upcoming(season: 2)))
    }

    func testPartialLibraryDivergenceUsesPerSeasonStatus() {
        // Series-level partiallyAvailable, but the scheduled season 3 is still pending.
        let avail = availability([
            MediaSeasonRequestState(number: 1, title: "S1", status: .available),
            MediaSeasonRequestState(number: 3, title: "S3", status: .pending),
        ], status: .partiallyAvailable)
        XCTAssertEqual(SeriesScheduleSeerReflection.seerStatus(for: upcoming(season: 3), availability: avail), .pending)
        // A season with no per-season entry falls back to the series-level status.
        XCTAssertEqual(SeriesScheduleSeerReflection.seerStatus(for: upcoming(season: 9), availability: avail), .partiallyAvailable)
    }

    func testAbsoluteAnimeUsesSeriesLevelStatus() {
        let anime = UpcomingEpisode(
            seriesIdentity: .external(source: "anilist", value: "21"),
            absoluteEpisodeNumber: 1075, airDate: epoch, datePrecision: .dateAndTime,
            source: .anilist, refreshedAt: epoch)
        let avail = availability([], status: .processing)
        XCTAssertEqual(SeriesScheduleSeerReflection.seerStatus(for: anime, availability: avail), .processing)
        XCTAssertNil(SeriesScheduleSeerReflection.requestableMissingSeason(for: anime, availability: avail))
    }

    func testRequestableMissingSeasonOnlyWhenRequestable() {
        let avail = availability([
            MediaSeasonRequestState(number: 2, title: "S2", status: .unknown),   // requestable
            MediaSeasonRequestState(number: 3, title: "S3", status: .processing), // in flight
        ])
        XCTAssertEqual(SeriesScheduleSeerReflection.requestableMissingSeason(for: upcoming(season: 2), availability: avail), 2)
        XCTAssertNil(SeriesScheduleSeerReflection.requestableMissingSeason(for: upcoming(season: 3), availability: avail),
                     "An in-flight season must not be re-offered")
        XCTAssertNil(SeriesScheduleSeerReflection.requestableMissingSeason(for: upcoming(season: 5), availability: avail),
                     "An untracked season offers nothing")
    }
}
