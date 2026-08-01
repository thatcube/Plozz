import XCTest
import CoreModels
import RatingsService
@testable import AppShell

final class HeroMetadataEnricherTests: XCTestCase {
    func testFillsOverviewAndTaglinesWhenOtherHeroMetadataIsAlreadyPresent() async throws {
        let accountID = "jellyfin-account"
        let sparse = MediaItem(
            id: "movie",
            title: "Movie",
            kind: .movie,
            productionYear: 2004,
            officialRating: "PG-13",
            genres: ["Comedy"],
            sourceAccountID: accountID
        )
        var detail = sparse
        detail.overview = "A complete Jellyfin overview."
        detail.taglines = ["For some, 13 feels like it was just yesterday."]
        let account = resolved(accountID, detail: detail)

        let enrich = makeHeroMetadataEnricher(
            accounts: [account],
            identitySources: { _ in [] }
        )
        let result = await enrich([sparse])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].overview, detail.overview)
        XCTAssertEqual(result[0].taglines, detail.taglines)
        XCTAssertEqual(result[0].id, sparse.id)
        XCTAssertEqual(result[0].sourceAccountID, sparse.sourceAccountID)
    }

    func testPreservesExistingOverviewAndTaglinesWhileFillingOtherMissingFields() async throws {
        let accountID = "jellyfin-account"
        let sparse = MediaItem(
            id: "movie",
            title: "Movie",
            kind: .movie,
            overview: "Server-selected overview.",
            taglines: ["Server-selected tagline."],
            sourceAccountID: accountID
        )
        var detail = sparse
        detail.overview = "Replacement overview."
        detail.taglines = ["Replacement tagline."]
        detail.productionYear = 2004
        detail.officialRating = "PG-13"
        detail.genres = ["Comedy"]
        let account = resolved(accountID, detail: detail)

        let enrich = makeHeroMetadataEnricher(
            accounts: [account],
            identitySources: { _ in [] }
        )
        let result = await enrich([sparse])

        XCTAssertEqual(result[0].overview, sparse.overview)
        XCTAssertEqual(result[0].taglines, sparse.taglines)
        XCTAssertEqual(result[0].productionYear, 2004)
        XCTAssertEqual(result[0].officialRating, "PG-13")
        XCTAssertEqual(result[0].genres, ["Comedy"])
    }

    func testEpisodeHydrationPreservesSelectedSourceAccountAndHierarchy() async throws {
        let accountID = "jellyfin-account"
        let original = MediaItem(
            id: "plex-discover-episode",
            title: "The Getaway",
            kind: .episode,
            seriesID: "plex-series",
            providerIDs: ["SeriesTmdb": "125988"],
            sourceAccountID: "plex-account",
            sources: [
                MediaSourceRef(
                    accountID: accountID,
                    itemID: "jellyfin-episode",
                    kind: .episode
                )
            ]
        )
        let hydratedEpisode = MediaItem(
            id: "jellyfin-episode",
            title: "The Getaway",
            kind: .episode,
            seasonNumber: 1,
            episodeNumber: 4,
            seriesID: "jellyfin-series",
            seasonID: "jellyfin-season",
            providerIDs: ["Tmdb": "episode-4"]
        )
        let series = MediaItem(
            id: "jellyfin-series",
            title: "Silo",
            kind: .series,
            genres: ["Science Fiction"],
            providerIDs: ["Tmdb": "125988", "Tvdb": "403245"]
        )
        let account = resolved(
            accountID,
            details: [
                hydratedEpisode.id: hydratedEpisode,
                series.id: series
            ]
        )

        let enrich = makeHeroMetadataEnricher(
            accounts: [account],
            identitySources: { _ in [] }
        )
        let result = await enrich([original])

        XCTAssertEqual(result[0].id, hydratedEpisode.id)
        XCTAssertEqual(result[0].sourceAccountID, accountID)
        XCTAssertEqual(result[0].seriesID, series.id)
        XCTAssertEqual(result[0].seasonID, hydratedEpisode.seasonID)
        XCTAssertEqual(result[0].providerID(.tmdb), "episode-4")
        XCTAssertEqual(result[0].providerID(.seriesTmdb), "125988")
        XCTAssertEqual(result[0].providerID(.seriesTvdb), "403245")
    }

    func testMergesSharedCachedRatingsWithoutStartingProviderWork() async {
        let accountID = "plex-account"
        let item = MediaItem(
            id: "arrietty",
            title: "The Secret World of Arrietty",
            kind: .movie,
            overview: "A tiny family lives beneath the floorboards.",
            productionYear: 2010,
            officialRating: "G",
            taglines: ["Discover a secret world."],
            ratings: [
                ExternalRating(source: .imdb, value: 7.6, scale: .outOfTen)
            ],
            sourceAccountID: accountID
        )
        let cached = CachedHeroRatingsProvider(
            ratings: [
                ExternalRating(source: .imdb, value: 7.6, scale: .outOfTen),
                ExternalRating(source: .tmdb, value: 7.7, scale: .outOfTen),
                ExternalRating(source: .anilist, value: 79, scale: .percent),
            ]
        )
        let enrich = makeHeroMetadataEnricher(
            accounts: [resolved(accountID, detail: item)],
            identitySources: { _ in [] },
            ratingsProvider: cached
        )

        let result = await enrich([item])

        XCTAssertEqual(
            Set<RatingSource>(result[0].ratings.map { $0.source }),
            [.imdb, .tmdb, .anilist]
        )
        XCTAssertEqual(cached.fetchCount, 0)
        XCTAssertEqual(cached.cacheReadCount, 1)
    }

    private func resolved(_ accountID: String, detail: MediaItem) -> ResolvedAccount {
        resolved(accountID, details: [detail.id: detail])
    }

    private func resolved(
        _ accountID: String,
        details: [String: MediaItem]
    ) -> ResolvedAccount {
        let session = UserSession(
            server: MediaServer(
                id: "server-\(accountID)",
                name: "Server",
                baseURL: URL(string: "http://jellyfin.local")!,
                provider: .jellyfin
            ),
            userID: "user",
            userName: "User",
            deviceID: "device",
            accessToken: "token"
        )
        let account = Account(
            id: accountID,
            server: session.server,
            userID: session.userID,
            userName: session.userName,
            deviceID: session.deviceID
        )
        return ResolvedAccount(
            account: account,
            provider: HeroMetadataProvider(session: session, details: details)
        )
    }
}

