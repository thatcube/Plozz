import CoreModels
@testable import FeatureHomeCore
import MetadataKit
import XCTest

final class RelatedEntryTests: XCTestCase {
    func testContinuationCueFollowsRelationNotTitleOrLibraryMatch() {
        let item = MediaItem(id: "owned", title: "Sequel", kind: .movie)
        let continuation = RelatedEntry(
            related: RelatedTitle(
                title: "Sequel",
                kind: .movie,
                relation: .continuation,
                source: .tmdb
            ),
            libraryItem: item
        )
        let sideStory = RelatedEntry(
            related: RelatedTitle(
                title: "Side Story",
                kind: .movie,
                relation: .sideStory,
                source: .tmdb
            ),
            libraryItem: item
        )
        let recommendation = RelatedEntry(
            related: RelatedTitle(
                title: "Similar",
                kind: .movie,
                relation: .recommendation,
                source: .tmdb
            ),
            libraryItem: item
        )

        XCTAssertTrue(continuation.isContinuation)
        XCTAssertTrue(sideStory.isContinuation)
        XCTAssertFalse(recommendation.isContinuation)
    }
}
