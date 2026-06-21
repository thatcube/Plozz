import XCTest
@testable import CoreModels

final class MediaItemTests: XCTestCase {
    func testEpisodeSubtitleShowsSeasonAndEpisode() {
        let item = MediaItem(id: "1", title: "Pilot", kind: .episode, seasonNumber: 1, episodeNumber: 3)
        XCTAssertEqual(item.subtitle, "S1 · E3")
    }

    func testMovieSubtitleFallsBackToYear() {
        let item = MediaItem(id: "1", title: "Movie", kind: .movie, productionYear: 1999)
        XCTAssertEqual(item.subtitle, "1999")
    }

    func testParentTitlePreferredOverYearWhenNoEpisodeInfo() {
        let item = MediaItem(id: "1", title: "Item", kind: .episode, parentTitle: "Show", productionYear: 2001)
        XCTAssertEqual(item.subtitle, "Show")
    }
}

final class AppErrorTests: XCTestCase {
    func testAllErrorsProduceNonEmptyUserMessage() {
        let cases: [AppError] = [
            .serverUnreachable, .invalidResponse, .unauthorized, .notFound,
            .quickConnectUnavailable, .quickConnectExpired, .cancelled, .decoding, .unknown("x")
        ]
        for error in cases {
            XCTAssertFalse(error.userMessage.isEmpty, "\(error) should have a message")
        }
    }
}

final class LoadStateTests: XCTestCase {
    func testLoadedExposesValue() {
        let state: LoadState<Int> = .loaded(42)
        XCTAssertEqual(state.value, 42)
        XCTAssertFalse(state.isLoading)
    }

    func testLoadingFlag() {
        let state: LoadState<Int> = .loading
        XCTAssertNil(state.value)
        XCTAssertTrue(state.isLoading)
    }
}

final class CaptionSettingsTests: XCTestCase {
    func testCodableRoundTrip() throws {
        var settings = CaptionSettings.default
        settings.followsSystemStyle = false
        settings.fontScale = 1.5
        settings.textColor = .yellow
        settings.edgeStyle = .uniform

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(CaptionSettings.self, from: data)
        XCTAssertEqual(decoded, settings)
    }

    func testDefaultFollowsSystemStyle() {
        XCTAssertTrue(CaptionSettings.default.followsSystemStyle)
    }
}

final class UserSessionRedactionTests: XCTestCase {
    func testDescriptionRedactsToken() {
        let session = UserSession(
            server: MediaServer(id: "s", name: "Home", baseURL: URL(string: "http://x")!, provider: .jellyfin),
            userID: "u", userName: "Alice", deviceID: "d", accessToken: "SUPERSECRET"
        )
        XCTAssertFalse(session.description.contains("SUPERSECRET"))
        XCTAssertTrue(session.description.contains("<redacted>"))
    }
}

final class SpoilerSettingsTests: XCTestCase {
    private let enabled = SpoilerSettings(isEnabled: true, mode: .blur)

    private func episode(played: Bool = false, percentage: Double? = nil, resume: TimeInterval? = nil, number: Int? = 4) -> MediaItem {
        MediaItem(
            id: "e", title: "The Big Twist", kind: .episode,
            episodeNumber: number, resumePosition: resume,
            playedPercentage: percentage, isPlayed: played
        )
    }

    func testCodableRoundTrip() throws {
        let settings = SpoilerSettings(isEnabled: true, mode: .placeholder)
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(SpoilerSettings.self, from: data)
        XCTAssertEqual(decoded, settings)
    }

    func testDefaultIsDisabledAndBlur() {
        XCTAssertFalse(SpoilerSettings.default.isEnabled)
        XCTAssertEqual(SpoilerSettings.default.mode, .blur)
    }

    func testDisabledHidesNothing() {
        let item = episode()
        XCTAssertFalse(SpoilerSettings.default.shouldHideThumbnail(for: item))
        XCTAssertFalse(SpoilerSettings.default.shouldHideText(for: item))
    }

    func testMovieIsNeverHidden() {
        let movie = MediaItem(id: "m", title: "Film", kind: .movie)
        XCTAssertFalse(enabled.shouldHideThumbnail(for: movie))
        XCTAssertFalse(enabled.shouldHideText(for: movie))
    }

    func testSeriesIsNeverHidden() {
        let series = MediaItem(id: "s", title: "Show", kind: .series)
        XCTAssertFalse(enabled.shouldHideThumbnail(for: series))
        XCTAssertFalse(enabled.shouldHideText(for: series))
    }

    func testPlayedEpisodeIsRevealed() {
        let item = episode(played: true)
        XCTAssertFalse(enabled.shouldHideThumbnail(for: item))
        XCTAssertFalse(enabled.shouldHideText(for: item))
    }

    func testUnwatchedEpisodeHidesBoth() {
        let item = episode()
        XCTAssertTrue(enabled.shouldHideThumbnail(for: item))
        XCTAssertTrue(enabled.shouldHideText(for: item))
    }

    func testInProgressByPercentageRevealsThumbnailButHidesText() {
        let item = episode(percentage: 0.3)
        XCTAssertFalse(enabled.shouldHideThumbnail(for: item))
        XCTAssertTrue(enabled.shouldHideText(for: item))
    }

    func testInProgressByResumePositionRevealsThumbnailButHidesText() {
        let item = episode(percentage: nil, resume: 120)
        XCTAssertFalse(enabled.shouldHideThumbnail(for: item))
        XCTAssertTrue(enabled.shouldHideText(for: item))
    }

    func testNegligiblePercentageIsStillUnwatched() {
        let item = episode(percentage: 0.005)
        XCTAssertTrue(enabled.shouldHideThumbnail(for: item))
        XCTAssertTrue(enabled.shouldHideText(for: item))
    }

    func testMaskedTitleUsesEpisodeNumber() {
        XCTAssertEqual(enabled.maskedTitle(for: episode(number: 7)), "Episode 7")
        XCTAssertEqual(enabled.maskedTitle(for: episode(number: nil)), "Episode")
    }
}
