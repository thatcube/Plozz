import XCTest
import CoreModels
@testable import FeatureHome

/// Pure-logic coverage for the env-gated imperative UIKit hero foreground's value
/// layer (``HeroForegroundModel`` / ``HeroForegroundModelBuilder``). These lock the
/// slide → visuals mapping — metadata joining, per-pill label/glyph resolution,
/// selection clamping, dots presence, spoiler masking and overview gating — with no
/// view or simulator, so the persistent renderer can stay a thin apply-in-place
/// layer over a trusted model.
final class HeroForegroundModelTests: XCTestCase {
    private typealias Builder = HeroForegroundModelBuilder
    private typealias PillInput = HeroForegroundModelBuilder.PillInput

    private func movie(
        id: String = "m1",
        title: String = "The Example",
        overview: String? = "An example overview.",
        year: Int? = 2021,
        officialRating: String? = "TV-14",
        genres: [String] = ["Action", "Drama"],
        runtime: TimeInterval? = nil,
        resumePosition: TimeInterval? = nil,
        logoURL: URL? = URL(string: "https://example.com/logo.png")
    ) -> MediaItem {
        MediaItem(
            id: id,
            title: title,
            kind: .movie,
            overview: overview,
            productionYear: year,
            officialRating: officialRating,
            genres: genres,
            runtime: runtime,
            resumePosition: resumePosition,
            logoURL: logoURL
        )
    }

    // MARK: - metadataText

    func testMetadataTextJoinsYearAndGenresWithHeroSeparator() {
        let text = Builder.metadataText(for: movie(year: 2021, genres: ["Action", "Drama"]))
        XCTAssertEqual(text, "2021  ·  Action  ·  Drama")
    }

    func testMetadataTextIsNilWhenNoComponents() {
        let bare = movie(year: nil, genres: [], runtime: nil)
        XCTAssertNil(Builder.metadataText(for: bare))
    }

    func testMetadataTextCapsGenresAtThree() {
        let item = movie(year: nil, genres: ["A", "B", "C", "D", "E"])
        XCTAssertEqual(Builder.metadataText(for: item), "A  ·  B  ·  C")
    }

    // MARK: - seasonEpisodeButtonText

    private func episode(
        id: String = "e1",
        title: String = "Pilot",
        parentTitle: String? = "Example Show",
        season: Int? = 12,
        number: Int? = 2
    ) -> MediaItem {
        MediaItem(
            id: id,
            title: title,
            kind: .episode,
            parentTitle: parentTitle,
            seasonNumber: season,
            episodeNumber: number
        )
    }

    func testSeasonEpisodeButtonTextFormatsEpisode() {
        XCTAssertEqual(Builder.seasonEpisodeButtonText(for: episode(season: 12, number: 2)), "S12, E2")
    }

    func testSeasonEpisodeButtonTextNilForMovie() {
        XCTAssertNil(Builder.seasonEpisodeButtonText(for: movie()))
    }

    func testSeasonEpisodeButtonTextNilWhenNumbersMissing() {
        XCTAssertNil(Builder.seasonEpisodeButtonText(for: episode(season: nil, number: 2)))
        XCTAssertNil(Builder.seasonEpisodeButtonText(for: episode(season: 1, number: nil)))
    }

    func testBuiltEpisodePlayPillCarriesSeasonEpisode() {
        let item = episode(season: 3, number: 7)
        let model = Builder.model(
            item: item,
            overviewVisible: true,
            maskedTitle: nil,
            pillInputs: [
                .init(kind: .play, seasonEpisodeText: Builder.seasonEpisodeButtonText(for: item))
            ],
            selectedIndex: 0,
            heroFocused: false,
            slideCount: 1,
            slideIndex: 0
        )
        XCTAssertEqual(model.pills.first?.text, "Play S3, E7")
    }

