import XCTest
import CoreModels
import CoreNetworking
@testable import ProviderPlex

/// Spoiler-safe parent artwork for Plex episodes.
///
/// `MediaItem.fallbackArtworkURL` is documented as parent artwork that is *never*
/// the episode's own frame, and spoiler `.placeholder` mode reads only that field.
/// Plex never populated it, so a Plex user who chose "Placeholder Art" got a blank
/// grey card for every hidden episode — strictly worse than the blur it replaced.
///
/// Plex propagates the SHOW's `art` down onto episode nodes (an episode's own
/// image is `thumb`), so the series backdrop is already available on the episode
/// DTO and simply needed mapping across.
final class PlexSpoilerSafeArtworkTests: XCTestCase {
    private func makeSession() -> UserSession {
        UserSession(
            server: MediaServer(id: "srv", name: "Home", baseURL: URL(string: "https://plex.host:32400")!, provider: .plex),
            userID: "u1", userName: "Alice", deviceID: "d1", accessToken: "TOKEN"
        )
    }

    /// One episode carrying the full Plex artwork shape: its own still (`thumb`),
    /// the show's poster (`grandparentThumb`) and the show's backdrop (`art`).
    private func makeProvider() -> PlexProvider {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/library/metadata/9/children", json: """
        {"MediaContainer":{"size":1,"Metadata":[
          {"ratingKey":"e1","type":"episode","title":"Pilot","index":1,"parentIndex":1,
           "grandparentRatingKey":"show1","grandparentTitle":"The Show",
           "thumb":"/library/metadata/e1/thumb/1",
           "grandparentThumb":"/library/metadata/show1/thumb/1",
           "art":"/library/metadata/show1/art/1"}
        ]}}
        """)
        return PlexProvider(session: makeSession(), http: stub)
    }

    private func loadEpisode() async throws -> MediaItem {
        let children = try await makeProvider().children(of: "9")
        return try XCTUnwrap(children.first { $0.id == "e1" })
    }

    /// Plex serves artwork through its photo transcoder, so the real library path
    /// is the percent-encoded `url` query item rather than the URL's own path.
    /// `URLComponents` decodes it back for us.
    private func sourcePath(of url: URL) throws -> String {
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        return try XCTUnwrap(
            components.queryItems?.first(where: { $0.name == "url" })?.value,
            "expected a transcoder URL carrying the source path, got \(url)"
        )
    }

    func testEpisodeCarriesSeriesBackdropAsSpoilerSafeFallbackArtwork() async throws {
        let episode = try await loadEpisode()
        let fallback = try XCTUnwrap(
            episode.fallbackArtworkURL,
            "spoiler placeholder mode reads only this field — nil renders a blank card"
        )
        let path = try sourcePath(of: fallback)
        XCTAssertTrue(
            path.hasPrefix("/library/metadata/show1/art/"),
            "the fallback must be the SHOW's art, got \(path)"
        )
    }

    func testFallbackArtworkIsNeverTheEpisodesOwnStill() async throws {
        let episode = try await loadEpisode()
        let fallback = try XCTUnwrap(episode.fallbackArtworkURL)
        let path = try sourcePath(of: fallback)
        XCTAssertFalse(
            path.hasPrefix("/library/metadata/e1/"),
            "fallback artwork must never be the episode's own image — that is the frame spoiler mode hides"
        )
        XCTAssertNotEqual(fallback, episode.posterURL)
    }

    /// The episode's own still must keep its own home, so unmasked surfaces still
    /// show a real per-episode thumbnail.
    func testEpisodeStillIsStillMappedToPosterURL() async throws {
        let episode = try await loadEpisode()
        let poster = try XCTUnwrap(episode.posterURL)
        let path = try sourcePath(of: poster)
        XCTAssertTrue(path.hasPrefix("/library/metadata/e1/thumb/"), "got \(path)")
    }

    /// Only episodes need parent artwork. For a movie or a series, `art` is the
    /// item's own backdrop and already rides on `backdropURL`.
    func testNonEpisodesDoNotGetFallbackArtwork() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/library/metadata/7/children", json: """
        {"MediaContainer":{"size":1,"Metadata":[
          {"ratingKey":"s1","type":"season","title":"Season 1","index":1,
           "parentRatingKey":"show1","art":"/library/metadata/show1/art/1"}
        ]}}
        """)
        let children = try await PlexProvider(session: makeSession(), http: stub).children(of: "7")
        let season = try XCTUnwrap(children.first { $0.id == "s1" })
        XCTAssertNil(season.fallbackArtworkURL)
        XCTAssertNotNil(season.backdropURL, "a container's own art still maps normally")
    }
}
