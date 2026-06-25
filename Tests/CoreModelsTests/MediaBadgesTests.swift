import XCTest
@testable import CoreModels

final class MediaBadgesTests: XCTestCase {
    // MARK: Resolution

    func testResolutionBadge4K() {
        let meta = MediaSourceMetadata(video: .init(width: 3840, height: 2160))
        XCTAssertEqual(meta.resolutionBadge?.label, "4K")
    }

    func testResolutionBadge1080p() {
        let meta = MediaSourceMetadata(video: .init(width: 1920, height: 1080))
        XCTAssertEqual(meta.resolutionBadge?.label, "1080p")
    }

    func testResolutionBadge720p() {
        let meta = MediaSourceMetadata(video: .init(width: 1280, height: 720))
        XCTAssertEqual(meta.resolutionBadge?.label, "720p")
    }

    func testResolutionBadgeSD() {
        let meta = MediaSourceMetadata(video: .init(width: 720, height: 480))
        XCTAssertEqual(meta.resolutionBadge?.label, "SD")
    }

    func testResolutionInfersFromWidthWhenHeightMissing() {
        // 3840 wide, no height -> ~2160 lines -> 4K.
        let meta = MediaSourceMetadata(video: .init(width: 3840, height: nil))
        XCTAssertEqual(meta.resolutionBadge?.label, "4K")
    }

    func testResolutionNilWhenNoDimensions() {
        let meta = MediaSourceMetadata(video: .init())
        XCTAssertNil(meta.resolutionBadge)
    }

    func testLetterboxedCinemaWidthClassifiesByWidth() {
        // A 2.40:1 movie mastered at full-HD width is 1920×804; keying off the
        // cropped height alone would misread it as 720p.
        let meta = MediaSourceMetadata(video: .init(width: 1920, height: 804))
        XCTAssertEqual(meta.resolutionBadge?.label, "1080p")
    }

    func testUltrawide4KClassifiesByWidth() {
        // 3840×1600 (2.40:1 UHD) is 4K despite its 1600-line height.
        let meta = MediaSourceMetadata(video: .init(width: 3840, height: 1600))
        XCTAssertEqual(meta.resolutionBadge?.label, "4K")
    }

    // MARK: Video codec badge

    func testVideoCodecBadgeHEVC() {
        let meta = MediaSourceMetadata(video: .init(codec: "hevc"))
        XCTAssertEqual(meta.videoCodecBadge?.label, "HEVC")
        XCTAssertEqual(meta.videoCodecBadge?.style, .spec)
    }

    func testVideoCodecBadgeH264() {
        let meta = MediaSourceMetadata(video: .init(codec: "h264"))
        XCTAssertEqual(meta.videoCodecBadge?.label, "H.264")
    }

    func testVideoCodecBadgeNilWithoutCodec() {
        let meta = MediaSourceMetadata(video: .init(width: 1920, height: 1080))
        XCTAssertNil(meta.videoCodecBadge)
    }

    func testTechnicalBadgesOmitCodec() {
        let meta = MediaSourceMetadata(
            video: .init(codec: "hevc", width: 1920, height: 1080, videoRange: "HDR", videoRangeType: "HDR10"),
            audio: .init(codec: "eac3", profile: "Dolby Atmos")
        )
        // The video codec (HEVC) is intentionally excluded from the headline badge
        // row; it remains available via `videoCodecBadge` for the diagnostics overlay.
        XCTAssertEqual(meta.technicalBadges.map(\.label), ["1080p", "HDR10", "Dolby Atmos"])
    }

    // MARK: Dynamic range

    func testDolbyVisionFromRangeType() {
        let meta = MediaSourceMetadata(video: .init(videoRangeType: "DOVIWithHDR10"))
        // DoVi with an HDR10 base layer advertises both badges (Plex "DoVi/HDR10").
        XCTAssertEqual(meta.dynamicRangeBadges.map(\.label), ["Dolby Vision", "HDR10"])
        XCTAssertEqual(meta.dynamicRangeBadges.first?.style, .dolby)
        XCTAssertEqual(meta.dynamicRangeBadges.last?.style, .hdr)
    }

    func testPureDolbyVisionHasNoHDR10Badge() {
        // Profile 5 DoVi has no HDR10 fallback, so it shows Dolby Vision alone.
        let meta = MediaSourceMetadata(video: .init(videoRangeType: "DOVI"))
        XCTAssertEqual(meta.dynamicRangeBadges.map(\.label), ["Dolby Vision"])
    }

    func testHDR10Plus() {
        let meta = MediaSourceMetadata(video: .init(videoRangeType: "HDR10Plus"))
        XCTAssertEqual(meta.dynamicRangeBadges.map(\.label), ["HDR10+"])
    }

    func testHDR10() {
        let meta = MediaSourceMetadata(video: .init(videoRange: "HDR", videoRangeType: "HDR10"))
        XCTAssertEqual(meta.dynamicRangeBadges.map(\.label), ["HDR10"])
    }

