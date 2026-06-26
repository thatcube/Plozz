import XCTest
@testable import CoreUI

final class ArtworkImageVariantTests: XCTestCase {
    private let url = URL(string: "https://media.example.com/Items/abc/Images/Primary?maxWidth=1280")!

    func testMaxPixelSizeBoundsPerVariant() {
        // Cards are aggressively bounded; the hero is high-fidelity but still capped;
        // only `.original` decodes at native source size.
        XCTAssertNil(ArtworkImageVariant.original.maxPixelSize)
        XCTAssertEqual(ArtworkImageVariant.musicThumbnail.maxPixelSize, 256)
        XCTAssertEqual(ArtworkImageVariant.posterCard.maxPixelSize, 960)
        XCTAssertEqual(ArtworkImageVariant.landscapeCard.maxPixelSize, 1_200)
        XCTAssertEqual(ArtworkImageVariant.heroBackdrop.maxPixelSize, 2_000)
    }

    func testCardVariantsAreSmallerThanHero() {
        // Sanity-check the size ordering the whole optimization rests on: cards must
        // never decode larger than the hero, and every bounded variant must be
        // smaller than an unbounded `.original`.
        let poster = ArtworkImageVariant.posterCard.maxPixelSize!
        let landscape = ArtworkImageVariant.landscapeCard.maxPixelSize!
        let hero = ArtworkImageVariant.heroBackdrop.maxPixelSize!
        XCTAssertLessThan(poster, hero)
        XCTAssertLessThan(landscape, hero)
        XCTAssertLessThanOrEqual(poster, landscape)
    }

    func testVariantsProduceDistinctCacheKeysForSameURL() {
        // The same source URL must be cacheable at every variant at once (an episode
        // card's small backdrop and the detail hero's large one) without collision.
        let keys = ArtworkImageVariant.allCases.map { $0.cacheKey(for: url) }
        XCTAssertEqual(Set(keys).count, keys.count)
    }

    func testCacheKeyIsStableAndContainsURL() {
        let key = ArtworkImageVariant.posterCard.cacheKey(for: url)
        XCTAssertEqual(key, ArtworkImageVariant.posterCard.cacheKey(for: url))
        XCTAssertTrue(key.contains(url.absoluteString))
    }

    func testDifferentURLsProduceDifferentKeysWithinAVariant() {
        let other = URL(string: "https://media.example.com/Items/xyz/Images/Primary")!
        XCTAssertNotEqual(
            ArtworkImageVariant.landscapeCard.cacheKey(for: url),
            ArtworkImageVariant.landscapeCard.cacheKey(for: other)
        )
    }
}
