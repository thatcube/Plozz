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
