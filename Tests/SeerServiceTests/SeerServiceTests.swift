import XCTest
import CoreModels
import CoreNetworking
@testable import SeerService

private let seerBaseURL = URL(string: "https://requests.example.com")!

// MARK: - Pure mapping tests

final class SeerMapperTests: XCTestCase {

    func testMovieResultMapsToMediaItem() {
        let result = SeerDiscoverResult(
            id: 550,
            mediaType: "movie",
            title: "Fight Club",
            originalTitle: "Fight Club",
            overview: "An insomniac…",
            posterPath: "/poster.jpg",
            backdropPath: "/backdrop.jpg",
            releaseDate: "1999-10-15",
            mediaInfo: SeerMediaInfo(status: 5)
        )

        let item = SeerMapper.mediaItem(from: result)
        XCTAssertNotNil(item)
        XCTAssertEqual(item?.id, "seer:550")
        XCTAssertEqual(item?.title, "Fight Club")
        XCTAssertEqual(item?.kind, .movie)
        XCTAssertEqual(item?.productionYear, 1999)
        XCTAssertEqual(item?.providerIDs["Tmdb"], "550")
        XCTAssertEqual(item?.availability, .available)
        XCTAssertEqual(item?.posterURL?.absoluteString, "https://image.tmdb.org/t/p/w500/poster.jpg")
        XCTAssertEqual(item?.backdropURL?.absoluteString, "https://image.tmdb.org/t/p/w780/backdrop.jpg")
        XCTAssertEqual(item?.heroBackdropURL?.absoluteString, "https://image.tmdb.org/t/p/w1280/backdrop.jpg")
    }

    func testTVResultUsesNameAndFirstAirDate() {
        let result = SeerDiscoverResult(
            id: 1396,
            mediaType: "tv",
            name: "Breaking Bad",
            originalName: "Breaking Bad",
            firstAirDate: "2008-01-20",
            mediaInfo: SeerMediaInfo(status: 2)
        )

        let item = SeerMapper.mediaItem(from: result)
        XCTAssertEqual(item?.id, "seer:1396")
        XCTAssertEqual(item?.title, "Breaking Bad")
        XCTAssertEqual(item?.kind, .series)
        XCTAssertEqual(item?.productionYear, 2008)
        XCTAssertEqual(item?.availability, .pending)
    }

    func testPersonResultIsSkipped() {
        let result = SeerDiscoverResult(id: 1, mediaType: "person", name: "Some Actor")
        XCTAssertNil(SeerMapper.mediaItem(from: result))
    }

    func testEmptyTitleIsSkipped() {
        let result = SeerDiscoverResult(id: 2, mediaType: "movie", title: "   ")
        XCTAssertNil(SeerMapper.mediaItem(from: result))
    }

    func testMissingMediaInfoMapsToUnknownAvailability() {
        // An untracked featured title (no mediaInfo) isn't owned and hasn't been
        // requested — the hero must offer Request, so availability defaults to
        // `.unknown` (requestable), never `nil` (which would read as a library item).
        let result = SeerDiscoverResult(id: 3, mediaType: "movie", title: "Untracked")
        XCTAssertEqual(SeerMapper.mediaItem(from: result)?.availability, .unknown)
    }

    func testAllStatusRawValuesMap() {
        let expected: [Int: MediaAvailabilityStatus] = [
            1: .unknown, 2: .pending, 3: .processing,
            4: .partiallyAvailable, 5: .available, 6: .deleted
        ]
        for (raw, status) in expected {
            let result = SeerDiscoverResult(id: raw, mediaType: "movie", title: "T", mediaInfo: SeerMediaInfo(status: raw))
            XCTAssertEqual(SeerMapper.mediaItem(from: result)?.availability, status, "raw \(raw)")
        }
    }

    func testImageURLNilForMissingPath() {
        XCTAssertNil(SeerMapper.imageURL(path: nil, size: "w500"))
        XCTAssertNil(SeerMapper.imageURL(path: "", size: "w500"))
    }

    func testImageURLNormalizesLeadingSlash() {
        XCTAssertEqual(
            SeerMapper.imageURL(path: "abc.jpg", size: "w342")?.absoluteString,
            "https://image.tmdb.org/t/p/w342/abc.jpg"
        )
    }

    func testYearParsing() {
        XCTAssertEqual(SeerMapper.year(from: "2021-06-01"), 2021)
        XCTAssertNil(SeerMapper.year(from: "bad"))
        XCTAssertNil(SeerMapper.year(from: nil))
    }

    func testRequestMediaTypeDerivation() {
        XCTAssertEqual(SeerMapper.requestMediaType(for: makeItem(kind: .movie)), "movie")
        XCTAssertEqual(SeerMapper.requestMediaType(for: makeItem(kind: .series)), "tv")
        XCTAssertNil(SeerMapper.requestMediaType(for: makeItem(kind: .episode)))
    }

