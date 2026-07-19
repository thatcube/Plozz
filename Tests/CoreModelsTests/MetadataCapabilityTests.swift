import XCTest
@testable import CoreModels

final class MetadataCapabilityTests: XCTestCase {
    func testCoveringMapsArtworkFields() {
        XCTAssertEqual(MetadataCapability.covering(.posterURL), .poster)
        XCTAssertEqual(MetadataCapability.covering(.backdropURL), .backdrop)
        XCTAssertEqual(MetadataCapability.covering(.homeHero), .backdrop)
        XCTAssertEqual(MetadataCapability.covering(.detailBackdrop), .backdrop)
        XCTAssertEqual(MetadataCapability.covering(.logoURL), .logo)
        XCTAssertEqual(MetadataCapability.covering(.episodeThumbnail), .episodeStill)
    }

    func testCoveringMapsTextAndTagline() {
        XCTAssertEqual(MetadataCapability.covering(.overview), .canonicalText)
        XCTAssertEqual(MetadataCapability.covering(.genres), .canonicalText)
        XCTAssertEqual(MetadataCapability.covering(.title), .canonicalText)
        XCTAssertEqual(MetadataCapability.covering(.taglines), .tagline)
        XCTAssertEqual(MetadataCapability.covering(.ratings), .ratings)
    }

    func testCoveringMapsAnyProviderIDToExternalIDs() {
        XCTAssertEqual(MetadataCapability.covering(.providerID("Imdb")), .externalIDs)
        XCTAssertEqual(MetadataCapability.covering(.providerID("AniList")), .externalIDs)
    }

    func testCoveredFieldsRoundTrip() {
        XCTAssertTrue(MetadataCapability.backdrop.coveredFields.contains(.homeHero))
        XCTAssertTrue(MetadataCapability.backdrop.coveredFields.contains(.detailBackdrop))
        XCTAssertTrue(MetadataCapability.canonicalText.coveredFields.contains(.overview))
        XCTAssertFalse(MetadataCapability.poster.coveredFields.contains(.overview))
    }
}
