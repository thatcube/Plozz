#if canImport(SwiftUI)
import XCTest
import CoreModels
@testable import CoreUI

final class PosterCardPresentationTests: XCTestCase {
    func testFolderUsesDedicatedArtworkWithoutPlaybackChrome() {
        XCTAssertTrue(PosterCardPresentation.usesFolderArtwork(for: .folder))
        XCTAssertFalse(PosterCardPresentation.showsWatchStatus(for: .folder))
        XCTAssertFalse(PosterCardPresentation.showsPlaybackIndicators(for: .folder))
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
