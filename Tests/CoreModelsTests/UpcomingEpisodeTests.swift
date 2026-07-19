import XCTest
@testable import CoreModels

final class UpcomingEpisodeTests: XCTestCase {
    private func sample() -> UpcomingEpisode {
        UpcomingEpisode(
            seriesIdentity: .external(source: "anilist", value: "21"),
            absoluteEpisodeNumber: 1075,
            title: nil,
            airDate: Date(timeIntervalSince1970: 1_900_000_000),
            datePrecision: .dateAndTime,
            source: .anilist,
            sourceURL: URL(string: "https://anilist.co/anime/21"),
            refreshedAt: Date(timeIntervalSince1970: 1_000_000)
        )
    }

    func testUpcomingEpisodeCodableRoundTrip() throws {
        let original = sample()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(UpcomingEpisode.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.seriesIdentity, .external(source: "anilist", value: "21"))
        XCTAssertNil(decoded.seasonNumber)
        XCTAssertEqual(decoded.absoluteEpisodeNumber, 1075)
    }

    func testReleaseStateExposesUpcomingExceptWhenPresent() {
        let up = sample()
        XCTAssertEqual(EpisodeReleaseState.upcoming(up).upcomingEpisode, up)
        XCTAssertEqual(EpisodeReleaseState.airedGracePeriod(up).upcomingEpisode, up)
        XCTAssertEqual(EpisodeReleaseState.airedMissing(up).upcomingEpisode, up)
        XCTAssertEqual(EpisodeReleaseState.requested(up).upcomingEpisode, up)

        var item = MediaItem(id: "x", title: "Ep", kind: .episode)
        item.seasonNumber = 1
        item.episodeNumber = 2
        XCTAssertNil(EpisodeReleaseState.present(item: item).upcomingEpisode)
        XCTAssertFalse(EpisodeReleaseState.present(item: item).isAbsent)
        XCTAssertTrue(EpisodeReleaseState.upcoming(up).isAbsent)
    }

    func testNextAiringEpisodeCapabilityCoversField() {
        XCTAssertEqual(MetadataCapability.covering(.nextAiringEpisode), .nextAiringEpisode)
        XCTAssertTrue(MetadataCapability.nextAiringEpisode.coveredFields.contains(.nextAiringEpisode))
    }
}
