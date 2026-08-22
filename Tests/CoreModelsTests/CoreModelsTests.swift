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
            // `userMessage` is a LocalizedStringResource now, so resolve it in an
            // explicit locale before asserting — and resolving also proves the
            // English default is actually reachable, not just declared.
            var resource = error.userMessage
            resource.locale = Locale(identifier: "en")
            XCTAssertFalse(String(localized: resource).isEmpty, "\(error) should have a message")
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

final class SubtitleStyleCodableTests: XCTestCase {
    func testCodableRoundTrip() throws {
        var style = SubtitleStyle.default
        style.followsSystemStyle = false
        style.fontScale = 1.5
        style.textColor = .yellow
        // Use a persisting edge style: `.uniform` is intentionally folded into
        // the Outline (border) control on decode, so it wouldn't round-trip as
        // an edge — that folding is covered by its own test below.
        style.edge.style = .raised

        let data = try JSONEncoder().encode(style)
        let decoded = try JSONDecoder().decode(SubtitleStyle.self, from: data)
        XCTAssertEqual(decoded, style)
    }

    func testUniformEdgeFoldsIntoOutlineOnDecode() throws {
        // Shadow and outline are two independent concerns now. A persisted style
        // (or migrated legacy data) that expressed an outline via the legacy
        // `.uniform` edge decodes into the single Outline (border) control: the
        // edge becomes `.none` and the border turns on carrying the old edge's
        // colour + thickness, so old data keeps its outline through one control.
        var style = SubtitleStyle.default
        style.border = SubtitleStyle.Border(isEnabled: false)
        style.edge = SubtitleStyle.Edge(style: .uniform, color: .yellow, thickness: 3)

        let data = try JSONEncoder().encode(style)
        let decoded = try JSONDecoder().decode(SubtitleStyle.self, from: data)

        XCTAssertEqual(decoded.edge.style, .none)
        XCTAssertTrue(decoded.border.isEnabled)
        XCTAssertEqual(decoded.border.color, .yellow)
        XCTAssertEqual(decoded.border.width, 3)
    }

