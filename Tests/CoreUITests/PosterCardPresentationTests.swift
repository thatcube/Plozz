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
}
#endif
