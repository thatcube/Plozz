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
