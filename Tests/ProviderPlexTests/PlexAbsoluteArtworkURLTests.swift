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
    private func makeClient(
        baseURL: URL = URL(string: "https://plex.host:32400")!
    ) -> PlexClient {
        PlexClient(
            baseURL: baseURL,
            deviceProfile: PlexDeviceProfile(clientIdentifier: "dev1"),
            token: "SERVER-TOKEN",
            http: StubHTTPClient()
        )
    }

    private func makeProvider(
        baseURL: URL = URL(string: "https://plex.host:32400")!,
        serverID: String = "server",
        connectionURLs: [URL]? = nil
    ) -> PlexProvider {
        PlexProvider(
            session: UserSession(
                server: MediaServer(
                    id: serverID,
                    name: "Plex",
                    baseURL: baseURL,
                    provider: .plex,
                    connectionURLs: connectionURLs
                ),
                userID: "user",
                userName: "Viewer",
                deviceID: "device",
                accessToken: "SERVER-TOKEN"
            ),
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

    func testProviderRehydratesArtworkFromItemIDWithoutMetadataRequest() throws {
        let url = try XCTUnwrap(
            makeProvider().imageURL(
                itemID: "4407",
                kind: .primary,
                maxWidth: 500
            )
        )
        let components = try XCTUnwrap(
            URLComponents(url: url, resolvingAgainstBaseURL: false)
        )
        let inner = try XCTUnwrap(
            components.queryItems?.first { $0.name == "url" }?.value
        )

        XCTAssertEqual(url.host, "plex.host")
        XCTAssertEqual(url.path, "/photo/:/transcode")
        XCTAssertTrue(inner.contains("/library/metadata/4407/thumb"))
        XCTAssertTrue(
            components.queryItems?.contains {
                $0.name == "X-Plex-Token"
            } == true
        )
    }

    func testProviderReauthenticatesPersistedTranscodeAndKeepsRevision() throws {
        let live = try XCTUnwrap(
            makeClient().imageURL(
                path: "/library/metadata/4407/thumb/1785747598",
                maxWidth: 500
            )
        )
        let persisted = SyncURLSanitizer.sanitize(live)
        XCTAssertFalse(
            persisted.absoluteString.contains("SERVER-TOKEN")
        )

        let signed = try XCTUnwrap(
            makeProvider().reauthenticatedImageURL(
                persisted,
                maxWidth: 500
            )
        )
        let components = try XCTUnwrap(
            URLComponents(url: signed, resolvingAgainstBaseURL: false)
        )
        let inner = try XCTUnwrap(
            components.queryItems?.first { $0.name == "url" }?.value
        )

        XCTAssertTrue(
            inner.contains(
                "/library/metadata/4407/thumb/1785747598"
            )
        )
        XCTAssertTrue(inner.contains("SERVER-TOKEN"))
        XCTAssertTrue(
            components.queryItems?.contains {
                $0.name == "X-Plex-Token"
                    && $0.value == "SERVER-TOKEN"
            } == true
        )
    }

    func testProviderDoesNotReauthenticateDiscoverArtworkAsLocal() throws {
        let discover = URL(
            string:
                "https://discover.provider.plex.tv"
                + "/library/metadata/5d9c08/thumb/1700000000"
        )!

        XCTAssertNil(
            makeProvider().reauthenticatedImageURL(
                discover,
                maxWidth: 500
            )
        )
    }

    func testProviderDoesNotOwnTranscodedExternalArtwork() throws {
        var components = URLComponents(
            string: "https://plex.host:32400/photo/:/transcode"
        )!
        components.queryItems = [
            URLQueryItem(name: "width", value: "500"),
            URLQueryItem(
                name: "url",
                value:
                    "https://discover.provider.plex.tv"
                    + "/library/metadata/arcane/thumb/1"
            )
        ]
        let persisted = try XCTUnwrap(components.url)
        let provider = makeProvider()

        XCTAssertFalse(provider.ownsPersistedImageURL(persisted))
        XCTAssertNil(
            provider.reauthenticatedImageURL(
                persisted,
                maxWidth: 500
            )
        )
    }

    func testProviderReauthenticatesDiscoverArtworkWithDiscoverToken() throws {
        let live = try XCTUnwrap(
            PlexClient(
                baseURL: URL(string: "https://plex.host:32400")!,
                deviceProfile: PlexDeviceProfile(clientIdentifier: "dev1"),
                token: "SERVER-TOKEN",
                discoverToken: "OLD-DISCOVER-TOKEN",
                http: StubHTTPClient()
            ).discoverImageURL(
                path: "/library/metadata/arcane/thumb/1"
            )
        )
        let persisted = SyncURLSanitizer.sanitize(live)
        let signed = try XCTUnwrap(
            makeProvider().reauthenticatedDiscoverImageURL(
                persisted,
                discoverToken: "CURRENT-DISCOVER-TOKEN"
            )
        )
        let query = try XCTUnwrap(
            URLComponents(url: signed, resolvingAgainstBaseURL: false)?
                .queryItems
        )

        XCTAssertEqual(signed.host, "discover.provider.plex.tv")
        XCTAssertEqual(signed.path, "/library/metadata/arcane/thumb/1")
        XCTAssertTrue(
            query.contains {
                $0.name == "X-Plex-Token"
                    && $0.value == "CURRENT-DISCOVER-TOKEN"
            }
        )
        XCTAssertFalse(signed.absoluteString.contains("OLD-DISCOVER-TOKEN"))
    }

    func testProviderStripsReverseProxyBasePathFromDirectArtwork() throws {
        let baseURL = URL(string: "https://plex.host/plex")!
        let persisted = URL(
            string:
                "https://plex.host/plex"
                + "/library/metadata/4407/thumb/1785747598"
        )!
        let signed = try XCTUnwrap(
            makeProvider(
                baseURL: baseURL,
                serverID: "reverse-proxy-test"
            ).reauthenticatedImageURL(
                persisted,
                maxWidth: 500
            )
        )
        let components = try XCTUnwrap(
            URLComponents(url: signed, resolvingAgainstBaseURL: false)
        )
        let inner = try XCTUnwrap(
            components.queryItems?.first { $0.name == "url" }?.value
        )

        XCTAssertEqual(signed.path, "/plex/photo/:/transcode")
        XCTAssertTrue(
            inner.hasPrefix(
                "/library/metadata/4407/thumb/1785747598?"
            )
        )
        XCTAssertFalse(inner.hasPrefix("/plex/plex/"))
        XCTAssertFalse(inner.hasPrefix("/plex/library/"))
    }

    func testLibraryNamedProxyDoesNotStripProviderLibraryPath() throws {
        let baseURL = URL(string: "https://plex.host/library")!
        let live = try XCTUnwrap(
            makeClient(baseURL: baseURL).imageURL(
                path: "/library/metadata/4407/thumb/1785747598",
                maxWidth: 500
            )
        )
        let signed = try XCTUnwrap(
            makeProvider(
                baseURL: baseURL,
                serverID: "library-proxy-test"
            ).reauthenticatedImageURL(
                SyncURLSanitizer.sanitize(live),
                maxWidth: 500
            )
        )
        let inner = try XCTUnwrap(
            URLComponents(url: signed, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "url" }?.value
        )

        XCTAssertEqual(signed.path, "/library/photo/:/transcode")
        XCTAssertTrue(
            inner.hasPrefix(
                "/library/metadata/4407/thumb/1785747598?"
            )
        )
    }

    func testProviderReauthenticatesArtworkFromKnownPreviousOrigin() throws {
        let current = URL(string: "http://192.168.1.10:32400")!
        let previous = URL(string: "https://relay.plex.direct")!
        let provider = makeProvider(
            baseURL: current,
            serverID: "failover-artwork-test",
            connectionURLs: [current, previous]
        )
        let persisted = URL(
            string:
                "https://relay.plex.direct"
                + "/library/metadata/4407/thumb/1"
        )!
        let signed = try XCTUnwrap(
            provider.reauthenticatedImageURL(
                persisted,
                maxWidth: 500
            )
        )

        XCTAssertTrue(provider.ownsPersistedImageURL(persisted))
        XCTAssertEqual(signed.host, provider.authenticatedHTTPOrigin.host)
        XCTAssertNotEqual(signed.host, persisted.host)
    }

    /// Unsized reads take the same rule.
    func testAbsoluteArtworkIsUntouchedWithoutAWidth() throws {
        let discover = "https://metadata-static.plex.tv/9/gracenote/9abc.jpg"
        let url = try XCTUnwrap(makeClient().imageURL(path: discover, maxWidth: nil))
        XCTAssertEqual(url.absoluteString, discover)
    }

    // MARK: Discover artwork

    /// A watchlist row's art is a path on plex.tv Discover, and must resolve
    /// there — not against the viewer's own server, which has never heard of it.
    func testDiscoverArtworkResolvesAgainstTheDiscoverHost() throws {
        let url = try XCTUnwrap(
            makeClient().discoverImageURL(path: "/library/metadata/5d9c08/thumb/1700000000")
        )
        XCTAssertEqual(url.host, "discover.provider.plex.tv")
        XCTAssertEqual(url.path, "/library/metadata/5d9c08/thumb/1700000000")
        XCTAssertFalse(url.absoluteString.contains("/photo/:/transcode"))
    }

    /// Two different Discover art paths must stay two different URLs — the
    /// property whose absence put one poster on a whole row.
    func testTwoDiscoverArtworkPathsStayDistinct() throws {
        let client = makeClient()
        let first = try XCTUnwrap(client.discoverImageURL(path: "/library/metadata/aaa/thumb/1"))
        let second = try XCTUnwrap(client.discoverImageURL(path: "/library/metadata/bbb/thumb/1"))
        XCTAssertNotEqual(first, second)
    }

    /// Discover occasionally answers with a fully-qualified URL of its own.
    func testAbsoluteDiscoverArtworkIsLeftAlone() throws {
        let absolute = "https://metadata-static.plex.tv/9/gracenote/9abc.jpg"
        let url = try XCTUnwrap(makeClient().discoverImageURL(path: absolute))
        XCTAssertEqual(url.absoluteString, absolute)
    }

    func testEmptyDiscoverPathIsNil() {
        XCTAssertNil(makeClient().discoverImageURL(path: ""))
        XCTAssertNil(makeClient().discoverImageURL(path: nil))
    }

    func testEmptyPathIsStillNil() {
        XCTAssertNil(makeClient().imageURL(path: "", maxWidth: 500))
        XCTAssertNil(makeClient().imageURL(path: nil, maxWidth: 500))
    }
}
