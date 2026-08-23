#if canImport(SwiftUI)
import Foundation
import XCTest
import CoreModels
@testable import CoreUI

final class MediaRowPolicyTests: XCTestCase {
    func testEntryCallbackObservesFocusWithoutCreatingAnEntryGate() {
        XCTAssertTrue(MediaRowFocusPolicy.observesFocus(
            initialFocusID: nil,
            defaultFocusID: nil,
            hasOnFocusEntered: true,
            hasOnFocusChange: false
        ))
        XCTAssertFalse(MediaRowFocusPolicy.usesEntryGate(defaultFocusID: nil))
    }

    func testDefaultTargetObservesFocusAndCreatesAnEntryGate() {
        XCTAssertTrue(MediaRowFocusPolicy.observesFocus(
            initialFocusID: nil,
            defaultFocusID: "episode-8",
            hasOnFocusEntered: false,
            hasOnFocusChange: false
        ))
        XCTAssertTrue(MediaRowFocusPolicy.usesEntryGate(defaultFocusID: "episode-8"))
    }

    func testPlaceholderModePrefetchesOnlySpoilerSafeFallbackArtwork() {
        let artwork = artworkURLs()
        let candidates = MediaArtworkPrefetchPolicy.candidates(
            for: episode(artwork: artwork),
            style: .landscape,
            spoilerSettings: SpoilerSettings(isEnabled: true, mode: .placeholder)
        )

        XCTAssertEqual(candidates, [artwork.fallback])
        XCTAssertFalse(candidates.contains(artwork.still))
        XCTAssertFalse(candidates.contains(artwork.backdrop))
    }

    /// A landscape card wants the show's wide backdrop, keeping its vertical
    /// poster as a last resort — a cropped poster still identifies the show, and a
    /// blank card does not.
    func testPlaceholderModePrefersSeriesBackdropThenSeriesPosterOnLandscape() {
        let artwork = artworkURLs()
        let candidates = MediaArtworkPrefetchPolicy.candidates(
            for: episode(artwork: artwork, seriesPoster: artwork.seriesPoster),
            style: .landscape,
            spoilerSettings: SpoilerSettings(isEnabled: true, mode: .placeholder)
        )

        XCTAssertEqual(candidates, [artwork.fallback, artwork.seriesPoster])
        XCTAssertFalse(candidates.contains(artwork.still))
        XCTAssertFalse(candidates.contains(artwork.backdrop))
    }

    /// A poster card wants the vertical show poster first — the reverse order.
    func testPlaceholderModePrefersSeriesPosterOnAPosterCard() {
        let artwork = artworkURLs()
        let candidates = MediaArtworkPrefetchPolicy.candidates(
            for: episode(artwork: artwork, seriesPoster: artwork.seriesPoster),
            style: .poster,
            spoilerSettings: SpoilerSettings(isEnabled: true, mode: .placeholder)
        )

        XCTAssertEqual(candidates, [artwork.seriesPoster, artwork.fallback])
        XCTAssertFalse(candidates.contains(artwork.still))
    }

    /// The shape Plex and direct shares sent for years: no `fallbackArtworkURL` at
    /// all, because neither provider ever populated it. A ladder that knew only
    /// that field warmed nothing here — which is how "Placeholder Art" became a
    /// row of grey boxes on two of the three backends.
    func testPlaceholderModeStillFindsArtWithoutASeriesBackdrop() {
        let artwork = artworkURLs()
        let candidates = MediaArtworkPrefetchPolicy.candidates(
            for: episode(
                artwork: artwork,
                seriesPoster: artwork.seriesPoster,
                includesSeriesBackdrop: false
            ),
            style: .landscape,
            spoilerSettings: SpoilerSettings(isEnabled: true, mode: .placeholder)
        )

        XCTAssertEqual(candidates, [artwork.seriesPoster])
        XCTAssertFalse(candidates.contains(artwork.still),
                       "never the episode's own frame, however little else is available")
        XCTAssertFalse(candidates.contains(artwork.backdrop))
    }

    func testBlurModePrefetchesRealArtworkNeededForBlur() {
        let artwork = artworkURLs()
        XCTAssertEqual(
            MediaArtworkPrefetchPolicy.candidates(
                for: episode(artwork: artwork),
                style: .landscape,
                spoilerSettings: SpoilerSettings(isEnabled: true, mode: .blur)
            ),
            [artwork.still, artwork.backdrop]
        )
    }

    /// A poster card of an episode paints the SHOW's poster whatever the spoiler
    /// mode — there is no episode frame on it to mask — so blur mode must warm the
    /// series ladder here too, not the still it will never draw.
    func testBlurModePrefetchesSeriesArtworkOnAPosterCard() {
        let artwork = artworkURLs()
        let candidates = MediaArtworkPrefetchPolicy.candidates(
            for: episode(artwork: artwork, seriesPoster: artwork.seriesPoster),
            style: .poster,
            spoilerSettings: SpoilerSettings(isEnabled: true, mode: .blur)
        )

        XCTAssertEqual(candidates, [artwork.seriesPoster, artwork.fallback])
        XCTAssertFalse(candidates.contains(artwork.still),
                       "the episode's own frame is the one thing a poster card must never warm")
    }