    func testEpisodeTextFallbackUsesSeriesTitle() {
        let item = episode(title: "Episode 1", parentTitle: "The Series", season: 2, number: 1)
        XCTAssertEqual(Builder.titleText(for: item, maskedTitle: nil), "The Series")
    }

    func testEpisodeTextFallbackUsesEpisodeTitleWhenSeriesTitleIsUnavailable() {
        let item = episode(title: "Episode 1", parentTitle: "  ")
        XCTAssertEqual(Builder.titleText(for: item, maskedTitle: nil), "Episode 1")
    }

    func testEpisodeTextFallbackKeepsSeriesTitleWhenEpisodeIsSpoilerMasked() {
        let item = episode(title: "Episode 1", parentTitle: "The Series")
        XCTAssertEqual(Builder.titleText(for: item, maskedTitle: "Episode 1"), "The Series")
    }

    func testEpisodeTextFallbackUsesSpoilerMaskWhenSeriesTitleIsUnavailable() {
        let item = episode(title: "Spoiler Title", parentTitle: nil)
        XCTAssertEqual(Builder.titleText(for: item, maskedTitle: "Episode 1"), "Episode 1")
    }

    // MARK: - pill(for:)

    func testPlayPillUsesPlayLabelWhenNotResumable() {
        let pill = Builder.pill(for: PillInput(kind: .play, resumeProgress: nil, isResume: false))
        XCTAssertEqual(pill.text, "Play")
        XCTAssertEqual(pill.systemImage, "play.fill")
        XCTAssertNil(pill.progress)
    }

    func testPlayPillResumeFormUsesRemainingTextAndProgress() {
        // Resume form (matches PlayResumeButtonLabel): the trailing text is the
        // remaining-time string — NOT the word "Resume" — and the inline progress
        // bar carries the resume fraction.
        let pill = Builder.pill(for: PillInput(
            kind: .play, resumeProgress: 0.42, isResume: true, resumeRemainingText: "20m"
        ))
        XCTAssertEqual(pill.text, "20m")
        XCTAssertEqual(pill.systemImage, "play.fill")
        XCTAssertEqual(pill.progress, 0.42)
    }

    func testPlayPillFallsBackToResumeWordWithoutRemainingText() {
        // Resumable but no remaining-time string: fall back to the plain titled pill
        // with no inline bar (mirrors PlayResumeButtonLabel's non-resume-form path).
        let pill = Builder.pill(for: PillInput(
            kind: .play, resumeProgress: 0.42, isResume: true, resumeRemainingText: nil
        ))
        XCTAssertEqual(pill.text, "Resume")
        XCTAssertNil(pill.progress)
    }

    // MARK: - season/episode in the Play pill

    func testSeasonEpisodeButtonTextUsesCommaForm() {
        XCTAssertEqual(Builder.seasonEpisodeButtonText(for: episode(season: 21, number: 8)), "S21, E8")
        XCTAssertNil(Builder.seasonEpisodeButtonText(for: movie()))
        XCTAssertNil(Builder.seasonEpisodeButtonText(for: episode(season: nil, number: 8)))
    }

    func testPlainPlayPillAppendsSeasonEpisode() {
        let pill = Builder.pill(for: PillInput(
            kind: .play, resumeProgress: nil, isResume: false, seasonEpisodeText: "S21, E8"
        ))
        XCTAssertEqual(pill.text, "Play S21, E8")
        XCTAssertNil(pill.progress)
    }

    func testResumePlayPillPrefixesSeasonEpisodeOntoRemaining() {
        let pill = Builder.pill(for: PillInput(
            kind: .play, resumeProgress: 0.42, isResume: true,
            resumeRemainingText: "43m", seasonEpisodeText: "S5, E12"
        ))
        XCTAssertEqual(pill.text, "S5, E12 • 43m")
        XCTAssertEqual(pill.progress, 0.42)
    }

