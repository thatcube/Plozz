import XCTest
import CoreModels
import CoreNetworking
@testable import ProviderPlex

/// Phase 1: Plex on-demand subtitle search/download parity with Jellyfin. The
/// keyless, server-proxied search maps `<Stream>` results to `RemoteSubtitle`,
/// and the download PUTs the chosen result's `key` back to the item.
final class PlexRemoteSubtitleTests: XCTestCase {
    private func makeSession() -> UserSession {
        UserSession(
            server: MediaServer(id: "srv", name: "Home", baseURL: URL(string: "https://plex.host:32400")!, provider: .plex),
            userID: "u1", userName: "Alice", deviceID: "d1", accessToken: "TOKEN"
        )
    }

    func testRemoteSubtitleSearchMapsResultsAndPassesLanguage() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/library/metadata/rk1/subtitles", json: """
        {"MediaContainer":{"Stream":[
          {"key":"/subtitles/opensubtitles/12345","title":"Movie.2020.en.srt",
           "language":"English","languageCode":"en","format":"srt",
           "providerTitle":"OpenSubtitles","score":1200,"forced":0,"hearingImpaired":1}
        ]}}
        """)
        let provider = PlexProvider(session: makeSession(), http: stub)

        let results = try await provider.remoteSubtitleSearch(itemID: "rk1", language: "en")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].id, "/subtitles/opensubtitles/12345")
        XCTAssertEqual(results[0].name, "Movie.2020.en.srt")
        XCTAssertEqual(results[0].providerName, "OpenSubtitles")
        XCTAssertEqual(results[0].language, "en")
        XCTAssertEqual(results[0].format, "srt")
        XCTAssertEqual(results[0].downloadCount, 1200)
        XCTAssertFalse(results[0].isForced)
        XCTAssertTrue(results[0].isHearingImpaired, "HI flag maps from Plex hearingImpaired")

        XCTAssertTrue(stub.sentPaths.contains { $0.hasSuffix("/library/metadata/rk1/subtitles") })
        let query = stub.queryItems(forPathSuffix: "/library/metadata/rk1/subtitles") ?? []
        XCTAssertTrue(query.contains { $0.name == "language" && $0.value == "en" })
    }

    func testRemoteSubtitleSearchNormalisesLanguageToAlpha2() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/library/metadata/rk1/subtitles", json: #"{"MediaContainer":{"Stream":[]}}"#)
        let provider = PlexProvider(session: makeSession(), http: stub)

        // Plex wants ISO-639-1; a 3-letter code must be folded to 2-letter.
        _ = try await provider.remoteSubtitleSearch(itemID: "rk1", language: "eng")
        let query = stub.queryItems(forPathSuffix: "/library/metadata/rk1/subtitles") ?? []
        XCTAssertTrue(query.contains { $0.name == "language" && $0.value == "en" })
    }

    func testRemoteSubtitleSearchEmptyWhenNoSource() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/library/metadata/rk1/subtitles", json: #"{"MediaContainer":{}}"#)
        let provider = PlexProvider(session: makeSession(), http: stub)
        let results = try await provider.remoteSubtitleSearch(itemID: "rk1", language: "en")
        XCTAssertTrue(results.isEmpty)
    }

    func testDownloadRemoteSubtitlePUTsKeyToSubtitlesPath() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/library/metadata/rk1/subtitles", json: #"{"MediaContainer":{}}"#)
        let provider = PlexProvider(session: makeSession(), http: stub)

        try await provider.downloadRemoteSubtitle(itemID: "rk1", subtitleID: "/subtitles/opensubtitles/9")
        XCTAssertEqual(stub.method(forPathSuffix: "/library/metadata/rk1/subtitles"), .put)
        let query = stub.queryItems(forPathSuffix: "/library/metadata/rk1/subtitles") ?? []
        XCTAssertTrue(query.contains { $0.name == "key" && $0.value == "/subtitles/opensubtitles/9" })
    }

    func testPlexAdvertisesRemoteSubtitlesCapability() {
        let provider = PlexProvider(session: makeSession(), http: StubHTTPClient())
        XCTAssertTrue(provider.capabilities.contains(.remoteSubtitles))
        XCTAssertTrue(provider.capabilities.contains(.music), "must not drop the Music capability")
        XCTAssertTrue(provider.capabilities.contains(.video))
    }
}
