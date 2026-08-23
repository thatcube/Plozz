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

/// Which artwork already has the show's name printed on it.
///
/// A poster is designed to be seen alone, so it is designed to name itself.
/// Laying our own wordmark over one prints the title twice — which is what the
/// "Let's go KAIKIGUMI" and "Black Cat and a Witch" cards were doing, because
/// those series have no untitled wide art and the poster is all there is.
final class TitleBearingArtworkTests: XCTestCase {

    private func url(_ s: String) -> URL { URL(string: s)! }

    /// An episode's *series poster* names the show, so a card that falls back to
    /// it must not name it again.
    func testSeriesPosterCountsAsTitleBearing() {
        let episode = MediaItem(
            id: "e", title: "Episode 7", kind: .episode,
            seriesPosterURL: url("https://example.test/series-poster.jpg")
        )
        XCTAssertTrue(
            PosterCardPresentation.titleBearingArtwork(for: episode)
                .contains(.remote(url("https://example.test/series-poster.jpg")))
        )
    }

    /// A backdrop is not key art and is left alone — this is the common case, and
    /// the one that must keep its logo.
    func testBackdropIsNotTitleBearing() {
        let episode = MediaItem(
            id: "e", title: "Episode 7", kind: .episode,
            seriesPosterURL: url("https://example.test/series-poster.jpg"),
            backdropURL: url("https://example.test/backdrop.jpg"),
            fallbackArtworkURL: url("https://example.test/series-backdrop.jpg")
        )
        let titled = PosterCardPresentation.titleBearingArtwork(for: episode)
        XCTAssertFalse(titled.contains(.remote(url("https://example.test/backdrop.jpg"))))
        XCTAssertFalse(titled.contains(.remote(url("https://example.test/series-backdrop.jpg"))))
    }

    /// A movie or series *is* the show, so its own poster is the one that names it.
    func testOwnPosterCountsForAMovie() {
        let movie = MediaItem(
            id: "m", title: "A Movie", kind: .movie,
            posterURL: url("https://example.test/poster.jpg")
        )
        XCTAssertTrue(
            PosterCardPresentation.titleBearingArtwork(for: movie)
                .contains(.remote(url("https://example.test/poster.jpg")))
        )
    }

    /// An episode's OWN poster is its still, not the show's key art, so it names
    /// nothing and must not suppress the logo.
    func testEpisodeOwnPosterIsNotTreatedAsKeyArt() {
        let episode = MediaItem(
            id: "e", title: "Episode 7", kind: .episode,
            posterURL: url("https://example.test/episode-still.jpg")
        )
        XCTAssertFalse(
            PosterCardPresentation.titleBearingArtwork(for: episode)
                .contains(.remote(url("https://example.test/episode-still.jpg")))
        )
    }

    /// An item with no artwork at all suppresses nothing.
    func testNoArtworkSuppressesNothing() {
        let bare = MediaItem(id: "x", title: "Bare", kind: .series)
        XCTAssertTrue(PosterCardPresentation.titleBearingArtwork(for: bare).isEmpty)
    }
}

/// The blanket "an anime's backdrop is titled" rule was tried and reverted, and
/// these pin the revert so it is not re-derived from the same reasoning. Whether
/// a backdrop has the title burned into it is a fact about the pixels, and the
/// genre/id test that stood in for it was wrong in both directions at once.
final class AnimeBackdropKeepsItsLogoTests: XCTestCase {

    private func url(_ s: String) -> URL { URL(string: s)! }

    private func animeEpisode() -> MediaItem {
        MediaItem(
            id: "e", title: "Episode 7", kind: .episode,
            genres: ["Anime"],
            fallbackArtworkURL: url("https://example.test/series-backdrop.jpg")
        )
    }

    /// The false-positive half of the reverted rule. "Arcane" carries an anime
    /// label but has an ordinary textless backdrop, and the rule took its logo
    /// away — a card the viewer had no complaint about before.
    func testAnimeLabelledBackdropIsNotTreatedAsTitled() {
        XCTAssertFalse(
            PosterCardPresentation.titleBearingArtwork(for: animeEpisode())
                .contains(.remote(url("https://example.test/series-backdrop.jpg")))
        )
    }