private final class CachedHeroRatingsProvider:
    CachedExternalRatingsProviding,
    @unchecked Sendable {
    private let lock = NSLock()
    private let stored: [ExternalRating]
    private var _fetchCount = 0
    private var _cacheReadCount = 0

    init(ratings: [ExternalRating]) {
        stored = ratings
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var fetchCount: Int {
        withLock { _fetchCount }
    }

    var cacheReadCount: Int {
        withLock { _cacheReadCount }
    }

    func ratings(for item: MediaItem) async -> [ExternalRating] {
        withLock { _fetchCount += 1 }
        return stored
    }

    func cachedRatings(for item: MediaItem) async -> [ExternalRating]? {
        withLock { _cacheReadCount += 1 }
        return stored
    }
}

private final class HeroMetadataProvider: MediaProvider, @unchecked Sendable {
    let kind: ProviderKind = .jellyfin
    let session: UserSession
    private let details: [String: MediaItem]

    init(session: UserSession, details: [String: MediaItem]) {
        self.session = session
        self.details = details
    }

    func libraries() async throws -> [MediaLibrary] { [] }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        MediaPage(items: [], startIndex: page.startIndex, totalCount: 0)
    }
    func item(id: String) async throws -> MediaItem {
        guard let detail = details[id] else { throw AppError.notFound }
        return detail
    }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}
