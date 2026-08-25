import XCTest
@testable import CoreModels
@testable import MetadataKit

/// Coverage for `ArtworkProvider.artworkURLs` — the candidate list that lets the
/// Home hero and the detail page show *different* pictures.
///
/// The bug this closes: both screens resolved the same `.hero` chain and each took
/// the single answer it returned, so they always drew the identical image. TMDb
/// fetches every backdrop a title has in one response, ranks textless ones first,
/// and all but the best were discarded a layer above.
final class ArtworkCandidateTests: XCTestCase {

    private func url(_ name: String) -> URL {
        URL(string: "https://art.example/\(name).jpg")!
    }

    /// A provider holding one picture needs no change and must keep costing one
    /// call — the default implementation is what guarantees that.
    private struct SingleImageProvider: ArtworkProvider {
        let id = "single"
        let image: URL
        /// Counts calls, to prove the default adds no extra work.
        final class Calls: @unchecked Sendable { var count = 0 }
        let calls: Calls

        func artworkURL(_ kind: ArtworkKind, for query: MetadataQuery) async -> URL? {
            calls.count += 1
            return image
        }
    }

    private struct MultiImageProvider: ArtworkProvider {
        let id = "multi"
        let images: [URL]

        func artworkURL(_ kind: ArtworkKind, for query: MetadataQuery) async -> URL? {
            images.first
        }

        func artworkURLs(_ kind: ArtworkKind, for query: MetadataQuery, limit: Int) async -> [URL] {
            Array(images.prefix(limit))
        }
    }

    private var query: MetadataQuery {
        MetadataQuery(MediaItem(id: "i1", title: "Show", kind: .series))
    }

    // MARK: The default

    /// A single-image provider answers with exactly its one picture...
    func testTheDefaultReturnsTheSingleAnswer() async {
        let provider = SingleImageProvider(image: url("only"), calls: .init())
        let urls = await provider.artworkURLs(.hero, for: query, limit: 4)
        XCTAssertEqual(urls, [url("only")])
    }

    /// ...using exactly one underlying call, however many are asked for. A default
    /// that fanned out per requested candidate would turn one request into four on
    /// every provider that never needed changing.
    func testTheDefaultCostsExactlyOneCall() async {
        let calls = SingleImageProvider.Calls()
        let provider = SingleImageProvider(image: url("only"), calls: calls)
        _ = await provider.artworkURLs(.hero, for: query, limit: 4)
        XCTAssertEqual(calls.count, 1)
    }

    /// Asking for nothing must do nothing — the guard that keeps a satisfied
    /// caller from touching the network at all.
    func testAZeroLimitDoesNoWork() async {
        let calls = SingleImageProvider.Calls()
        let provider = SingleImageProvider(image: url("only"), calls: calls)
        let urls = await provider.artworkURLs(.hero, for: query, limit: 0)
        XCTAssertTrue(urls.isEmpty)
        XCTAssertEqual(calls.count, 0, "a zero limit must not reach the provider")
    }

    // MARK: Multi-image providers

    func testAMultiImageProviderOffersItsWholeRankedSet() async {
        let provider = MultiImageProvider(images: [url("a"), url("b"), url("c")])
        let urls = await provider.artworkURLs(.hero, for: query, limit: 2)
        XCTAssertEqual(urls, [url("a"), url("b")])
    }

    /// The first candidate must remain what the single-answer path returns, so the
    /// Home hero is byte-for-byte unaffected by any of this.
    func testTheFirstCandidateMatchesTheSingleAnswer() async {
        let provider = MultiImageProvider(images: [url("a"), url("b")])
        let single = await provider.artworkURL(.hero, for: query)
        let first = await provider.artworkURLs(.hero, for: query, limit: 2).first
        XCTAssertEqual(single, first)
    }

    /// And the detail page's pick is a different picture from Home's.
    func testTheRunnerUpDiffersFromTheFirst() async {
        let provider = MultiImageProvider(images: [url("a"), url("b")])
        let urls = await provider.artworkURLs(.hero, for: query, limit: 2)
        XCTAssertEqual(urls.dropFirst().first, url("b"))
        XCTAssertNotEqual(urls.first, urls.dropFirst().first)
    }
}