    /// Recognised-by-provider-id was the wider half of the same test, and is
    /// equally not evidence about the picture.
    func testAnimeProviderIDBackdropIsNotTreatedAsTitled() {
        let byID = MediaItem(
            id: "e", title: "Episode 7", kind: .episode,
            fallbackArtworkURL: url("https://example.test/b.jpg"),
            providerIDs: ["AniList": "12345"]
        )
        XCTAssertFalse(
            PosterCardPresentation.titleBearingArtwork(for: byID)
                .contains(.remote(url("https://example.test/b.jpg")))
        )
    }

    /// Live action was never affected, and still isn't — the rule that survives
    /// is about slots, and a backdrop slot is a backdrop slot either way.
    func testLiveActionBackdropIsUnaffected() {
        let liveAction = MediaItem(
            id: "e", title: "Episode 7", kind: .episode,
            genres: ["Drama"],
            fallbackArtworkURL: url("https://example.test/series-backdrop.jpg")
        )
        XCTAssertFalse(
            PosterCardPresentation.titleBearingArtwork(for: liveAction)
                .contains(.remote(url("https://example.test/series-backdrop.jpg")))
        )
    }

    /// What does survive: an anime's *poster* still names itself, exactly as a
    /// live-action one does. The slot rule is unchanged by the revert.
    func testAnimePosterIsStillTitleBearing() {
        let withPoster = MediaItem(
            id: "e", title: "Episode 7", kind: .episode,
            genres: ["Anime"],
            seriesPosterURL: url("https://example.test/series-poster.jpg")
        )
        XCTAssertTrue(
            PosterCardPresentation.titleBearingArtwork(for: withPoster)
                .contains(.remote(url("https://example.test/series-poster.jpg")))
        )
    }
}

/// Continue Watching draws the show's logo over the show's picture, so it wants a
/// picture with no lettering in it. Since no metadata field says whether a given
/// backdrop has words baked in, the card asks for art that is textless by
/// construction instead of guessing — these pin how that answer is used.
final class TextlessBackdropPreferenceTests: XCTestCase {

    private func url(_ s: String) -> URL { URL(string: s)! }

    private var ladder: [ArtworkReference] {
        [
            .remote(url("https://server.test/backdrop.jpg")),
            .remote(url("https://server.test/poster.jpg")),
        ]
    }

    /// No answer yet is the common case on a cold launch, and must cost nothing:
    /// the card falls back to exactly the ladder it had before.
    func testNoTextlessAnswerLeavesTheLadderUntouched() {
        XCTAssertEqual(PosterCardPresentation.preferringTextless(nil, over: ladder), ladder)
    }

    /// The clean picture leads, and the server's art stays behind it — "textless"
    /// describes the URL we resolved, not a promise that it loads, and a blank
    /// card is worse than a doubled title.
    func testTextlessLeadsButServerArtIsKeptAsBackup() {
        let clean = url("https://tmdb.test/textless.jpg")
        let ordered = PosterCardPresentation.preferringTextless(clean, over: ladder)
        XCTAssertEqual(ordered.first, .remote(clean))
        XCTAssertEqual(ordered.count, ladder.count + 1)
        for reference in ladder {
            XCTAssertTrue(ordered.contains(reference), "dropped \(reference)")
        }
    }

    /// The resolved backdrop is sometimes the very picture the server was already
    /// serving. Naming it twice would make the retry loop try it twice before
    /// moving on, turning one dead URL into two wasted passes.
    func testAnAnswerAlreadyInTheLadderIsNotListedTwice() {
        let shared = url("https://server.test/backdrop.jpg")
        let ordered = PosterCardPresentation.preferringTextless(shared, over: ladder)
        XCTAssertEqual(ordered.first, .remote(shared))
        XCTAssertEqual(ordered.count, ladder.count)
        XCTAssertEqual(ordered.filter { $0 == .remote(shared) }.count, 1)
    }
}

/// Continue Watching is one card per show, so the store has to answer per show.
@MainActor
final class TextlessBackdropStoreKeyTests: XCTestCase {