    func testPlayPillOmitsSeasonEpisodeForMovies() {
        // No seasonEpisodeText (movie): plain "Play" and bare remaining, unchanged.
        XCTAssertEqual(Builder.pill(for: PillInput(kind: .play)).text, "Play")
        XCTAssertEqual(Builder.pill(for: PillInput(
            kind: .play, resumeProgress: 0.5, isResume: true, resumeRemainingText: "43m"
        )).text, "43m")
    }

    func testRequestPill() {
        let pill = Builder.pill(for: PillInput(kind: .request))
        XCTAssertEqual(pill.text, "Request")
        XCTAssertEqual(pill.systemImage, "plus.circle")
    }

    func testDownloadStatusPillShowsPercentWhenDownloading() {
        let pill = Builder.pill(for: PillInput(kind: .downloadStatus, downloadProgress: 0.826))
        XCTAssertEqual(pill.text, "83%")
        XCTAssertEqual(pill.progress, 0.826)
    }

    func testDownloadStatusPillShowsRequestedWhenNoProgress() {
        let pill = Builder.pill(for: PillInput(kind: .downloadStatus, downloadProgress: nil))
        XCTAssertEqual(pill.text, "Requested")
        XCTAssertNil(pill.progress)
    }

    func testMoreInfoPillIsIconOnly() {
        let pill = Builder.pill(for: PillInput(kind: .moreInfo))
        XCTAssertNil(pill.text)
        XCTAssertEqual(pill.systemImage, "info.circle")
    }

    func testWatchlistPillReflectsFavouriteState() {
        XCTAssertEqual(Builder.pill(for: PillInput(kind: .watchlist, isFavorite: true)).systemImage, "bookmark.fill")
        XCTAssertEqual(Builder.pill(for: PillInput(kind: .watchlist, isFavorite: false)).systemImage, "bookmark")
    }

    func testNextPillIsChevron() {
        XCTAssertEqual(Builder.pill(for: PillInput(kind: .next)).systemImage, "chevron.right")
    }

    // MARK: - model(...)

    func testModelMapsPillsInOrderAndClampsSelection() {
        let model = Builder.model(
            item: movie(),
            overviewVisible: true,
            maskedTitle: nil,
            pillInputs: [PillInput(kind: .play), PillInput(kind: .moreInfo)],
            selectedIndex: 9,
            heroFocused: true,
            slideCount: 3,
            slideIndex: 0
        )
        XCTAssertEqual(model.pills.map(\.kind), [.play, .moreInfo])
        XCTAssertEqual(model.selectedIndex, 1, "out-of-range selection clamps to the last pill")
        XCTAssertTrue(model.heroFocused)
    }

    func testModelClampsNegativeSelectionToZero() {
        let model = Builder.model(
            item: movie(),
            overviewVisible: true,
            maskedTitle: nil,
            pillInputs: [PillInput(kind: .play), PillInput(kind: .moreInfo)],
            selectedIndex: -5,
            heroFocused: false,
            slideCount: 1,
            slideIndex: 0
        )
        XCTAssertEqual(model.selectedIndex, 0)
    }

    func testModelSelectionIsZeroWhenNoPills() {
        let model = Builder.model(
            item: movie(),
            overviewVisible: true,
            maskedTitle: nil,
            pillInputs: [],
            selectedIndex: 3,
            heroFocused: true,
            slideCount: 1,
            slideIndex: 0
        )
        XCTAssertEqual(model.selectedIndex, 0)
        XCTAssertTrue(model.pills.isEmpty)
    }

    func testModelHasNoDotsForSingleSlide() {
        let model = Builder.model(
            item: movie(),
            overviewVisible: true,
            maskedTitle: nil,
            pillInputs: [],
            selectedIndex: 0,
            heroFocused: false,
            slideCount: 1,
            slideIndex: 0
        )
        XCTAssertNil(model.dots)
    }