    func testTMDBIDFromProviderIDsAndSyntheticID() {
        let fromProvider = makeItem(kind: .movie, id: "x", tmdb: "603")
        XCTAssertEqual(SeerMapper.tmdbID(for: fromProvider), 603)

        let fromSynthetic = MediaItem(id: "seer:604", title: "T", kind: .movie)
        XCTAssertEqual(SeerMapper.tmdbID(for: fromSynthetic), 604)

        let none = MediaItem(id: "jf:abc", title: "T", kind: .movie)
        XCTAssertNil(SeerMapper.tmdbID(for: none))
    }

    func testMediaItemsCapAndDropPeople() {
        let page = SeerDiscoverPage(page: 1, totalPages: 1, totalResults: 3, results: [
            SeerDiscoverResult(id: 1, mediaType: "movie", title: "A"),
            SeerDiscoverResult(id: 2, mediaType: "person", name: "P"),
            SeerDiscoverResult(id: 3, mediaType: "tv", name: "B"),
            SeerDiscoverResult(id: 4, mediaType: "movie", title: "C")
        ])
        let all = SeerMapper.mediaItems(from: page)
        XCTAssertEqual(all.map(\.id), ["seer:1", "seer:3", "seer:4"])
        let capped = SeerMapper.mediaItems(from: page, limit: 2)
        XCTAssertEqual(capped.map(\.id), ["seer:1", "seer:3"])
    }

    private func makeItem(kind: MediaItemKind, id: String = "seer:1", tmdb: String? = nil) -> MediaItem {
        var ids: [String: String] = [:]
        if let tmdb { ids["Tmdb"] = tmdb }
        return MediaItem(id: id, title: "T", kind: kind, providerIDs: ids)
    }
}

// MARK: - Config tests

final class SeerConfigTests: XCTestCase {
    func testNormalizedBaseURLAddsSchemeAndStripsTrailingSlash() {
        // Scheme-less input defaults to **http** (self-hosted LAN servers are
        // virtually never TLS) plus Overseerr's default port 5055 — matching
        // `ServerURLNormalizer`'s Jellyfin behavior, just with a different
        // default port.
        XCTAssertEqual(SeerConfig.normalizedBaseURL(from: "requests.example.com")?.absoluteString, "http://requests.example.com:5055")
        XCTAssertEqual(SeerConfig.normalizedBaseURL(from: "192.168.68.71:5055")?.absoluteString, "http://192.168.68.71:5055")
        XCTAssertEqual(SeerConfig.normalizedBaseURL(from: "http://host:5055/")?.absoluteString, "http://host:5055")
        XCTAssertEqual(SeerConfig.normalizedBaseURL(from: "https://host/seerr/")?.absoluteString, "https://host/seerr")
    }

    func testNormalizedBaseURLRejectsEmpty() {
        XCTAssertNil(SeerConfig.normalizedBaseURL(from: "   "))
    }

    func testIsConfiguredRequiresBoth() {
        XCTAssertFalse(SeerConfig(baseURL: seerBaseURL).isConfigured)
        XCTAssertFalse(SeerConfig(apiKey: "k").isConfigured)
        XCTAssertTrue(SeerConfig(baseURL: seerBaseURL, apiKey: "k").isConfigured)
    }

    func testBlankAPIKeyIsSanitizedToNil() {
        XCTAssertNil(SeerConfig(baseURL: seerBaseURL, apiKey: "   ").apiKey)
    }
}

// MARK: - Service tests

@MainActor
final class SeerServiceTests: XCTestCase {

    private func makeConnectedService(_ http: SeerRecordingHTTPClient) -> SeerService {
        let store = InMemorySeerCredentialStore(
            credentials: SeerCredentials(baseURL: seerBaseURL, apiKey: "KEY", userId: 7)
        )
        return SeerService(credentialStore: store, http: http)
    }

    func testTrendingMapsAndCaps() async throws {
        let http = SeerRecordingHTTPClient()
        http.stub(pathSuffix: "/discover/trending", json: """
        {"page":1,"totalPages":1,"totalResults":3,"results":[
          {"id":10,"mediaType":"movie","title":"M","posterPath":"/p.jpg","mediaInfo":{"status":5}},
          {"id":11,"mediaType":"person","name":"P"},
          {"id":12,"mediaType":"tv","name":"S"}
        ]}
        """)
        let service = makeConnectedService(http)
        let items = try await service.trending(limit: 5)
        XCTAssertEqual(items.map(\.id), ["seer:10", "seer:12"])
        XCTAssertEqual(items.first?.availability, .available)
        // Auth header injected.
        let sent = http.lastSent(pathSuffix: "/discover/trending")
        XCTAssertEqual(sent?.headers["X-Api-Key"], "KEY")
        XCTAssertEqual(sent?.headers["X-API-User"], "7")
    }

