import XCTest
import CoreModels
@testable import TopShelfKit

/// Covers the line a half-watched shelf card carries beside its progress bar.
///
/// A Top Shelf card is a name and a picture. For a row of things someone is
/// part-way through, that says what they are and nothing about where they got to
/// — and tvOS draws its own progress only on `.hdtv` cards, never on posters, so
/// anything a poster says has to be painted into the artwork.
final class TopShelfResumeChipTests: XCTestCase {

    private func episode(season: Int?, number: Int?, runtime: TimeInterval?, resume: TimeInterval?) -> MediaItem {
        MediaItem(
            id: "1",
            title: "An Episode",
            kind: .episode,
            parentTitle: "A Show",
            seasonNumber: season,
            episodeNumber: number,
            runtime: runtime,
            resumePosition: resume
        )
    }

    func testAnEpisodeNamesItsPlaceAndWhatIsLeft() {
        let chip = TopShelfPublisher.resumeChipText(
            for: episode(season: 1, number: 1, runtime: 3_600, resume: 2_340)
        )
        XCTAssertEqual(chip, "S1 · E1 · 21m")
    }

    /// A movie has no episode numbering, so it says only what is left rather than
    /// padding the line with something it does not have.
    func testAMovieSaysOnlyWhatIsLeft() {
        var movie = MediaItem(id: "2", title: "A Film", kind: .movie, runtime: 7_200, resumePosition: 3_600)
        movie.productionYear = 1999
        XCTAssertEqual(TopShelfPublisher.resumeChipText(for: movie), "1h")
    }

    /// Some servers never report a runtime, so there is no remaining time to
    /// state. The episode numbering is still worth saying on its own.
    func testAnEpisodeWithNoRuntimeStillNamesItsPlace() {
        let chip = TopShelfPublisher.resumeChipText(
            for: episode(season: 2, number: 5, runtime: nil, resume: 600)
        )
        XCTAssertEqual(chip, "S2 · E5")
    }

    /// Nothing to say beats an empty chip drawn onto the artwork.
    func testNothingToSayProducesNoChip() {
        let bare = MediaItem(id: "3", title: "Unknown", kind: .movie)
        XCTAssertNil(TopShelfPublisher.resumeChipText(for: bare))
    }

    /// The chip belongs to a title being resumed. Something never started has no
    /// place to report, and would otherwise read as though it did.
    func testAnUnstartedEpisodeReportsNoRemainingTime() {
        let chip = TopShelfPublisher.resumeChipText(
            for: episode(season: 1, number: 3, runtime: 3_600, resume: nil)
        )
        XCTAssertEqual(chip, "S1 · E3", "No position means nothing is left to say about one")
    }
}
