#if canImport(SwiftUI)
import XCTest
import CoreModels
@testable import CoreUI

final class EpisodeColumnPresentationTests: XCTestCase {
    func testUnwatchedEpisodeShowsIdentityRuntimeAndOverview() {
        let presentation = EpisodeColumnPresentation(
            item: episode(runtime: 2_700),
            spoilerSettings: .default
        )

        XCTAssertEqual(presentation.titleLine, "E4 · The Hidden Room")
        XCTAssertEqual(presentation.metadataText, "45m")
        XCTAssertNil(presentation.progress)
        XCTAssertFalse(presentation.isWatched)
        XCTAssertEqual(presentation.artworkTreatment, .visible)
        XCTAssertEqual(presentation.overviewTreatment, .visible)
        XCTAssertEqual(presentation.visibleOverview, "A secret is revealed.")
        XCTAssertTrue(presentation.accessibilityLabel.contains("Unwatched"))
    }

    func testInProgressEpisodeUsesRemainingTimeAndProgress() {
        let presentation = EpisodeColumnPresentation(
            item: episode(runtime: 3_600, resumePosition: 900, playedPercentage: 0.25),
            spoilerSettings: .default
        )

        XCTAssertEqual(presentation.metadataText, "45m left")
        XCTAssertEqual(presentation.progress, 0.25)
        XCTAssertFalse(presentation.isWatched)
        XCTAssertTrue(presentation.accessibilityLabel.contains("25 percent watched"))
    }

    func testWatchedEpisodeUsesWatchedStateWithoutProgress() {
        let presentation = EpisodeColumnPresentation(
            item: episode(runtime: 2_700, resumePosition: 1_000, playedPercentage: 0.4, isPlayed: true),
            spoilerSettings: .default
        )

        XCTAssertEqual(presentation.metadataText, "45m")
        XCTAssertNil(presentation.progress)
        XCTAssertTrue(presentation.isWatched)
        XCTAssertTrue(presentation.accessibilityLabel.contains("Watched"))
    }

    func testBlurModeDoesNotLeakHiddenTextToPresentationOutputs() {
        let presentation = EpisodeColumnPresentation(
            item: episode(),
            spoilerSettings: SpoilerSettings(isEnabled: true, mode: .blur)
        )

        XCTAssertEqual(presentation.titleLine, "Episode 4")
        XCTAssertEqual(presentation.artworkTreatment, .blurred)
        XCTAssertEqual(presentation.overviewTreatment, .blurred)
        XCTAssertNil(presentation.visibleOverview)
        XCTAssertTrue(
            presentation.accessibilityLabel.contains(
                EpisodeColumnPresentation.hiddenOverviewLabel
            )
        )
        XCTAssertFalse(presentation.accessibilityLabel.contains("The Hidden Room"))
        XCTAssertFalse(presentation.accessibilityLabel.contains("A secret is revealed."))
        XCTAssertFalse(presentation.debugDescription.contains("The Hidden Room"))
        XCTAssertFalse(presentation.debugDescription.contains("A secret is revealed."))
    }

    func testPlaceholderModeNeverCarriesHiddenOverview() {
        let presentation = EpisodeColumnPresentation(
            item: episode(),
            spoilerSettings: SpoilerSettings(isEnabled: true, mode: .placeholder)
        )

        XCTAssertEqual(presentation.artworkTreatment, .placeholder)
        XCTAssertEqual(presentation.overviewTreatment, .placeholder)
        XCTAssertNil(presentation.visibleOverview)
        XCTAssertFalse(presentation.accessibilityLabel.contains("A secret is revealed."))
        XCTAssertFalse(presentation.debugDescription.contains("A secret is revealed."))
    }

    func testMissingMetadataKeepsSafeEmptyValues() {
        let item = MediaItem(id: "missing", title: "", kind: .episode)
        let presentation = EpisodeColumnPresentation(
            item: item,
            spoilerSettings: .default
        )

        XCTAssertEqual(presentation.titleLine, "Episode")
        XCTAssertNil(presentation.metadataText)
        XCTAssertEqual(presentation.overviewTreatment, .missing)
        XCTAssertNil(presentation.visibleOverview)
    }

    func testAirDateAndContentRatingAreExcluded() {
        let item = MediaItem(
            id: "rated",
            title: "The Hidden Room",
            kind: .episode,
            overview: "A secret is revealed.",
            episodeNumber: 4,
            productionYear: 2026,
            officialRating: "TV-MA",
            runtime: 2_700
        )
        let presentation = EpisodeColumnPresentation(
            item: item,
            spoilerSettings: .default
        )

        XCTAssertFalse(presentation.accessibilityLabel.contains("2026"))
        XCTAssertFalse(presentation.accessibilityLabel.contains("TV-MA"))
        XCTAssertFalse(presentation.debugDescription.contains("2026"))
        XCTAssertFalse(presentation.debugDescription.contains("TV-MA"))
    }

    private func episode(
        runtime: TimeInterval? = 2_700,
        resumePosition: TimeInterval? = nil,
        playedPercentage: Double? = nil,
        isPlayed: Bool = false
    ) -> MediaItem {
        MediaItem(
            id: "episode-4",
            title: "The Hidden Room",
            kind: .episode,
            overview: "A secret is revealed.",
            parentTitle: "Example Show",
            seasonNumber: 1,
            episodeNumber: 4,
            runtime: runtime,
            resumePosition: resumePosition,
            playedPercentage: playedPercentage,
            isPlayed: isPlayed
        )
    }
}
#endif
