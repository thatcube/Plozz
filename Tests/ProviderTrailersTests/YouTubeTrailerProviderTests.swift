import XCTest
import CoreModels
@testable import ProviderTrailers

final class YouTubeTrailerProviderTests: XCTestCase {
    private func trailer() -> MediaItem {
        MediaItem.youTubeTrailer(videoID: "dQw4w9WgXcQ", title: "Dune — Trailer", parentTitle: "Dune")
    }

    func testItemReturnsTheTrailerLeaf() async throws {
        let provider = YouTubeTrailerProvider(item: trailer(), videoID: "dQw4w9WgXcQ")
        let resolved = try await provider.item(id: "anything")
        XCTAssertEqual(resolved.id, "dQw4w9WgXcQ")
        XCTAssertTrue(resolved.isYouTubeTrailer)
    }

    func testBrowsingAndSearchAreInert() async throws {
        let provider = YouTubeTrailerProvider(item: trailer(), videoID: "dQw4w9WgXcQ")
        let libraries = try await provider.libraries()
        let children = try await provider.children(of: "x")
        let results = try await provider.search(query: "q", limit: 10)
        let page = try await provider.items(in: "x", kind: .movie, page: PageRequest())
        XCTAssertTrue(libraries.isEmpty)
        XCTAssertTrue(children.isEmpty)
        XCTAssertTrue(results.isEmpty)
        XCTAssertEqual(page.totalCount, 0)
        XCTAssertNil(provider.imageURL(itemID: "x", kind: .primary, maxWidth: nil))
    }

    func testAcceptsAlternativesResolver() async throws {
        // The optional alternatives resolver is wired for replacement-trailer
        // recovery; constructing with it must not disturb the inert surface.
        let provider = YouTubeTrailerProvider(
            item: trailer(),
            videoID: "dQw4w9WgXcQ",
            alternatives: { ["altVideoID01"] }
        )
        let resolved = try await provider.item(id: "x")
        XCTAssertEqual(resolved.id, "dQw4w9WgXcQ")
        let children = try await provider.children(of: "x")
        XCTAssertTrue(children.isEmpty)
    }
}
