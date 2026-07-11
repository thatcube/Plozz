import XCTest
#if canImport(UIKit)
import UIKit
#endif
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
        XCTAssertEqual(ArtworkImageVariant.heroPreview.maxPixelSize, 768)
        XCTAssertEqual(ArtworkImageVariant.heroBackdrop.maxPixelSize, 2_000)
    }

    func testCardVariantsAreSmallerThanHero() {
        // Sanity-check the size ordering the whole optimization rests on: cards must
        // never decode larger than the hero, and every bounded variant must be
        // smaller than an unbounded `.original`.
        let poster = ArtworkImageVariant.posterCard.maxPixelSize!
        let landscape = ArtworkImageVariant.landscapeCard.maxPixelSize!
        let preview = ArtworkImageVariant.heroPreview.maxPixelSize!
        let hero = ArtworkImageVariant.heroBackdrop.maxPixelSize!
        XCTAssertLessThan(poster, hero)
        XCTAssertLessThan(landscape, hero)
        XCTAssertLessThan(preview, hero)
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

    func testHeroPreviewRightSizesJellyfinTransferWithoutChangingCacheIdentity() {
        let source = URL(string: "https://jellyfin.example/Items/abc/Images/Backdrop?maxWidth=3840&tag=rev")!
        let request = ArtworkImageVariant.heroPreview.requestURL(for: source)

        XCTAssertEqual(
            request.absoluteString,
            "https://jellyfin.example/Items/abc/Images/Backdrop?maxWidth=768&tag=rev"
        )
        XCTAssertEqual(
            ArtworkImageVariant.heroPreview.cacheKey(for: source),
            "heroPreview|\(source.absoluteString)"
        )
    }

    func testHeroBackdropNeverUpscalesSmallerJellyfinTransfer() {
        let source = URL(string: "https://jellyfin.example/Items/abc/Images/Backdrop?maxWidth=1280")!
        XCTAssertEqual(ArtworkImageVariant.heroBackdrop.requestURL(for: source), source)
    }

    func testHeroPreviewRightSizesPlexTransferAndPreservesNestedToken() {
        let source = URL(
            string: "https://plex.example/photo/:/transcode?width=3840&height=5760&minSize=1&url=%2Flibrary%2Fmetadata%2F1%2Fart%2F2%3FX-Plex-Token%3DSECRET&X-Plex-Token=SECRET"
        )!
        let request = ArtworkImageVariant.heroPreview.requestURL(for: source)
        let components = URLComponents(url: request, resolvingAgainstBaseURL: false)
        let query = Dictionary(
            uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value) }
        )

        XCTAssertEqual(query["width"]!, "768")
        XCTAssertEqual(query["height"]!, "1152")
        XCTAssertEqual(query["url"]!, "/library/metadata/1/art/2?X-Plex-Token=SECRET")
        XCTAssertEqual(query["X-Plex-Token"]!, "SECRET")
    }

    func testHeroPreviewUsesNearestTMDbBucket() {
        let source = URL(string: "https://image.tmdb.org/t/p/w1280/backdrop.jpg")!
        XCTAssertEqual(
            ArtworkImageVariant.heroPreview.requestURL(for: source).absoluteString,
            "https://image.tmdb.org/t/p/w780/backdrop.jpg"
        )
        XCTAssertEqual(ArtworkImageVariant.heroBackdrop.requestURL(for: source), source)
    }

    func testUnknownArtworkEndpointIsNotRewritten() {
        let source = URL(string: "https://images.example.com/backdrop.jpg?width=3840")!
        XCTAssertEqual(ArtworkImageVariant.heroPreview.requestURL(for: source), source)
    }

    #if canImport(UIKit)
    func testSharedDownsamplerBoundsLongestEdge() throws {
        let source = UIGraphicsImageRenderer(size: CGSize(width: 1_600, height: 900)).image {
            UIColor.red.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 1_600, height: 900))
        }
        let data = try XCTUnwrap(source.jpegData(compressionQuality: 0.9))
        let downsampled = try XCTUnwrap(ArtworkImageCache.downsample(data, maxPixelSize: 768))

        XCTAssertEqual(max(downsampled.size.width, downsampled.size.height), 768, accuracy: 1)
        XCTAssertEqual(downsampled.size.width / downsampled.size.height, 16.0 / 9.0, accuracy: 0.01)
    }
    #endif
}
