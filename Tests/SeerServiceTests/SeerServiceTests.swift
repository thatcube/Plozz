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

    func testRequestAvailabilityCombinesTrackedAndMissingSeasons() {
        let details = SeerMediaDetails(
            mediaInfo: SeerMediaInfo(
                status: 4,
                seasons: [
                    SeerMediaSeason(seasonNumber: 1, status: 5),
                    SeerMediaSeason(seasonNumber: 3, status: 2)
                ],
                requests: [
                    SeerMediaRequest(
                        status: 2,
                        seasons: [SeerRequestedSeason(seasonNumber: 2, status: 2)]
                    ),
                    SeerMediaRequest(
                        status: 4,
                        seasons: [SeerRequestedSeason(seasonNumber: 4, status: 2)]
                    )
                ]
            ),
            seasons: [
                SeerSeasonSummary(name: "Specials", seasonNumber: 0),
                SeerSeasonSummary(name: "The Beginning", seasonNumber: 1),
                SeerSeasonSummary(seasonNumber: 2),
                SeerSeasonSummary(seasonNumber: 3),
                SeerSeasonSummary(seasonNumber: 4)
            ]
        )

        let availability = SeerMapper.requestAvailability(from: details)

        XCTAssertEqual(availability.status, .partiallyAvailable)
        XCTAssertEqual(availability.seasons.map(\.number), [1, 2, 3, 4])
        XCTAssertEqual(availability.seasons.map(\.status), [.available, .processing, .pending, .pending])
        XCTAssertEqual(availability.seasons.map(\.requestFailed), [false, false, false, true])
        XCTAssertEqual(availability.seasons.map(\.title), ["The Beginning", "Season 2", "Season 3", "Season 4"])
        XCTAssertEqual(availability.requestableSeasonNumbers, [])
        XCTAssertEqual(availability.requestPickerSeasons.map(\.number), [2, 3, 4])
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
        let store = InMemorySeerConnectionStore(
            connection: SeerConnection(baseURL: seerBaseURL, apiKey: "KEY")
        )
        return SeerService(connectionStore: store, http: http)
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
        // Auth header injected; browse runs as ADMIN (no X-API-User).
        let sent = http.lastSent(pathSuffix: "/discover/trending")
        XCTAssertEqual(sent?.headers["X-Api-Key"], "KEY")
        XCTAssertNil(sent?.headers["X-API-User"], "Browse calls run as admin")
    }

    func testTrendingEmptyWhenUnconfigured() async throws {
        let http = SeerRecordingHTTPClient()
        let service = SeerService(connectionStore: InMemorySeerConnectionStore(), http: http)
        let items = try await service.trending(limit: 5)
        XCTAssertTrue(items.isEmpty)
        XCTAssertTrue(http.sentPaths.isEmpty)
    }

    // MARK: - Users

    func testUsersFetchesAllPagesSortedByName() async throws {
        let http = SeerRecordingHTTPClient()
        // Two pages (take=100 each). First page full-ish, second short → stop.
        // The stub matches on path suffix only, so both /user calls return this
        // page; assert the merge + sort, and that pagination terminates.
        http.stub(pathSuffix: "/user", json: """
        {"pageInfo":{"pages":1,"page":1,"results":2},"results":[
          {"id":3,"displayName":"Zoe","email":"z@x.com"},
          {"id":1,"displayName":"Amy","plexUsername":"amy"}
        ]}
        """)
        let service = makeConnectedService(http)
        let users = try await service.users()
        XCTAssertEqual(users.map(\.name), ["Amy", "Zoe"], "Sorted by display name")
        XCTAssertEqual(users.map(\.id), [1, 3])
        // Admin identity for the user list.
        XCTAssertNil(http.lastSent(pathSuffix: "/user")?.headers["X-API-User"])
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

    func testRequestAvailabilityDecodesSeriesSeasonCoverage() async throws {
        let http = SeerRecordingHTTPClient()
        http.stub(pathSuffix: "/tv/1396", json: """
        {
          "id": 1396,
          "seasons": [
            {"name":"Specials","seasonNumber":0},
            {"name":"Season 1","seasonNumber":1},
            {"name":"Season 2","seasonNumber":2},
            {"name":"Season 3","seasonNumber":3}
          ],
          "mediaInfo": {
            "status": 4,
            "seasons": [{"seasonNumber":1,"status":5}],
            "requests": [
              {
                "status": 2,
                "is4k": false,
                "seasons": [{"seasonNumber":2,"status":2}]
              }
            ]
          }
        }
        """)
        let service = makeConnectedService(http)
        let item = MediaItem(id: "library:1396", title: "Breaking Bad", kind: .series, providerIDs: ["Tmdb": "1396"])

        let result = await service.requestAvailability(for: item)

        XCTAssertEqual(result?.status, .partiallyAvailable)
        XCTAssertEqual(result?.seasons.map(\.number), [1, 2, 3])
        XCTAssertEqual(result?.seasons.map(\.status), [.available, .processing, .unknown])
        XCTAssertEqual(result?.requestableSeasonNumbers, [3])
    }

    func testAvailabilityIsUnknownForUntrackedTitle() async throws {
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
        let service = SeerService(connectionStore: InMemorySeerConnectionStore(), http: http)
        let item = MediaItem(id: "seer:1", title: "X", kind: .movie, providerIDs: ["Tmdb": "1"])

        let result = await service.availability(for: item)

        XCTAssertNil(result)
        XCTAssertTrue(http.sentPaths.isEmpty, "No network when Seerr isn't configured")
    }

    // MARK: - Requests (admin path seeds defaults)

    func testMovieRequestAsAdminBuildsBodyWithRadarrDefaults() async throws {
        let http = SeerRecordingHTTPClient()
        http.stub(pathSuffix: "/service/radarr", json: """
        [{"id":1,"name":"Main","is4k":false,"isDefault":true,"activeDirectory":"/movies","activeProfileId":4}]
        """)
        http.stub(pathSuffix: "/request", json: """
        {"id":42,"media":{"tmdbId":550,"status":2}}
        """, status: 201)

        let service = makeConnectedService(http)
        let item = MediaItem(id: "seer:550", title: "Fight Club", kind: .movie, providerIDs: ["Tmdb": "550"])
        let outcome = await service.request(item) // actingUserID nil = admin

        XCTAssertEqual(outcome, .success(.pending))
        let sent = http.lastSent(pathSuffix: "/request")
        XCTAssertNil(sent?.headers["X-API-User"], "Admin request omits X-API-User")
        let body = sent?.json
        XCTAssertEqual(body?["mediaType"] as? String, "movie")
        XCTAssertEqual(body?["mediaId"] as? Int, 550)
        XCTAssertEqual(body?["serverId"] as? Int, 1)
        XCTAssertEqual(body?["profileId"] as? Int, 4)
        XCTAssertEqual(body?["rootFolder"] as? String, "/movies")
        XCTAssertNil(body?["seasons"])
    }

    func testRequestAsMappedUserSendsHeaderAndOmitsServerDefaults() async throws {
        let http = SeerRecordingHTTPClient()
        // Even if a radarr default exists, a mapped user must NOT seed it — let
        // Overseerr apply that user's own defaults.
        http.stub(pathSuffix: "/service/radarr", json: """
        [{"id":1,"isDefault":true,"activeDirectory":"/movies","activeProfileId":4}]
        """)
        http.stub(pathSuffix: "/request", json: #"{"id":42,"media":{"tmdbId":550,"status":2}}"#, status: 201)

        let service = makeConnectedService(http)
        let item = MediaItem(id: "seer:550", title: "Fight Club", kind: .movie, providerIDs: ["Tmdb": "550"])
        let outcome = await service.request(item, actingUserID: 9)

        XCTAssertEqual(outcome, .success(.pending))
        let sent = http.lastSent(pathSuffix: "/request")
        XCTAssertEqual(sent?.headers["X-API-User"], "9", "Requests as the mapped user")
        let body = sent?.json
        XCTAssertNil(body?["serverId"], "Mapped user omits server so Overseerr uses their default")
        XCTAssertNil(body?["profileId"])
        XCTAssertNil(body?["rootFolder"])
        // The admin radarr-default lookup should NOT even be attempted for a mapped user.
        XCTAssertTrue(http.sentPaths.filter { $0.hasSuffix("/service/radarr") }.isEmpty)
    }

    func testTVRequestAsAdminRequestsAllSeasonsWithSonarrDefaults() async throws {
        let http = SeerRecordingHTTPClient()
        http.stub(pathSuffix: "/service/sonarr", json: """
        [{"id":2,"name":"TV","is4k":false,"isDefault":true,"activeDirectory":"/tv","activeProfileId":6,"activeLanguageProfileId":1}]
        """)
        http.stub(pathSuffix: "/request", json: #"{"id":43,"media":{"tmdbId":1396,"status":3}}"#, status: 201)

        let service = makeConnectedService(http)
        let item = MediaItem(id: "seer:1396", title: "Breaking Bad", kind: .series, providerIDs: ["Tmdb": "1396"])
        let outcome = await service.request(item)

        XCTAssertEqual(outcome, .success(.processing))
        let body = http.lastSent(pathSuffix: "/request")?.json
        XCTAssertEqual(body?["mediaType"] as? String, "tv")
        XCTAssertEqual(body?["seasons"] as? String, "all")
        XCTAssertEqual(body?["serverId"] as? Int, 2)
        XCTAssertEqual(body?["languageProfileId"] as? Int, 1)
    }

    func testTVRequestCanRequestExplicitSeasons() async throws {
        let http = SeerRecordingHTTPClient()
        http.stub(pathSuffix: "/request", json: #"{"id":43,"media":{"tmdbId":1396,"status":2}}"#, status: 201)

        let service = makeConnectedService(http)
        let item = MediaItem(id: "library:1396", title: "Breaking Bad", kind: .series, providerIDs: ["Tmdb": "1396"])
        let outcome = await service.request(item, seasons: [4, 2, 4, 0], actingUserID: 9)

        XCTAssertEqual(outcome, .success(.pending))
        let body = http.lastSent(pathSuffix: "/request")?.json
        XCTAssertEqual(body?["seasons"] as? [Int], [2, 4])
        XCTAssertEqual(http.lastSent(pathSuffix: "/request")?.headers["X-API-User"], "9")
    }

    func testRequestWithoutTMDBIDFailsWithReason() async {
        let http = SeerRecordingHTTPClient()
        let service = makeConnectedService(http)
        let item = MediaItem(id: "jf:abc", title: "No id", kind: .movie)
        let outcome = await service.request(item)
        guard case .failure(.unknown) = outcome else {
            return XCTFail("expected .failure(.unknown), got \(outcome)")
        }
    }

    // MARK: - RequestOutcome failure mapping (status + message)

    func testRequestAlreadyRequestedMapsFrom409() async {
        let http = SeerRecordingHTTPClient()
        http.stub(pathSuffix: "/request", json: #"{"message":"Request already exists"}"#, status: 409)
        let service = makeConnectedService(http)
        let item = MediaItem(id: "seer:5", title: "T", kind: .movie, providerIDs: ["Tmdb": "5"])
        let outcome = await service.request(item, actingUserID: 2)
        XCTAssertEqual(outcome, .failure(.alreadyRequested))
    }

    func testRequestQuotaMapsFrom403Message() async {
        let http = SeerRecordingHTTPClient()
        http.stub(pathSuffix: "/request", json: #"{"message":"You have exceeded your request quota"}"#, status: 403)
        let service = makeConnectedService(http)
        let item = MediaItem(id: "seer:5", title: "T", kind: .movie, providerIDs: ["Tmdb": "5"])
        let outcome = await service.request(item, actingUserID: 2)
        XCTAssertEqual(outcome, .failure(.quotaExceeded))
    }

    func testRequestNoPermissionMapsFrom403() async {
        let http = SeerRecordingHTTPClient()
        http.stub(pathSuffix: "/request", json: #"{"message":"You do not have permission"}"#, status: 403)
        let service = makeConnectedService(http)
        let item = MediaItem(id: "seer:5", title: "T", kind: .movie, providerIDs: ["Tmdb": "5"])
        let outcome = await service.request(item, actingUserID: 2)
        XCTAssertEqual(outcome, .failure(.noPermission))
    }

    func testRequestNoDefaultsMapsFromServerMessage() async {
        let http = SeerRecordingHTTPClient()
        http.stub(pathSuffix: "/request", json: #"{"message":"No default server was found"}"#, status: 500)
        let service = makeConnectedService(http)
        let item = MediaItem(id: "seer:5", title: "T", kind: .movie, providerIDs: ["Tmdb": "5"])
        let outcome = await service.request(item, actingUserID: 2)
        XCTAssertEqual(outcome, .failure(.noDefaults))
    }

    func testRequestInvalidActingUserMapsFrom401() async {
        let http = SeerRecordingHTTPClient()
        http.stub(pathSuffix: "/request", json: #"{"message":"Unauthorized"}"#, status: 401)
        let service = makeConnectedService(http)
        let item = MediaItem(id: "seer:5", title: "T", kind: .movie, providerIDs: ["Tmdb": "5"])
        let outcome = await service.request(item, actingUserID: 999)
        XCTAssertEqual(outcome, .failure(.invalidActingUser))
    }

    func testAdmin401IsNotInvalidActingUser() async {
        // On the admin path (no X-API-User) a 401 means a bad admin key, NOT an
        // invalid acting user — it must not be misclassified as invalidActingUser.
        let http = SeerRecordingHTTPClient()
        http.stub(pathSuffix: "/service/radarr", json: "[]")
        http.stub(pathSuffix: "/request", json: #"{"message":"Unauthorized"}"#, status: 401)
        let service = makeConnectedService(http)
        let item = MediaItem(id: "seer:5", title: "T", kind: .movie, providerIDs: ["Tmdb": "5"])
        let outcome = await service.request(item) // admin (actingUserID nil)
        guard case let .failure(reason) = outcome else {
            return XCTFail("expected failure, got \(outcome)")
        }
        XCTAssertNotEqual(reason, .invalidActingUser)
        if case .unknown = reason {} else { XCTFail("admin 401 should map to .unknown, got \(reason)") }
    }

    func testRequestUnreachableMapsTransportFailure() async {
        let http = SeerRecordingHTTPClient()
        http.error = .serverUnreachable
        let service = makeConnectedService(http)
        let item = MediaItem(id: "seer:5", title: "T", kind: .movie, providerIDs: ["Tmdb": "5"])
        let outcome = await service.request(item, actingUserID: 2)
        XCTAssertEqual(outcome, .failure(.unreachable))
    }

    // MARK: - Connection lifecycle

    func testConnectSuccessPersistsAndReportsConnected() async {
        let http = SeerRecordingHTTPClient()
        http.stub(pathSuffix: "/status", json: #"{"version":"1.33.2"}"#)
        let store = InMemorySeerConnectionStore()
        let service = SeerService(connectionStore: store, http: http)

        await service.connect(baseURL: seerBaseURL, apiKey: "KEY")

        XCTAssertEqual(service.phase, .connected(summary: "Version 1.33.2"))
        XCTAssertTrue(service.isConfigured)
        XCTAssertEqual(store.load()?.apiKey, "KEY")
    }

    func testConnectFailureDoesNotPersist() async {
        let http = SeerRecordingHTTPClient()
        http.error = .serverUnreachable
        let store = InMemorySeerConnectionStore()
        let service = SeerService(connectionStore: store, http: http)

        await service.connect(baseURL: seerBaseURL, apiKey: "KEY")

        if case .failed = service.phase {} else { XCTFail("expected failed phase, got \(service.phase)") }
        XCTAssertNil(store.load())
        XCTAssertFalse(service.isConfigured)
    }

    func testDisconnectClears() async {
        let http = SeerRecordingHTTPClient()
        let store = InMemorySeerConnectionStore(
            connection: SeerConnection(baseURL: seerBaseURL, apiKey: "KEY")
        )
        let service = SeerService(connectionStore: store, http: http)
        XCTAssertTrue(service.isConfigured)

        service.disconnect()

        XCTAssertEqual(service.phase, .unconfigured)
        XCTAssertFalse(service.isConfigured)
        XCTAssertNil(store.load())
    }

    func testRefreshStatusUnconfigured() async {
        let http = SeerRecordingHTTPClient()
        let service = SeerService(connectionStore: InMemorySeerConnectionStore(), http: http)
        await service.refreshStatus()
        XCTAssertEqual(service.phase, .unconfigured)
    }

    // MARK: - Legacy connection migration

    func testMigrationPromotesFirstConfiguredConnection() async {
        let http = SeerRecordingHTTPClient()
        http.stub(pathSuffix: "/status", json: #"{"version":"1.0"}"#)
        // Legacy: default profile (nil ns) unconfigured; a secondary profile "kid"
        // has a connection. First CONFIGURED wins — never empty-over-configured.
        let legacy = InMemorySeerCredentialStore()
        legacy.setNamespace("kid")
        try? legacy.save(SeerCredentials(baseURL: seerBaseURL, apiKey: "LEGACY", userId: nil))

        let household = InMemorySeerConnectionStore()
        let service = SeerService(connectionStore: household, legacyCredentialStore: legacy, http: http)

        let result = await service.migrateLegacyConnectionIfNeeded(namespaces: [nil, "kid"])

        XCTAssertTrue(result.didPromote)
        XCTAssertEqual(household.load()?.apiKey, "LEGACY")
        XCTAssertTrue(service.isConfigured, "Household connection adopted after migration")
        // Legacy item consumed.
        legacy.setNamespace("kid")
        XCTAssertNil(legacy.load(), "Legacy per-profile connection cleared after promotion")
    }

    func testMigrationFlagsConflictingConnections() async {
        let http = SeerRecordingHTTPClient()
        http.stub(pathSuffix: "/status", json: #"{"version":"1.0"}"#)
        let legacy = InMemorySeerCredentialStore()
        legacy.setNamespace(nil)
        try? legacy.save(SeerCredentials(baseURL: URL(string: "https://a.example.com")!, apiKey: "A"))
        legacy.setNamespace("kid")
        try? legacy.save(SeerCredentials(baseURL: URL(string: "https://b.example.com")!, apiKey: "B"))

        let household = InMemorySeerConnectionStore()
        let service = SeerService(connectionStore: household, legacyCredentialStore: legacy, http: http)

        let result = await service.migrateLegacyConnectionIfNeeded(namespaces: [nil, "kid"])

        XCTAssertTrue(result.didPromote)
        XCTAssertEqual(household.load()?.apiKey, "A", "Default (first) connection wins")
        XCTAssertTrue(result.hadConflictingConnections, "A second, different server is flagged")
    }

    func testMigrationNoOpWhenHouseholdAlreadyConfigured() async {
        let http = SeerRecordingHTTPClient()
        let legacy = InMemorySeerCredentialStore()
        legacy.setNamespace(nil)
        try? legacy.save(SeerCredentials(baseURL: URL(string: "https://legacy.example.com")!, apiKey: "LEGACY"))

        let household = InMemorySeerConnectionStore(
            connection: SeerConnection(baseURL: seerBaseURL, apiKey: "HOUSEHOLD")
        )
        let service = SeerService(connectionStore: household, legacyCredentialStore: legacy, http: http)

        let result = await service.migrateLegacyConnectionIfNeeded(namespaces: [nil])

        XCTAssertFalse(result.didPromote, "Never clobber an already-configured household slot")
        XCTAssertEqual(household.load()?.apiKey, "HOUSEHOLD")
    }

    func testMigrationKeepsLegacyIntactWhenHouseholdSaveFails() async {
        // Loss-safe guarantee: if the household Keychain write fails, the legacy
        // per-profile connection MUST survive so the next launch can retry — never
        // delete it and report a promotion that didn't persist.
        let http = SeerRecordingHTTPClient()
        let legacy = InMemorySeerCredentialStore()
        legacy.setNamespace("kid")
        try? legacy.save(SeerCredentials(baseURL: seerBaseURL, apiKey: "LEGACY", userId: nil))

        let household = FailingSeerConnectionStore()
        let service = SeerService(connectionStore: household, legacyCredentialStore: legacy, http: http)

        let result = await service.migrateLegacyConnectionIfNeeded(namespaces: [nil, "kid"])

        XCTAssertFalse(result.didPromote, "A failed household save must not report a promotion")
        XCTAssertNil(result.connection)
        XCTAssertNil(household.load(), "Nothing persisted to the household slot")
        legacy.setNamespace("kid")
        XCTAssertEqual(legacy.load()?.apiKey, "LEGACY", "Legacy connection preserved for a retry")
    }
}

/// A connection store whose `save` always throws, to exercise the migration's
/// loss-safe path (legacy must not be cleared when the household write fails).
private final class FailingSeerConnectionStore: SeerConnectionStoring, @unchecked Sendable {
    func load() -> SeerConnection? { nil }
    func save(_ connection: SeerConnection) throws { throw SeerConnectionStoreError.encodingFailed }
    func clear() throws {}
}
