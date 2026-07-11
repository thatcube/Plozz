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
        let candidates = MediaRowArtworkPrefetchPolicy.candidates(
            for: episode(artwork: artwork),
            style: .landscape,
            spoilerSettings: SpoilerSettings(isEnabled: true, mode: .placeholder)
        )

        XCTAssertEqual(candidates, [artwork.fallback])
        XCTAssertFalse(candidates.contains(artwork.still))
        XCTAssertFalse(candidates.contains(artwork.backdrop))
    }

    func testBlurModePrefetchesRealArtworkNeededForBlur() {
        let artwork = artworkURLs()
        XCTAssertEqual(
            MediaRowArtworkPrefetchPolicy.candidates(
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
            MediaRowArtworkPrefetchPolicy.candidates(
                for: episode(artwork: artwork, isPlayed: true),
                style: .landscape,
                spoilerSettings: SpoilerSettings(isEnabled: true, mode: .placeholder)
            ),
            [artwork.still, artwork.backdrop]
        )
    }

    private typealias ArtworkURLs = (still: URL, backdrop: URL, fallback: URL)

    private func artworkURLs() -> ArtworkURLs {
        (
            URL(string: "https://example.com/episode-still.jpg")!,
            URL(string: "https://example.com/episode-backdrop.jpg")!,
            URL(string: "https://example.com/series-fallback.jpg")!
        )
    }

    private func episode(artwork: ArtworkURLs, isPlayed: Bool = false) -> MediaItem {
        MediaItem(
            id: "episode-8",
            title: "Finale",
            kind: .episode,
            isPlayed: isPlayed,
            posterURL: artwork.still,
            backdropURL: artwork.backdrop,
            fallbackArtworkURL: artwork.fallback
        )
    }
}
#endif
