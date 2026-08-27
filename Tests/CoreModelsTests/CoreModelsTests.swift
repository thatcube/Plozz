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

    func testHideRatingsAppliesToSeriesAndSeason() {
        // A series page is what you read BEFORE starting a show, so its aggregate
        // score is the most spoiling number on screen, not an exempt one.
        XCTAssertTrue(ratingsHidden.shouldHideRatings(for: MediaItem(id: "s", title: "Show", kind: .series)))
        XCTAssertTrue(ratingsHidden.shouldHideRatings(for: MediaItem(id: "se", title: "Season 1", kind: .season)))
    }

    func testHideRatingsRevealsFinishedSeriesAndSeason() {
        XCTAssertFalse(ratingsHidden.shouldHideRatings(
            for: MediaItem(id: "s", title: "Show", kind: .series, isPlayed: true)
        ))
        XCTAssertFalse(ratingsHidden.shouldHideRatings(
            for: MediaItem(id: "se", title: "Season 1", kind: .season, isPlayed: true)
        ))
    }

    func testHideRatingsSkipsKindsWithNoWatchedState() {
        // Nothing to finish, so hiding would be permanent rather than deferred.
        XCTAssertFalse(ratingsHidden.shouldHideRatings(
            for: MediaItem(id: "c", title: "Marvel", kind: .collection)
        ))
        XCTAssertFalse(ratingsHidden.shouldHideRatings(
            for: MediaItem(id: "f", title: "Movies", kind: .folder)
        ))
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

/// `MediaItem.releaseDate` — the day a title came out, which every backend
/// reports differently and only one of them reports cleanly.
final class MediaItemReleaseDateTests: XCTestCase {
    /// The stored contract: UTC midnight on the day in question.
    private func utcDay(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar.date(from: components)!
    }

    // MARK: Bare calendar days (Plex `originallyAvailableAt`, TMDb via Seerr)

    func testParsesABareCalendarDayAtUTCMidnight() {
        XCTAssertEqual(
            MediaItem.calendarDayReleaseDate(from: "2019-04-14"),
            utcDay(2019, 4, 14)
        )
        XCTAssertEqual(
            MediaItem.calendarDayReleaseDate(from: "2024-02-29"),
            utcDay(2024, 2, 29),
            "leap day"
        )
    }

    /// Some agents write a full timestamp into the same attribute; the leading
    /// ten characters are the calendar day either way.
    func testParsesACalendarDayOutOfALongerTimestamp() {
        XCTAssertEqual(
            MediaItem.calendarDayReleaseDate(from: "2019-04-14T00:00:00Z"),
            utcDay(2019, 4, 14)
        )
        XCTAssertEqual(
            MediaItem.calendarDayReleaseDate(from: "  2019-04-14  "),
            utcDay(2019, 4, 14)
        )
    }

    func testRejectsUnusableCalendarDays() {
        XCTAssertNil(MediaItem.calendarDayReleaseDate(from: nil))
        XCTAssertNil(MediaItem.calendarDayReleaseDate(from: ""))
        XCTAssertNil(MediaItem.calendarDayReleaseDate(from: "2019"))
        XCTAssertNil(MediaItem.calendarDayReleaseDate(from: "not-a-date"))
        XCTAssertNil(MediaItem.calendarDayReleaseDate(from: "20190414"), "no separators")
    }

    // MARK: Shifted midnights (Jellyfin `PremiereDate`)

    /// Jellyfin stamps a bare air date with the SERVER's zone before converting
    /// to UTC, so the same premiere arrives as a different instant — and for an
    /// eastern server, a different UTC day — depending on where the server sits.
    /// Every one of these means 14 April 2019.
    func testSnapsAServerZoneShiftedMidnightBackToItsIntendedDay() {
        let intended = utcDay(2019, 4, 14)
        let cases: [(offsetHours: Int, label: String)] = [
            (0, "UTC"),
            (-5, "US Eastern"),
            (-8, "US Pacific"),
            (-11, "American Samoa"),
            (1, "Central Europe"),
            (5, "Pakistan"),
            (10, "Australian Eastern"),
            (12, "New Zealand, standard time")
        ]
        for (offsetHours, label) in cases {
            // What the server transmits: local midnight expressed in UTC.
            let transmitted = intended.addingTimeInterval(TimeInterval(-offsetHours * 3600))
            XCTAssertEqual(
                MediaItem.calendarDayReleaseDate(snapping: transmitted),
                intended,
                "\(label) (UTC\(offsetHours >= 0 ? "+" : "")\(offsetHours))"
            )
        }
    }

    /// A half-hour and three-quarter-hour zone is still a shifted midnight.
    func testSnapsOffsetsThatAreNotWholeHours() {
        let intended = utcDay(2019, 4, 14)
        for offsetMinutes in [330, -210, 345, 570] {   // India, Newfoundland, Nepal, Australia/Eucla
            let transmitted = intended.addingTimeInterval(TimeInterval(-offsetMinutes * 60))
            XCTAssertEqual(
                MediaItem.calendarDayReleaseDate(snapping: transmitted),
                intended,
                "UTC\(offsetMinutes >= 0 ? "+" : "")\(offsetMinutes)m"
            )
        }
    }

    func testSnappingLeavesACleanUTCMidnightAlone() {
        // The NFO path: Jellyfin reads those with AssumeUniversal, so they were
        // already right and the snap has to be a fixed point for them.
        XCTAssertEqual(
            MediaItem.calendarDayReleaseDate(snapping: utcDay(2019, 4, 14)),
            utcDay(2019, 4, 14)
        )
        XCTAssertNil(MediaItem.calendarDayReleaseDate(snapping: nil))
    }

    /// Exactly half a day in is a tie, and it resolves to the LATER day. That is
    /// a deliberate trade, not an oversight: the tie is where a UTC+12 midnight
    /// lands (New Zealand, Fiji, Kamchatka, the Marshall Islands — millions of
    /// people, fixed by this) and equally where a UTC−12 one lands (Baker and
    /// Howland Islands — nobody, broken by this). Flip the comparison to `>` and
    /// you swap which of those two is correct.
    func testSnappingResolvesTheMiddayTieToTheLaterDay() {
        let midday = utcDay(2019, 4, 14).addingTimeInterval(12 * 60 * 60)
        XCTAssertEqual(
            MediaItem.calendarDayReleaseDate(snapping: midday),
            utcDay(2019, 4, 15)
        )
        // One second earlier is not a tie, and stays on the earlier day.
        XCTAssertEqual(
            MediaItem.calendarDayReleaseDate(snapping: midday.addingTimeInterval(-1)),
            utcDay(2019, 4, 14)
        )
    }

    /// Pre-1970 instants are negative, so the floor has to go the same direction
    /// there as it does after the epoch — truncation would round them up.
    func testSnapsInstantsBeforeTheEpoch() {
        let intended = utcDay(1942, 8, 13)   // Bambi
        for offsetHours in [-8, 0, 10] {
            let transmitted = intended.addingTimeInterval(TimeInterval(-offsetHours * 3600))
            XCTAssertEqual(
                MediaItem.calendarDayReleaseDate(snapping: transmitted),
                intended,
                "UTC\(offsetHours >= 0 ? "+" : "")\(offsetHours)"
            )
        }
    }

    // MARK: Display

    func testFormatsTheStoredDayInUTCRegardlessOfDeviceZone() {
        // The point of storing and formatting in UTC: the label must not change
        // with where the viewer is standing.
        let label = MediaItem.releaseDateLabel(for: utcDay(2019, 4, 14))
        XCTAssertNotNil(label)
        XCTAssertTrue(label?.contains("2019") == true, label ?? "nil")
        XCTAssertNil(MediaItem.releaseDateLabel(for: nil))
    }

    func testItemLabelMirrorsTheStaticFormatter() {
        var item = MediaItem(id: "m", title: "Film", kind: .movie)
        XCTAssertNil(item.releaseDateLabel)
        item.releaseDate = utcDay(2019, 4, 14)
        XCTAssertEqual(item.releaseDateLabel, MediaItem.releaseDateLabel(for: item.releaseDate))
    }

    func testReleaseDateSurvivesACodableRoundTrip() throws {
        var item = MediaItem(id: "m", title: "Film", kind: .movie)
        item.releaseDate = utcDay(2019, 4, 14)
        let decoded = try JSONDecoder().decode(
            MediaItem.self,
            from: JSONEncoder().encode(item)
        )
        XCTAssertEqual(decoded.releaseDate, item.releaseDate)
    }

    /// Payloads cached before the field existed must still decode.
    func testDecodesLegacyPayloadWithoutAReleaseDate() throws {
        let legacy = #"{"id":"m","title":"Film","kind":"movie"}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(MediaItem.self, from: legacy)
        XCTAssertNil(decoded.releaseDate)
        XCTAssertEqual(decoded.title, "Film")
    }

    /// Folding two copies of one title must not lose a date only one of them had.
    func testFoldingDonatesAReleaseDateToACopyThatLacksOne() {
        var survivor = MediaItem(id: "a", title: "Film", kind: .movie)
        var donor = MediaItem(id: "b", title: "Film", kind: .movie)
        donor.releaseDate = utcDay(2019, 4, 14)
        survivor.fillingMissingPresentation(from: donor)
        XCTAssertEqual(survivor.releaseDate, donor.releaseDate)
    }

    func testFoldingNeverOverwritesADateTheSurvivorAlreadyHad() {
        var survivor = MediaItem(id: "a", title: "Film", kind: .movie)
        survivor.releaseDate = utcDay(2019, 4, 14)
        var donor = MediaItem(id: "b", title: "Film", kind: .movie)
        donor.releaseDate = utcDay(1999, 1, 1)
        survivor.fillingMissingPresentation(from: donor)
        XCTAssertEqual(survivor.releaseDate, utcDay(2019, 4, 14))
    }

    func testArtworkDonationTransfersProvenanceFromDonor() {
        var survivor = MediaItem(
            id: "a",
            title: "Film",
            kind: .movie
        ).taggingSource("artless-account")
        let donor = MediaItem(
            id: "b",
            title: "Film",
            kind: .movie,
            posterURL: URL(string: "https://media.example/poster.jpg")
        ).taggingSource("artwork-account")

        XCTAssertNil(survivor.artworkSourceAccountID)
        survivor.fillingMissingPresentation(from: donor)

        XCTAssertEqual(survivor.posterURL, donor.posterURL)
        XCTAssertEqual(
            survivor.artworkSourceAccountID,
            "artwork-account"
        )
    }

    func testPartialArtworkDonationKeepsPerURLProvenance() throws {
        let poster = URL(string: "https://one.example/poster.jpg")!
        let backdrop = URL(string: "https://two.example/backdrop.jpg")!
        var survivor = MediaItem(
            id: "a",
            title: "Film",
            kind: .movie,
            posterURL: poster
        ).taggingSource("poster-account")
        let donor = MediaItem(
            id: "b",
            title: "Film",
            kind: .movie,
            backdropURL: backdrop
        ).taggingSource("backdrop-account")

        survivor.fillingMissingPresentation(from: donor)

        XCTAssertEqual(
            survivor.artworkSourceAccountID(for: poster),
            "poster-account"
        )
        XCTAssertEqual(
            survivor.artworkSourceAccountID(for: backdrop),
            "backdrop-account"
        )
        XCTAssertNil(survivor.artworkSourceAccountID)
    }

    func testDonorFallbackDoesNotClaimPreexistingLegacyArtwork() {
        let poster = URL(string: "https://legacy.example/poster.jpg")!
        let backdrop = URL(string: "https://donor.example/backdrop.jpg")!
        var survivor = MediaItem(
            id: "a",
            title: "Film",
            kind: .movie,
            posterURL: poster
        )
        let donor = MediaItem(
            id: "b",
            title: "Film",
            kind: .movie,
            backdropURL: backdrop
        ).taggingSource("donor-account")

        survivor.fillingMissingPresentation(from: donor)

        XCTAssertNil(survivor.artworkSourceAccountID(for: poster))
        XCTAssertEqual(
            survivor.artworkSourceAccountID(for: backdrop),
            "donor-account"
        )
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