    func testTrendingEmptyWhenUnconfigured() async throws {
        let http = SeerRecordingHTTPClient()
        let service = SeerService(credentialStore: InMemorySeerCredentialStore(), http: http)
        let items = try await service.trending(limit: 5)
        XCTAssertTrue(items.isEmpty)
        XCTAssertTrue(http.sentPaths.isEmpty)
    }

    // MARK: - availability(for:) — discovery detail refresh

    func testAvailabilityFetchesMovieStatusAndDownloadProgress() async throws {
        let http = SeerRecordingHTTPClient()
        http.stub(pathSuffix: "/movie/550", json: """
        {"id":550,"mediaInfo":{"status":3,"downloadStatus":[{"size":100,"sizeLeft":40}]}}
        """)
        let service = makeConnectedService(http)
        let item = MediaItem(id: "seer:550", title: "Fight Club", kind: .movie, providerIDs: ["Tmdb": "550"])

        let result = await service.availability(for: item)

        XCTAssertEqual(result?.0, .processing)
        XCTAssertEqual(result?.1 ?? 0, 0.6, accuracy: 0.0001, "(100-40)/100 fetched fraction")
        let sent = http.lastSent(pathSuffix: "/movie/550")
        XCTAssertEqual(sent?.headers["X-Api-Key"], "KEY", "Admin key is sent")
    }

