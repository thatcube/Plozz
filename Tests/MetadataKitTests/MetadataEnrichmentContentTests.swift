import CoreModels
import XCTest
@testable import MetadataKit

final class MetadataEnrichmentContentTests: XCTestCase {
    func testCastOnlyEnrichmentIsNotCachedAsEmpty() {
        let enrichment = MetadataEnrichment(
            cast: SourcedValue(
                value: [
                    MediaPerson(id: "p1", name: "Actor", kind: "Actor")
                ],
                source: .tmdb
            )
        )
        XCTAssertFalse(enrichment.isEmpty)
        XCTAssertTrue(enrichment.filledFields.contains(.cast))
    }
}