    func testHLG() {
        let meta = MediaSourceMetadata(video: .init(videoRangeType: "HLG"))
        XCTAssertEqual(meta.dynamicRangeBadges.map(\.label), ["HLG"])
    }

    func testGenericHDRFromCoarseRange() {
        let meta = MediaSourceMetadata(video: .init(videoRange: "HDR"))
        XCTAssertEqual(meta.dynamicRangeBadges.map(\.label), ["HDR"])
    }

    func testSDRBadgeFromExplicitToken() {
        // Jellyfin reports an explicit SDR range token.
        let meta = MediaSourceMetadata(video: .init(videoRange: "SDR"))
        XCTAssertEqual(meta.dynamicRangeBadges.map(\.label), ["SDR"])
        XCTAssertEqual(meta.dynamicRangeBadges.first?.style, .sdr)
    }

    func testSDRBadgeInferredWhenNoRangeButDimensionsKnown() {
        // Plex omits range info for SDR; a sized stream is still classified SDR.
        let meta = MediaSourceMetadata(video: .init(width: 1920, height: 1080))
        XCTAssertEqual(meta.dynamicRangeBadges.map(\.label), ["SDR"])
    }

    func testNoDynamicRangeBadgeWhenStreamHasNothingToClassify() {
        // A bare codec with no dimensions or range token stays unbadged rather
        // than asserting SDR on no evidence.
        let meta = MediaSourceMetadata(video: .init(codec: "h264"))
        XCTAssertTrue(meta.dynamicRangeBadges.isEmpty)
    }

    // MARK: Audio

    func testDolbyAtmosSuppressesChannelBadge() {
        let meta = MediaSourceMetadata(audio: .init(codec: "eac3", profile: "Dolby Atmos", channels: 8, channelLayout: "7.1"))
        XCTAssertEqual(meta.audioBadges.map(\.label), ["Dolby Atmos"])
        XCTAssertEqual(meta.audioBadges.first?.style, .dolby)
    }

    func testDTSXHeadline() {
        let meta = MediaSourceMetadata(audio: .init(codec: "dts", profile: "DTS:X", channels: 8))
        XCTAssertEqual(meta.audioBadges.map(\.label), ["DTS:X"])
    }

    func testDolbyDigitalPlusWithSurroundChannel() {
        let meta = MediaSourceMetadata(audio: .init(codec: "eac3", profile: nil, channels: 6, channelLayout: "5.1"))
        XCTAssertEqual(meta.audioBadges.map(\.label), ["Dolby Digital+"])
        XCTAssertEqual(meta.audioBadges.first?.detail, "5.1")
    }

    func testStereoProducesNoChannelBadge() {
        let meta = MediaSourceMetadata(audio: .init(codec: "aac", channels: 2, channelLayout: "stereo"))
        XCTAssertTrue(meta.audioBadges.isEmpty)
    }

    func testSurroundFromChannelCountWhenNoLayout() {
        let meta = MediaSourceMetadata(audio: .init(codec: "aac", channels: 6))
        XCTAssertEqual(meta.audioBadges.map(\.label), ["5.1"])
    }

    // MARK: Combined technical badges + gating

    func testTechnicalBadgesOrder() {
        let meta = MediaSourceMetadata(
            video: .init(width: 3840, height: 2160, videoRangeType: "DOVI"),
            audio: .init(codec: "eac3", profile: "Dolby Atmos")
        )
        XCTAssertEqual(meta.technicalBadges.map(\.label), ["4K", "Dolby Vision", "Dolby Atmos"])
    }

    func testTechnicalBadgesGatedToPlayableKinds() {
        let meta = MediaSourceMetadata(video: .init(width: 3840, height: 2160))
        let movie = MediaItem(id: "1", title: "M", kind: .movie, mediaInfo: meta)
        XCTAssertEqual(movie.technicalBadges.map(\.label), ["4K", "SDR"])

        let series = MediaItem(id: "2", title: "S", kind: .series, mediaInfo: meta)
        XCTAssertTrue(series.technicalBadges.isEmpty)
    }

    // MARK: Representative (series ← episodes) aggregation

    func testRepresentativeBadgesPicksBestOfEachCategory() {
        let episodes = [
            // 1080p SDR stereo.
            MediaItem(id: "1", title: "E1", kind: .episode,
                      mediaInfo: .init(video: .init(width: 1920, height: 1080),
                                       audio: .init(codec: "aac", channels: 2))),
            // 4K Dolby Vision, Dolby Digital+ 5.1.
            MediaItem(id: "2", title: "E2", kind: .episode,
                      mediaInfo: .init(video: .init(width: 3840, height: 2160, videoRangeType: "DOVI"),
                                       audio: .init(codec: "eac3", channels: 6, channelLayout: "5.1"))),
            // 1080p HDR10, Dolby Atmos.
            MediaItem(id: "3", title: "E3", kind: .episode,
                      mediaInfo: .init(video: .init(width: 1920, height: 1080, videoRange: "HDR", videoRangeType: "HDR10"),
                                       audio: .init(codec: "eac3", profile: "Dolby Atmos", channels: 8))),
        ]
        // 4K (best resolution), Dolby Vision (best range), Dolby Atmos (best
        // audio, which implies surround so no channel badge).
        XCTAssertEqual(episodes.representativeTechnicalBadges.map(\.label),
                       ["4K", "Dolby Vision", "Dolby Atmos"])
    }