    func testAvailabilityUsesTvEndpointForSeries() async throws {
        let http = SeerRecordingHTTPClient()
        http.stub(pathSuffix: "/tv/1396", json: #"{"id":1396,"mediaInfo":{"status":2}}"#)
        let service = makeConnectedService(http)
        let item = MediaItem(id: "seer:1396", title: "Breaking Bad", kind: .series, providerIDs: ["Tmdb": "1396"])

        let result = await service.availability(for: item)

        XCTAssertEqual(result?.0, .pending)
        XCTAssertNil(result?.1, "No download queue -> no progress")
        XCTAssertNotNil(http.lastSent(pathSuffix: "/tv/1396"), "Series uses the /tv/{id} endpoint")
    }

    func testAvailabilityIsUnknownForUntrackedTitle() async throws {
        // A never-requested title: the details payload carries no mediaInfo, which
        // maps to `.unknown` (requestable) rather than nil.
        let http = SeerRecordingHTTPClient()
        http.stub(pathSuffix: "/movie/777", json: #"{"id":777}"#)
        let service = makeConnectedService(http)
        let item = MediaItem(id: "seer:777", title: "Untracked", kind: .movie, providerIDs: ["Tmdb": "777"])

        let result = await service.availability(for: item)

        XCTAssertEqual(result?.0, .unknown)
        XCTAssertNil(result?.1)
    }

    func testAvailabilityNilWhenUnconfigured() async throws {
        let http = SeerRecordingHTTPClient()
        let service = SeerService(credentialStore: InMemorySeerCredentialStore(), http: http)
        let item = MediaItem(id: "seer:1", title: "X", kind: .movie, providerIDs: ["Tmdb": "1"])

        let result = await service.availability(for: item)

        XCTAssertNil(result)
        XCTAssertTrue(http.sentPaths.isEmpty, "No network when Seerr isn't configured")
    }

    func testMovieRequestBuildsBodyWithRadarrDefaults() async throws {
        let http = SeerRecordingHTTPClient()
        http.stub(pathSuffix: "/service/radarr", json: """
        [{"id":1,"name":"Main","is4k":false,"isDefault":true,"activeDirectory":"/movies","activeProfileId":4}]
        """)
        http.stub(pathSuffix: "/request", json: """
        {"id":42,"media":{"tmdbId":550,"status":2}}
        """, status: 201)

        let service = makeConnectedService(http)
        let item = MediaItem(id: "seer:550", title: "Fight Club", kind: .movie, providerIDs: ["Tmdb": "550"])
        let status = try await service.request(item)

        XCTAssertEqual(status, .pending)
        let sent = http.lastSent(pathSuffix: "/request")
        let body = sent?.json
        XCTAssertEqual(body?["mediaType"] as? String, "movie")
        XCTAssertEqual(body?["mediaId"] as? Int, 550)
        XCTAssertEqual(body?["serverId"] as? Int, 1)
        XCTAssertEqual(body?["profileId"] as? Int, 4)
        XCTAssertEqual(body?["rootFolder"] as? String, "/movies")
        XCTAssertNil(body?["seasons"])
    }

    func testRadarrDefaultFetchFailureIsNotCached() async throws {
        let http = SeerRecordingHTTPClient()
        // No /service/radarr stub -> the lookup throws .notFound each time.
        http.stub(pathSuffix: "/request", json: """
        {"id":44,"media":{"tmdbId":550,"status":2}}
        """, status: 201)

        let service = makeConnectedService(http)
        let item = MediaItem(id: "seer:550", title: "Fight Club", kind: .movie, providerIDs: ["Tmdb": "550"])

        // First request: radarr lookup fails, so defaults are omitted but the
        // request still succeeds.
        _ = try await service.request(item)
        _ = try await service.request(item)

        // A transient failure must NOT be cached: the second request re-attempts
        // the radarr lookup rather than permanently giving up on defaults.
        let radarrHits = http.sentPaths.filter { $0.hasSuffix("/service/radarr") }.count
        XCTAssertEqual(radarrHits, 2)
        // Defaults were omitted (lookup never succeeded).
        let body = http.lastSent(pathSuffix: "/request")?.json
        XCTAssertNil(body?["serverId"])
    }

    func testTVRequestRequestsAllSeasonsWithSonarrDefaults() async throws {
        let http = SeerRecordingHTTPClient()
        http.stub(pathSuffix: "/service/sonarr", json: """
        [{"id":2,"name":"TV","is4k":false,"isDefault":true,"activeDirectory":"/tv","activeProfileId":6,"activeLanguageProfileId":1}]
        """)
        http.stub(pathSuffix: "/request", json: """
        {"id":43,"media":{"tmdbId":1396,"status":3}}
        """, status: 201)

        let service = makeConnectedService(http)
        let item = MediaItem(id: "seer:1396", title: "Breaking Bad", kind: .series, providerIDs: ["Tmdb": "1396"])
        let status = try await service.request(item)

        XCTAssertEqual(status, .processing)
        let body = http.lastSent(pathSuffix: "/request")?.json
        XCTAssertEqual(body?["mediaType"] as? String, "tv")
        XCTAssertEqual(body?["mediaId"] as? Int, 1396)
        XCTAssertEqual(body?["seasons"] as? String, "all")
        XCTAssertEqual(body?["serverId"] as? Int, 2)
        XCTAssertEqual(body?["languageProfileId"] as? Int, 1)
    }

    func testRequestWithoutTMDBIDThrows() async {
        let http = SeerRecordingHTTPClient()
        let service = makeConnectedService(http)
        let item = MediaItem(id: "jf:abc", title: "No id", kind: .movie)
        do {
            _ = try await service.request(item)
            XCTFail("expected throw")
        } catch let error as AppError {
            XCTAssertEqual(error, .invalidResponse)
        } catch {
            XCTFail("expected AppError.invalidResponse, got \(error)")
        }
    }

    func testConnectSuccessPersistsAndReportsConnected() async {
        let http = SeerRecordingHTTPClient()
        http.stub(pathSuffix: "/status", json: #"{"version":"1.33.2"}"#)
        let store = InMemorySeerCredentialStore()
        let service = SeerService(credentialStore: store, http: http)

        await service.connect(baseURL: seerBaseURL, apiKey: "KEY")

        XCTAssertEqual(service.phase, .connected(summary: "Version 1.33.2"))
        XCTAssertTrue(service.isConfigured)
        XCTAssertNotNil(store.load())
    }

    func testConnectFailureDoesNotPersist() async {
        let http = SeerRecordingHTTPClient()
        http.error = .serverUnreachable
        let store = InMemorySeerCredentialStore()
        let service = SeerService(credentialStore: store, http: http)

        await service.connect(baseURL: seerBaseURL, apiKey: "KEY")

        if case .failed = service.phase {} else { XCTFail("expected failed phase, got \(service.phase)") }
        XCTAssertNil(store.load())
        XCTAssertFalse(service.isConfigured)
    }

    func testDisconnectClears() async {
        let http = SeerRecordingHTTPClient()
        let store = InMemorySeerCredentialStore(
            credentials: SeerCredentials(baseURL: seerBaseURL, apiKey: "KEY", userId: nil)
        )
        let service = SeerService(credentialStore: store, http: http)
        XCTAssertTrue(service.isConfigured)

        service.disconnect()

        XCTAssertEqual(service.phase, .unconfigured)
        XCTAssertFalse(service.isConfigured)
        XCTAssertNil(store.load())
    }

    func testRefreshStatusUnconfigured() async {
        let http = SeerRecordingHTTPClient()
        let service = SeerService(credentialStore: InMemorySeerCredentialStore(), http: http)
        await service.refreshStatus()
        XCTAssertEqual(service.phase, .unconfigured)
    }
}