    /// The mask is what changes by shape, not the rule: a landscape card really
    /// does carry the still, so blur mode keeps warming it.
    func testBlurModeStillPrefetchesTheStillOnALandscapeCard() {
        let artwork = artworkURLs()
        XCTAssertEqual(
            MediaArtworkPrefetchPolicy.candidates(
                for: episode(artwork: artwork, seriesPoster: artwork.seriesPoster),
                style: .landscape,
                spoilerSettings: SpoilerSettings(isEnabled: true, mode: .blur)
            ),
            [artwork.still, artwork.backdrop]
        )
    }

    /// A watched episode is hidden by no rule, so a poster card goes back to the
    /// ordinary ladder — the series poster first (a poster grid always wants the
    /// vertical art), but with the episode's own image restored behind it.
    func testWatchedEpisodeKeepsTheOrdinaryPosterLadder() {
        let artwork = artworkURLs()
        XCTAssertEqual(
            MediaArtworkPrefetchPolicy.candidates(
                for: episode(artwork: artwork, isPlayed: true, seriesPoster: artwork.seriesPoster),
                style: .poster,
                spoilerSettings: SpoilerSettings(isEnabled: true, mode: .blur)
            ),
            [artwork.seriesPoster, artwork.still, artwork.fallback]
        )
    }

    func testWatchedEpisodePrefetchesRealArtworkInPlaceholderMode() {
        let artwork = artworkURLs()
        XCTAssertEqual(
            MediaArtworkPrefetchPolicy.candidates(
                for: episode(artwork: artwork, isPlayed: true),
                style: .landscape,
                spoilerSettings: SpoilerSettings(isEnabled: true, mode: .placeholder)
            ),
            [artwork.still, artwork.backdrop]
        )
    }

    /// Series-artwork mode paints show art on every card whatever the watch state,
    /// so the prefetcher must warm that rather than a thumbnail the card will
    /// never draw — including for a watched episode, which no spoiler rule hides.
    func testSeriesArtworkModePrefetchesShowArtRegardlessOfWatchState() {
        let artwork = artworkURLs()
        for isPlayed in [false, true] {
            let candidates = MediaArtworkPrefetchPolicy.candidates(
                for: episode(artwork: artwork, isPlayed: isPlayed, seriesPoster: artwork.seriesPoster),
                style: .landscape,
                spoilerSettings: SpoilerSettings(isEnabled: false),
                showsSeriesArtwork: true
            )
            XCTAssertEqual(candidates, [artwork.fallback, artwork.seriesPoster])
            XCTAssertFalse(candidates.contains(artwork.still), "isPlayed: \(isPlayed)")
        }
    }

    /// A movie in Continue Watching already *is* the show, so it keeps its own
    /// art rather than being routed down the series ladder.
    func testSeriesArtworkModeLeavesNonEpisodesOnTheirOwnArtwork() {
        let backdrop = URL(string: "https://example.com/movie-backdrop.jpg")!
        let poster = URL(string: "https://example.com/movie-poster.jpg")!
        let movie = MediaItem(
            id: "movie-1",
            title: "A Movie",
            kind: .movie,
            posterURL: poster,
            backdropURL: backdrop
        )

        XCTAssertEqual(
            MediaArtworkPrefetchPolicy.candidates(
                for: movie,
                style: .landscape,
                spoilerSettings: SpoilerSettings(isEnabled: true, mode: .placeholder),
                showsSeriesArtwork: true
            ),
            [backdrop, poster]
        )
    }

    /// A movie is never a spoiler candidate, so a poster card draws its OWN
    /// poster and the prefetcher must warm that. Guards the `.episode` clause in
    /// the policy: without it, widening the spoiler rule to another kind (as
    /// `shouldHideRatings` was widened to series and seasons) would have the
    /// prefetcher warm series art for a card still drawing the item's own.
    func testPosterPolicyLeavesNonEpisodesOnTheirOwnArtwork() {
        let poster = URL(string: "https://example.com/movie-poster.jpg")!
        let fallback = URL(string: "https://example.com/movie-fallback.jpg")!
        let movie = MediaItem(
            id: "movie-1",
            title: "A Movie",
            kind: .movie,
            posterURL: poster,
            fallbackArtworkURL: fallback
        )

        for mode in [SpoilerSettings.Mode.blur, .placeholder] {
            XCTAssertEqual(
                MediaArtworkPrefetchPolicy.candidates(
                    for: movie,
                    style: .poster,
                    spoilerSettings: SpoilerSettings(isEnabled: true, mode: mode)
                ),
                [poster, fallback],
                "mode: \(mode)"
            )
        }
    }

    private typealias ArtworkURLs = (still: URL, backdrop: URL, fallback: URL, seriesPoster: URL)

    private func artworkURLs() -> ArtworkURLs {
        (
            URL(string: "https://example.com/episode-still.jpg")!,
            URL(string: "https://example.com/episode-backdrop.jpg")!,
            URL(string: "https://example.com/series-fallback.jpg")!,
            URL(string: "https://example.com/series-poster.jpg")!
        )
    }

    private func episode(
        artwork: ArtworkURLs,
        isPlayed: Bool = false,
        seriesPoster: URL? = nil,
        includesSeriesBackdrop: Bool = true
    ) -> MediaItem {
        MediaItem(
            id: "episode-8",
            title: "Finale",
            kind: .episode,
            isPlayed: isPlayed,
            posterURL: artwork.still,
            seriesPosterURL: seriesPoster,
            backdropURL: artwork.backdrop,
            fallbackArtworkURL: includesSeriesBackdrop ? artwork.fallback : nil
        )
    }
}
#endif