    /// Keying an episode by its own id would ask the router once per episode for
    /// one answer that belongs to the series — and would miss the cache every
    /// time the viewer advanced an episode.
    func testEpisodesAreKeyedByTheirSeries() {
        let first = MediaItem(id: "ep1", title: "E1", kind: .episode, seriesID: "show")
        let second = MediaItem(id: "ep2", title: "E2", kind: .episode, seriesID: "show")
        XCTAssertEqual(TextlessBackdropStore.key(for: first), "show")
        XCTAssertEqual(TextlessBackdropStore.key(for: second), "show")
    }

    /// An episode with no series id still has to key to something stable.
    func testAnOrphanEpisodeFallsBackToItsOwnID() {
        let orphan = MediaItem(id: "ep1", title: "E1", kind: .episode)
        XCTAssertEqual(TextlessBackdropStore.key(for: orphan), "ep1")
    }

    /// A movie or series already *is* the show, so it keys to itself.
    func testAMovieKeysToItself() {
        let movie = MediaItem(id: "m1", title: "Movie", kind: .movie)
        XCTAssertEqual(TextlessBackdropStore.key(for: movie), "m1")
    }

    /// Nothing is published until the picture behind it is decoded, so a store
    /// that has not been warmed answers nil rather than a URL a card would have
    /// to wait on.
    func testAnUnwarmedStoreAnswersNothing() {
        let store = TextlessBackdropStore()
        XCTAssertNil(store.backdrop(for: MediaItem(id: "m1", title: "Movie", kind: .movie)))
    }
}

/// When no textless art exists anywhere, the picture we are left with is the
/// server's promotional key art — which is where burned-in titles live.
@MainActor
final class TextlessBackdropSuppressionTests: XCTestCase {

    private func anime() -> MediaItem {
        MediaItem(id: "s1", title: "Some Anime", kind: .series, genres: ["Anime"])
    }

    private func liveAction() -> MediaItem {
        MediaItem(id: "s2", title: "Some Drama", kind: .series, genres: ["Drama"])
    }

    /// The whole point of the tri-state. "Haven't heard back" must never license
    /// taking a logo away — that is indistinguishable from a slow network, and
    /// acting on it is how a card loses a logo it should have kept.
    func testAnUnansweredShowKeepsItsLogo() {
        let store = TextlessBackdropStore()
        XCTAssertFalse(store.suppressesLogo(for: anime()))
    }

    /// Live action is out of scope whatever its artwork situation, so the mass
    /// logo loss from the reverted genre rule cannot recur through this path.
    func testLiveActionKeepsItsLogoEvenWithNoTextlessArt() {
        let store = TextlessBackdropStore()
        store.recordForTesting(.none, for: liveAction())
        XCTAssertFalse(store.suppressesLogo(for: liveAction()))
    }

    /// A show with clean art keeps its logo — this is the condition that protects
    /// Arcane, which the genre test alone got wrong.
    func testAnimeWithTextlessArtKeepsItsLogo() {
        let store = TextlessBackdropStore()
        store.recordForTesting(.available(URL(string: "https://tmdb.test/clean.jpg")!), for: anime())
        XCTAssertFalse(store.suppressesLogo(for: anime()))
    }

    /// Both conditions together: the narrow case the row actually has.
    func testAnimeWithNoTextlessArtAnywhereDropsItsLogo() {
        let store = TextlessBackdropStore()
        store.recordForTesting(.none, for: anime())
        XCTAssertTrue(store.suppressesLogo(for: anime()))
    }

    /// Body runs on every focus move, so a decision that could flip mid-life would
    /// pull a logo off a card being looked at. First answer wins for the session.
    func testTheFirstDecisionIsKeptEvenWhenTheAnswerArrivesLater() {
        let store = TextlessBackdropStore()
        XCTAssertFalse(store.suppressesLogo(for: anime()))
        store.recordForTesting(.none, for: anime())
        XCTAssertFalse(
            store.suppressesLogo(for: anime()),
            "a late conclusive miss must not retro-actively strip a logo already on screen"
        )
    }
}