    func testDefaultUsesOwnRenderer() {
        // The appearance model owns its look by default (Plozz's own renderer)
        // rather than deferring to the system caption style.
        XCTAssertFalse(SubtitleStyle.default.followsSystemStyle)
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

final class HandoffDiagnosticsRedactionTests: XCTestCase {
    func testRedactsURLsAndCredentialAssignments() {
        let raw = """
        NativeAVPlayerHost failed url=https://server.test/video?token=secret \
        Authorization:Bearer-value api_key=key-value
        """
        let redacted = HandoffDiagnostics.redactedDetail(raw)

        XCTAssertFalse(redacted.contains("server.test"))
        XCTAssertFalse(redacted.contains("secret"))
        XCTAssertFalse(redacted.contains("Bearer-value"))
        XCTAssertFalse(redacted.contains("key-value"))
        XCTAssertTrue(redacted.contains("<url>"))
        XCTAssertTrue(redacted.contains("Authorization=<redacted>"))
        XCTAssertTrue(redacted.contains("api_key=<redacted>"))
    }
}

final class ProviderKindTests: XCTestCase {
    func testDedicatedServersAreFirstClassProviders() {
        XCTAssertEqual(Set(ProviderKind.allCases), [.jellyfin, .emby, .plex, .mediaShare])
        XCTAssertEqual(ProviderKind.allCases, [.jellyfin, .plex, .emby, .mediaShare])
        XCTAssertEqual(ProviderKind.jellyfin.displayName, "Jellyfin")
        XCTAssertEqual(ProviderKind.emby.displayName, "Emby")
        XCTAssertEqual(ProviderKind.plex.displayName, "Plex")
        XCTAssertEqual(ProviderKind.mediaShare.displayName, "Media Share")
        XCTAssertTrue(ProviderKind.emby.usesMediaBrowserAPI)
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
        // `maskedTitle` returns a `LocalizedStringResource` built with the
        // episode number interpolated in ("Episode %lld" + arg), so it is not
        // `Equatable` to a plain `"Episode 7"` literal (that's key "Episode 7"
        // with no format args — a different resource). Compare the resolved
        // `String(localized:)` output instead, which is fine in a test (unlike
        // in production code, this doesn't freeze a live-displayed value) and
        // still proves the count is interpolated correctly.
        XCTAssertEqual(String(localized: enabled.maskedTitle(for: episode(number: 7))), "Episode 7")
        XCTAssertEqual(String(localized: enabled.maskedTitle(for: episode(number: nil))), "Episode")
    }

    // MARK: - Hide ratings until watched

    private let ratingsHidden = SpoilerSettings(hideRatingsUntilWatched: true)
    private func movie(played: Bool = false) -> MediaItem {
        MediaItem(id: "m", title: "Film", kind: .movie, isPlayed: played)
    }

    func testHideRatingsDefaultsOff() {
        XCTAssertFalse(SpoilerSettings.default.hideRatingsUntilWatched)
        XCTAssertFalse(SpoilerSettings.default.shouldHideRatings(for: movie()))
        XCTAssertFalse(SpoilerSettings.default.shouldHideRatings(for: episode()))
    }

    func testHideRatingsIsIndependentOfSpoilerSwitch() {
        XCTAssertTrue(ratingsHidden.shouldHideRatings(for: episode()))
        XCTAssertFalse(ratingsHidden.shouldHideThumbnail(for: episode()))
        XCTAssertFalse(ratingsHidden.shouldHideText(for: episode()))
    }

    func testHideRatingsForUnwatchedMovieAndEpisode() {
        XCTAssertTrue(ratingsHidden.shouldHideRatings(for: movie()))
        XCTAssertTrue(ratingsHidden.shouldHideRatings(for: episode()))
    }

    func testHideRatingsRevealsAfterFullyWatched() {
        XCTAssertFalse(ratingsHidden.shouldHideRatings(for: movie(played: true)))
        XCTAssertFalse(ratingsHidden.shouldHideRatings(for: episode(played: true)))
    }

    func testHideRatingsStillHiddenWhileInProgress() {
        XCTAssertTrue(ratingsHidden.shouldHideRatings(for: episode(percentage: 0.5)))
        XCTAssertTrue(ratingsHidden.shouldHideRatings(for: episode(resume: 120)))
    }

    func testHideRatingsNeverAppliesToSeriesOrSeason() {
        XCTAssertFalse(ratingsHidden.shouldHideRatings(for: MediaItem(id: "s", title: "Show", kind: .series)))
        XCTAssertFalse(ratingsHidden.shouldHideRatings(for: MediaItem(id: "se", title: "Season 1", kind: .season)))
    }

    func testDecodesLegacyPayloadWithoutHideRatingsKey() throws {
        let legacy = #"{"isEnabled":true,"mode":"placeholder"}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(SpoilerSettings.self, from: legacy)
        XCTAssertTrue(decoded.isEnabled)
        XCTAssertEqual(decoded.mode, .placeholder)
        XCTAssertFalse(decoded.hideRatingsUntilWatched)
    }

    func testHideRatingsCodableRoundTrip() throws {
        let settings = SpoilerSettings(isEnabled: true, mode: .blur, hideRatingsUntilWatched: true)
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(SpoilerSettings.self, from: data), settings)
    }
}

/// `MediaItem.seasonEpisodeLabel` — the spaced designation Continue Watching
/// draws inside its resume chip.
final class SeasonEpisodeLabelTests: XCTestCase {
    private func episode(season: Int?, number: Int?) -> MediaItem {
        MediaItem(
            id: "e",
            title: "Pilot",
            kind: .episode,
            parentTitle: "The Show",
            seasonNumber: season,
            episodeNumber: number
        )
    }

    /// Comma-separated, not dotted. The chip already joins with `·` to attach the
    /// duration, so the dotted `subtitle` form would render "S4 · E1 · 22m" and
    /// read as three unrelated facts — while a bare space runs the two numbers
    /// together as "S4 E1 · 22m".
    func testPairsTheNumbersWithACommaSoTheyReadAsOneDesignation() {
        XCTAssertEqual(episode(season: 4, number: 1).seasonEpisodeLabel, "S4, E1")
        XCTAssertEqual(episode(season: 4, number: 1).subtitle, "S4 · E1", "subtitle keeps its dotted form")
    }

    /// A half-built "S4" says nothing useful, so both numbers are required.
    func testRequiresBothNumbers() {
        XCTAssertNil(episode(season: 4, number: nil).seasonEpisodeLabel)
        XCTAssertNil(episode(season: nil, number: 1).seasonEpisodeLabel)
        XCTAssertNil(episode(season: nil, number: nil).seasonEpisodeLabel)
    }

    /// Unlike `subtitle`, it never falls back to the series title — the artwork
    /// is already showing that, and a duplicate would read as a stutter.
    func testNeverFallsBackToTheSeriesTitle() {
        let numberless = episode(season: nil, number: nil)
        XCTAssertEqual(numberless.subtitle, "The Show")
        XCTAssertNil(numberless.seasonEpisodeLabel)
    }

    func testMovieHasNoDesignation() {
        XCTAssertNil(MediaItem(id: "m", title: "Film", kind: .movie, productionYear: 1999).seasonEpisodeLabel)
    }
}
