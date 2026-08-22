#if canImport(SwiftUI)
import XCTest
import CoreModels
@testable import CoreUI

final class PosterCardPresentationTests: XCTestCase {
    func testFolderUsesDedicatedArtworkWithoutPlaybackChrome() {
        XCTAssertTrue(PosterCardPresentation.usesFolderArtwork(for: .folder))
        XCTAssertFalse(PosterCardPresentation.showsWatchStatus(for: .folder))
        XCTAssertFalse(PosterCardPresentation.showsPlaybackIndicators(for: .folder))
        XCTAssertEqual(PosterCardPresentation.folderIconSize(for: .poster), 48)
        XCTAssertEqual(PosterCardPresentation.folderIconOpacity(isFocused: false), 0.4)
        XCTAssertLessThan(
            PosterCardPresentation.folderIconOpacity(isFocused: true),
            0.6,
            "focused folder glyph stays subdued like a library-type watermark"
        )
    }

    func testPlayableMediaKeepsNormalPosterAndPlaybackChrome() {
        for kind in [MediaItemKind.movie, .series, .episode, .video] {
            XCTAssertFalse(PosterCardPresentation.usesFolderArtwork(for: kind))
            XCTAssertTrue(PosterCardPresentation.showsWatchStatus(for: kind))
            XCTAssertTrue(PosterCardPresentation.showsPlaybackIndicators(for: kind))
        }
    }

    func testProgressTakesPriorityOverWatchedBadge() {
        let item = MediaItem(
            id: "movie",
            title: "Movie",
            kind: .movie,
            playedPercentage: 0.5,
            isPlayed: true
        )

        XCTAssertTrue(MediaPlaybackIndicatorPresentation.showsProgress(for: MediaPlaybackIndicatorState(item)))
        XCTAssertFalse(
            MediaPlaybackIndicatorPresentation.showsWatchedBadge(
                for: MediaPlaybackIndicatorState(item),
                hidesStatus: false
            )
        )
    }

    func testUnwatchedFlagOnlyShowsBeforePlaybackStarts() {
        let untouched = MediaItem(id: "new", title: "New", kind: .episode)
        let started = MediaItem(
            id: "started",
            title: "Started",
            kind: .episode,
            resumePosition: 12
        )

        XCTAssertTrue(
            MediaPlaybackIndicatorPresentation.showsUnwatchedFlag(
                for: MediaPlaybackIndicatorState(untouched),
                hidesStatus: false
            )
        )
        XCTAssertFalse(
            MediaPlaybackIndicatorPresentation.showsUnwatchedFlag(
                for: MediaPlaybackIndicatorState(started),
                hidesStatus: false
            )
        )
    }
    // MARK: - Series-artwork title (Continue Watching)

    /// A card that draws the show's name over its artwork must never reach for an
    /// episode's own title to do it. When the series name is missing and spoiler
    /// text is hidden, the episode title is exactly the string being protected —
    /// and this mode would print it in the largest type on the card.
    func testSeriesArtworkNeverDrawsAnEpisodeTitleWhileTextIsHidden() {
        XCTAssertEqual(
            PosterCardPresentation.seriesArtworkTitleSource(
                kind: .episode,
                hasSeriesTitle: false,
                hidesText: true
            ),
            .maskedEpisode
        )
    }

    func testSeriesArtworkPrefersTheSeriesTitleWhenKnown() {
        for hidesText in [false, true] {
            XCTAssertEqual(
                PosterCardPresentation.seriesArtworkTitleSource(
                    kind: .episode,
                    hasSeriesTitle: true,
                    hidesText: hidesText
                ),
                .seriesTitle,
                "the series name is spoiler-safe either way (hidesText: \(hidesText))"
            )
        }
    }

    /// With protection off there is nothing to protect, so a nameless episode may
    /// fall back to its own title rather than showing a bare "Episode 5".
    func testSeriesArtworkFallsBackToTheOwnTitleWhenNothingIsHidden() {
        XCTAssertEqual(
            PosterCardPresentation.seriesArtworkTitleSource(
                kind: .episode,
                hasSeriesTitle: false,
                hidesText: false
            ),
            .ownTitle
        )
    }

    /// A movie or series IS the show, so its own title is the right one.
    func testSeriesArtworkUsesTheOwnTitleForNonEpisodes() {
        for kind in [MediaItemKind.movie, .series, .season] {
            XCTAssertEqual(
                PosterCardPresentation.seriesArtworkTitleSource(
                    kind: kind,
                    hasSeriesTitle: false,
                    hidesText: true
                ),
                .ownTitle,
                "kind: \(kind)"
            )
        }
    }
}
#endif
