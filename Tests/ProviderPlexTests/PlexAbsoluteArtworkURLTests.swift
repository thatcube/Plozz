import XCTest
import CoreModels
import CoreNetworking
@testable import ProviderPlex

/// Artwork paths that already name their own host must not be routed through the
/// local server's photo transcoder.
///
/// A Plex watchlist is a plex.tv **Discover** list, and its entries carry Discover
/// artwork — absolute `https://…plex.tv/…` URLs belonging to a host this server
/// has nothing to do with. Wrapping one in `/photo/:/transcode` asked the local
/// server to go and fetch a URL it has no business fetching, signed with a token
/// that means nothing there.
///
/// The failure was invisible rather than loud: the server answered with a
/// placeholder instead of an error, and the same placeholder every time. A whole
/// watchlist row drew one show's poster under everybody else's title, while the
/// captions stayed perfectly correct — which is what made it read as an artwork
/// bug rather than a URL one.
final class PlexAbsoluteArtworkURLTests: XCTestCase {
    private func makeClient() -> PlexClient {
        PlexClient(
            baseURL: URL(string: "https://plex.host:32400")!,
            deviceProfile: PlexDeviceProfile(clientIdentifier: "dev1"),
            token: "SERVER-TOKEN",
            http: StubHTTPClient()
        )
    }

    /// The regression itself: a Discover poster is handed back untouched.
    func testAbsoluteArtworkURLIsNotSentThroughTheTranscoder() throws {
        let discover = "https://metadata-static.plex.tv/9/gracenote/9abc.jpg"
        let url = try XCTUnwrap(makeClient().imageURL(path: discover, maxWidth: 500))

        XCTAssertEqual(url.absoluteString, discover)
        XCTAssertFalse(url.absoluteString.contains("/photo/:/transcode"))
        // And it must not carry this server's credential to somebody else's host.
        XCTAssertFalse(url.absoluteString.contains("SERVER-TOKEN"))
    }

    /// Two different Discover posters must stay two different URLs. This is the
    /// property that actually broke: they collapsed onto one transcoder request
    /// shape whose answer was identical for both.
    func testTwoAbsoluteArtworkURLsStayDistinct() throws {
        let client = makeClient()
        let first = try XCTUnwrap(
            client.imageURL(path: "https://metadata-static.plex.tv/9/gracenote/aaa.jpg", maxWidth: 500)
        )
        let second = try XCTUnwrap(
            client.imageURL(path: "https://metadata-static.plex.tv/9/gracenote/bbb.jpg", maxWidth: 500)
        )
        XCTAssertNotEqual(first, second)
    }

    /// The ordinary case is untouched: a server-relative path is still sized by
    /// the server's transcoder, which is the whole reason that path exists.
    func testServerRelativeArtworkStillUsesTheTranscoder() throws {
        let url = try XCTUnwrap(
            makeClient().imageURL(path: "/library/metadata/12/thumb/1700000000", maxWidth: 500)
        )
        XCTAssertTrue(url.absoluteString.contains("/photo/:/transcode"))
        XCTAssertTrue(url.absoluteString.contains("width=500"))
        XCTAssertEqual(url.host, "plex.host")
    }

    /// Unsized reads take the same rule.
    func testAbsoluteArtworkIsUntouchedWithoutAWidth() throws {
        let discover = "https://metadata-static.plex.tv/9/gracenote/9abc.jpg"
        let url = try XCTUnwrap(makeClient().imageURL(path: discover, maxWidth: nil))
        XCTAssertEqual(url.absoluteString, discover)
    }

    func testEmptyPathIsStillNil() {
        XCTAssertNil(makeClient().imageURL(path: "", maxWidth: 500))
        XCTAssertNil(makeClient().imageURL(path: nil, maxWidth: 500))
    }
}