    func testModelHasDotsForMultipleSlides() {
        let model = Builder.model(
            item: movie(),
            overviewVisible: true,
            maskedTitle: nil,
            pillInputs: [],
            selectedIndex: 0,
            heroFocused: false,
            slideCount: 5,
            slideIndex: 2
        )
        XCTAssertEqual(model.dots, HeroForegroundModel.Dots(count: 5, index: 2))
    }

    func testModelHidesOverviewWhenNotVisible() {
        let model = Builder.model(
            item: movie(overview: "Secret plot."),
            overviewVisible: false,
            maskedTitle: nil,
            pillInputs: [],
            selectedIndex: 0,
            heroFocused: false,
            slideCount: 1,
            slideIndex: 0
        )
        XCTAssertNil(model.overview)
    }

    func testModelShowsOverviewWhenVisible() {
        let model = Builder.model(
            item: movie(overview: "Visible plot."),
            overviewVisible: true,
            maskedTitle: nil,
            pillInputs: [],
            selectedIndex: 0,
            heroFocused: false,
            slideCount: 1,
            slideIndex: 0
        )
        XCTAssertEqual(model.overview, "Visible plot.")
    }

    func testModelPrefersMaskedTitleAndKeepsLogo() {
        let model = Builder.model(
            item: movie(title: "Real Title", logoURL: URL(string: "https://example.com/logo.png")),
            overviewVisible: false,
            maskedTitle: "Hidden Show",
            pillInputs: [],
            selectedIndex: 0,
            heroFocused: false,
            slideCount: 1,
            slideIndex: 0
        )
        XCTAssertEqual(model.title, "Hidden Show")
        XCTAssertEqual(model.logoURL, URL(string: "https://example.com/logo.png"))
    }

    func testModelCarriesRatingBadgeText() {
        let model = Builder.model(
            item: movie(officialRating: "TV-MA"),
            overviewVisible: true,
            maskedTitle: nil,
            pillInputs: [],
            selectedIndex: 0,
            heroFocused: false,
            slideCount: 1,
            slideIndex: 0
        )
        XCTAssertEqual(model.ratingBadgeText, "TV-MA")
    }

    func testModelRatingBadgeIsNilWhenUnrated() {
        let model = Builder.model(
            item: movie(officialRating: nil),
            overviewVisible: true,
            maskedTitle: nil,
            pillInputs: [],
            selectedIndex: 0,
            heroFocused: false,
            slideCount: 1,
            slideIndex: 0
        )
        XCTAssertNil(model.ratingBadgeText)
    }

    func testSeriesCarriesYearAndUsesNRWhenProviderOmitsRating() {
        let item = MediaItem(
            id: "s1",
            title: "Example Series",
            kind: .series,
            productionYear: 2024,
            officialRating: nil
        )
        XCTAssertEqual(Builder.metadataText(for: item), "2024")
        XCTAssertNil(Builder.ratingBadgeText(for: item))
    }

    // MARK: - Equatable (same value = cheap no-op skip in the coordinator)

    func testEqualInputsProduceEqualModels() {
        func make() -> HeroForegroundModel {
            Builder.model(
                item: movie(),
                overviewVisible: true,
                maskedTitle: nil,
                pillInputs: [PillInput(kind: .play, resumeProgress: 0.5, isResume: true), PillInput(kind: .moreInfo)],
                selectedIndex: 0,
                heroFocused: true,
                slideCount: 3,
                slideIndex: 1
            )
        }
        XCTAssertEqual(make(), make())
    }

    func testSelectionChangeProducesUnequalModels() {
        func make(selected: Int) -> HeroForegroundModel {
            Builder.model(
                item: movie(),
                overviewVisible: true,
                maskedTitle: nil,
                pillInputs: [PillInput(kind: .play), PillInput(kind: .moreInfo)],
                selectedIndex: selected,
                heroFocused: true,
                slideCount: 2,
                slideIndex: 0
            )
        }
        XCTAssertNotEqual(make(selected: 0), make(selected: 1))
    }
}