    func testRepresentativeBadgesAddSurroundWhenFormatDoesNotImplyIt() {
        let episodes = [
            MediaItem(id: "1", title: "E1", kind: .episode,
                      mediaInfo: .init(video: .init(width: 1920, height: 1080),
                                       audio: .init(codec: "eac3", channels: 6, channelLayout: "5.1"))),
            MediaItem(id: "2", title: "E2", kind: .episode,
                      mediaInfo: .init(audio: .init(codec: "eac3", channels: 8, channelLayout: "7.1"))),
        ]
        // Dolby Digital+ doesn't imply surround, so the best channel layout (7.1)
        // is attached to it as a trailing detail. E1 is SDR, so the range summary
        // reads SDR.
        let badges = episodes.representativeTechnicalBadges
        XCTAssertEqual(badges.map(\.label), ["1080p", "SDR", "Dolby Digital+"])
        XCTAssertEqual(badges.last?.detail, "7.1")
    }

    func testRepresentativeBadgesEmptyWhenNoMediaInfo() {
        let episodes = [
            MediaItem(id: "1", title: "E1", kind: .episode),
            MediaItem(id: "2", title: "E2", kind: .episode),
        ]
        XCTAssertTrue(episodes.representativeTechnicalBadges.isEmpty)
    }

    // MARK: Rating badge

    func testRatingBadgeFromOfficialRating() {
        let item = MediaItem(id: "1", title: "M", kind: .movie, officialRating: "TV-14")
        XCTAssertEqual(item.ratingBadge?.label, "TV-14")
        XCTAssertEqual(item.ratingBadge?.style, .rating)
    }

    func testRatingBadgeNilWhenBlank() {
        let item = MediaItem(id: "1", title: "M", kind: .movie, officialRating: "   ")
        XCTAssertNil(item.ratingBadge)
    }

    // MARK: Metadata line

    func testMetadataComponentsOrderAndGenreCap() {
        let item = MediaItem(
            id: "1",
            title: "M",
            kind: .movie,
            productionYear: 2010,
            genres: ["Action", "Adventure", "Sci-Fi", "Thriller"],
            runtime: 8880 // 2h 28m
        )
        XCTAssertEqual(item.metadataComponents(), ["2010", "2h 28m", "Action", "Adventure", "Sci-Fi"])
    }

    // MARK: Card runtime text

    func testCardRuntimeTextShowsOverallRuntimeWhenNotInProgress() {
        let item = MediaItem(id: "1", title: "Movie", kind: .movie, runtime: 5400)
        XCTAssertEqual(item.cardRuntimeText, "1h 30m")
    }

    func testCardRuntimeTextShowsRemainingWhenResumePositionExists() {
        let item = MediaItem(
            id: "1",
            title: "Movie",
            kind: .movie,
            runtime: 7200,
            resumePosition: 1800
        )
        XCTAssertEqual(item.cardRuntimeText, "1h 30m left")
    }

    func testCardRuntimeTextShowsRemainingWhenOnlyPercentageExists() {
        let item = MediaItem(
            id: "1",
            title: "Episode",
            kind: .episode,
            runtime: 1800,
            playedPercentage: 0.5
        )
        XCTAssertEqual(item.cardRuntimeText, "15m left")
    }

    func testCardRuntimeTextUsesOverallWhenMarkedPlayed() {
        let item = MediaItem(
            id: "1",
            title: "Movie",
            kind: .movie,
            runtime: 7200,
            resumePosition: 1800,
            isPlayed: true
        )
        XCTAssertEqual(item.cardRuntimeText, "2h")
    }

    func testCardRuntimeTextNilForUnsupportedKinds() {
        let item = MediaItem(id: "1", title: "Library", kind: .folder, runtime: 3600)
        XCTAssertNil(item.cardRuntimeText)
    }

    // MARK: Dolby format word

    func testDolbyFormatWordStripsBrand() {
        XCTAssertEqual(MediaBadge("Dolby Atmos", style: .dolby).dolbyFormatWord, "Atmos")
        XCTAssertEqual(MediaBadge("Dolby Vision", style: .dolby).dolbyFormatWord, "Vision")
        XCTAssertEqual(MediaBadge("Dolby Digital+", style: .dolby).dolbyFormatWord, "Digital+")
    }

    func testNonDolbyFormatWordIsFullLabel() {
        XCTAssertEqual(MediaBadge("4K", style: .spec).dolbyFormatWord, "4K")
    }

    func testRuntimeBadgeText() {        XCTAssertEqual((8880 as TimeInterval).runtimeBadgeText, "2h 28m")
        XCTAssertEqual((2820 as TimeInterval).runtimeBadgeText, "47m")
        XCTAssertEqual((3600 as TimeInterval).runtimeBadgeText, "1h")
        XCTAssertNil((0 as TimeInterval).runtimeBadgeText)
    }
}
