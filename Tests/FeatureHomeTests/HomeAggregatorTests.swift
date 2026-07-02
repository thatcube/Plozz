import XCTest
import CoreModels
@testable import FeatureHome

@MainActor
final class HomeAggregatorTests: XCTestCase {
    func testInterleaveRoundRobinPreservesGroupOrder() {
        let merged = HomeAggregator.interleave([["a1", "a2", "a3"], ["b1"], ["c1", "c2"]])
        XCTAssertEqual(merged, ["a1", "b1", "c1", "a2", "c2", "a3"])
    }

    func testInterleaveEmptyGroups() {
        XCTAssertEqual(HomeAggregator.interleave([[String]]()), [])
        XCTAssertEqual(HomeAggregator.interleave([[], ["x"], []]), ["x"])
    }

    func testContentMergesTagsAndInterleavesAcrossAccounts() async {
        let plex = AggregatorStub(
            libraries: [library("L1", "Movies")],
            continueWatching: [item("p-cw1")],
            latest: [item("p-l1"), item("p-l2")]
        )
        let jelly = AggregatorStub(
            libraries: [library("L9", "Anime")],
            continueWatching: [item("j-cw1")],
            latest: [item("j-l1")]
        )
        let accounts = [
            resolved("acct-plex", user: "Bob", server: "Plex Server", kind: .plex, provider: plex),
            resolved("acct-jelly", user: "Alice", server: "Jelly Server", kind: .jellyfin, provider: jelly)
        ]

        let content = await HomeAggregator().content(from: accounts)

        // Continue Watching: round-robin interleaved and source-tagged.
        XCTAssertEqual(content.continueWatching.map(\.id), ["p-cw1", "j-cw1"])
        XCTAssertEqual(content.continueWatching.first?.sourceAccountID, "acct-plex")
        XCTAssertEqual(content.continueWatching.last?.sourceAccountID, "acct-jelly")

        // Recently Added: p-l1, j-l1, p-l2 (one from each, then the remainder).
        XCTAssertEqual(content.latest.map(\.id), ["p-l1", "j-l1", "p-l2"])

        // Libraries: tagged with account/provider metadata and a stable key.
        XCTAssertEqual(content.libraries.count, 2)
        let first = content.libraries[0]
        XCTAssertEqual(first.accountID, "acct-plex")
        XCTAssertEqual(first.accountName, "Bob")
        XCTAssertEqual(first.serverName, "Plex Server")
        XCTAssertEqual(first.providerKind, .plex)
        XCTAssertEqual(first.key, "acct-plex:L1")
        XCTAssertEqual(first.library.sourceAccountID, "acct-plex")
    }

    func testContentResilientToOneProviderFailing() async {
        let good = AggregatorStub(
            libraries: [library("L1", "Movies")],
            continueWatching: [item("g1")],
            latest: []
        )
        let bad = AggregatorStub.failing()
        let accounts = [
            resolved("acct-good", user: "A", server: "S1", kind: .jellyfin, provider: good),
            resolved("acct-bad", user: "B", server: "S2", kind: .plex, provider: bad)
        ]

        let content = await HomeAggregator().content(from: accounts)

        XCTAssertEqual(content.libraries.map(\.accountID), ["acct-good"])
        XCTAssertEqual(content.continueWatching.map(\.id), ["g1"])
        XCTAssertTrue(content.latest.isEmpty)
    }

    func testLibrariesDiscoveryTagsEveryAccount() async {
        let plex = AggregatorStub(libraries: [library("L1", "Movies"), library("L2", "Shows")])
        let jelly = AggregatorStub(libraries: [library("L1", "Films")])
        let accounts = [
            resolved("acct-plex", user: "Bob", server: "Plex", kind: .plex, provider: plex),
            resolved("acct-jelly", user: "Alice", server: "Jelly", kind: .jellyfin, provider: jelly)
        ]

        let libraries = await HomeAggregator().libraries(from: accounts)

        XCTAssertEqual(libraries.map(\.key), ["acct-plex:L1", "acct-plex:L2", "acct-jelly:L1"])
        // Same underlying library id on two accounts stays distinct via the key.
        XCTAssertEqual(Set(libraries.map(\.key)).count, 3)
    }

    func testContentNeverMergesSameTitleLibraryTilesAcrossAccounts() async {
        // The bug: two accounts each expose a "Movies" library (same kind+title).
        // Library TILES must NOT be merged across accounts — each must get its own
        // tile keyed `accountID:library.id`, so the second one never vanishes.
        let plex = AggregatorStub(libraries: [library("movies-plex", "Movies"), library("anime-plex", "Anime")])
        let jelly = AggregatorStub(libraries: [library("movies-jelly", "Movies")])
        let accounts = [
            resolved("acct-plex", user: "Bob", server: "Plex", kind: .plex, provider: plex),
            resolved("acct-jelly", user: "Alice", server: "Jelly", kind: .jellyfin, provider: jelly)
        ]

        let content = await HomeAggregator().content(from: accounts)

        XCTAssertEqual(content.libraries.count, 3, "Every library keeps its own tile — same-named ones don't fold")
        XCTAssertEqual(content.libraries.map(\.key),
                       ["acct-plex:movies-plex", "acct-plex:anime-plex", "acct-jelly:movies-jelly"],
                       "First account first, then each account's own order — matches the Settings checklist")
        // Each tile stays single-source so its browse targets its own server only.
        for tile in content.libraries {
            XCTAssertEqual(tile.library.allSourceAccountIDs.count, 1,
                           "Un-merged tiles are single-source")
        }
        // The two same-named "Movies" tiles are distinct, each on its own account.
        let movies = content.libraries.filter { $0.library.title == "Movies" }
        XCTAssertEqual(movies.count, 2)
        XCTAssertEqual(Set(movies.map(\.accountID)), ["acct-plex", "acct-jelly"])
    }

    func testContentKeepsEveryAccountsTileEvenWithIdenticalLibraryIDs() async {
        // Two accounts whose libraries collide on raw id ("1") AND title still
        // produce two tiles — the visibility key namespaces by account.
        let a = AggregatorStub(libraries: [library("1", "Movies")])
        let b = AggregatorStub(libraries: [library("1", "Movies")])
        let accounts = [
            resolved("acct-a", user: "A", server: "Server A", kind: .plex, provider: a),
            resolved("acct-b", user: "B", server: "Server B", kind: .jellyfin, provider: b)
        ]

        let content = await HomeAggregator().content(from: accounts)

        XCTAssertEqual(content.libraries.map(\.key), ["acct-a:1", "acct-b:1"])
    }

    func testContentDedupesSameTitleAcrossServersAndUnifiesState() async {
        // The same movie (shared Tmdb id) on Plex and Jellyfin, watched more
        // recently on Jellyfin.
        let plexCopy = MediaItem(id: "p-dune", title: "Dune", kind: .movie,
                                 productionYear: 2021, providerIDs: ["Tmdb": "438631"])
        let jellyCopy = MediaItem(id: "j-dune", title: "Dune", kind: .movie,
                                  productionYear: 2021, resumePosition: 240,
                                  providerIDs: ["Tmdb": "438631"],
                                  lastPlayedAt: Date(timeIntervalSince1970: 999))
        let plex = AggregatorStub(continueWatching: [plexCopy])
        let jelly = AggregatorStub(continueWatching: [jellyCopy])
        let accounts = [
            resolved("acct-plex", user: "Bob", server: "Plex", kind: .plex, provider: plex),
            resolved("acct-jelly", user: "Alice", server: "Jelly", kind: .jellyfin, provider: jelly)
        ]

        let content = await HomeAggregator().content(from: accounts)

        XCTAssertEqual(content.continueWatching.count, 1, "Same movie on two servers shows once")
        let card = content.continueWatching[0]
        XCTAssertEqual(card.sourceAccountID, "acct-plex", "First server stays primary")
        XCTAssertEqual(Set(card.allSourceAccountIDs), ["acct-plex", "acct-jelly"])
        XCTAssertEqual(card.resumePosition, 240, "Unified watch-state reflects the newer Jellyfin progress")
        XCTAssertEqual(card.sources.first { $0.accountID == "acct-jelly" }?.itemID, "j-dune",
                       "Each server's own item id is retained for playback")
        // Server labels come from the resolved accounts.
        XCTAssertEqual(card.sources.first?.providerKind, .plex)
    }

    func testContinueWatchingNextUpKeepsItsOwnServersRecencyAcrossMerge() async {
        // Regression for the reported "Continue Watching shifts / isn't what I
        // watched last" bug. Server A's activity is OLD: an in-progress episode
        // (T1) followed by its "Next Up" suggestion whose series-recency stamp
        // failed, so it arrives untimestamped. Server B has a FRESH in-progress
        // card (T2 > T1). The two feeds round-robin interleave to
        // [A-inprogress, B-inprogress, A-nextup].
        //
        // An earlier positional carry-forward walked that interleaved row and let
        // A-nextup inherit B's fresh T2, floating a stale show's next episode to the
        // #2 slot. With that carry removed, an untimestamped card gets NO recency and
        // sorts to the tail — it can never steal a foreign server's timestamp. The
        // correct order is therefore B's fresh card, then server A's old in-progress
        // card, then its still-unknown Next Up.
        let old = Date(timeIntervalSince1970: 1_000)
        let fresh = Date(timeIntervalSince1970: 9_000)
        let aInProgress = MediaItem(id: "a-ip", title: "A In Progress", kind: .episode,
                                    resumePosition: 60, lastPlayedAt: old)
        let aNextUp = MediaItem(id: "a-next", title: "A Next Up", kind: .episode)
        let bInProgress = MediaItem(id: "b-ip", title: "B In Progress", kind: .episode,
                                    resumePosition: 60, lastPlayedAt: fresh)
        let a = AggregatorStub(continueWatching: [aInProgress, aNextUp])
        let b = AggregatorStub(continueWatching: [bInProgress])
        let accounts = [
            resolved("acct-a", user: "A", server: "S-A", kind: .plex, provider: a),
            resolved("acct-b", user: "B", server: "S-B", kind: .jellyfin, provider: b)
        ]

        let content = await HomeAggregator().content(from: accounts)

        XCTAssertEqual(
            content.continueWatching.map(\.id),
            ["b-ip", "a-ip", "a-next"],
            "Server B's fresh card leads; server A's untimestamped Next Up sinks to the tail instead of stealing B's recency"
        )
    }

    func testContinueWatchingUntimestampedNextUpDoesNotStealNeighborRecency() async {
        // The definitive regression for the removed positional carry-forward. A real
        // provider feed is ordered "timestamped first, untimestamped tail" — NOT
        // in-progress/next-up pairs — so an untimestamped card sits below an UNRELATED
        // show's timestamped card in the same feed.
        //
        // Server A feed: showX in-progress (T=100), then showY's Next Up whose series
        // stamp failed (untimestamped). Server B: showZ in-progress (T=50) — genuine,
        // older progress on a real show.
        //
        // The old carry-forward gave showY-next server A's T=100, floating a show the
        // user never watched ABOVE showZ (real, if older, progress). Without carry,
        // showY-next has no recency and sorts last, so showZ correctly outranks it.
        let x = Date(timeIntervalSince1970: 100)
        let z = Date(timeIntervalSince1970: 50)
        let xInProgress = MediaItem(id: "x-ip", title: "Show X", kind: .episode,
                                    resumePosition: 60, lastPlayedAt: x)
        let yNextUp = MediaItem(id: "y-next", title: "Show Y", kind: .episode)
        let zInProgress = MediaItem(id: "z-ip", title: "Show Z", kind: .episode,
                                    resumePosition: 60, lastPlayedAt: z)
        let a = AggregatorStub(continueWatching: [xInProgress, yNextUp])
        let b = AggregatorStub(continueWatching: [zInProgress])
        let accounts = [
            resolved("acct-a", user: "A", server: "S-A", kind: .jellyfin, provider: a),
            resolved("acct-b", user: "B", server: "S-B", kind: .plex, provider: b)
        ]

        let content = await HomeAggregator().content(from: accounts)

        XCTAssertEqual(
            content.continueWatching.map(\.id),
            ["x-ip", "z-ip", "y-next"],
            "An untimestamped Next Up must not inherit an unrelated show's timestamp; real (even older) progress outranks it"
        )
    }

    func testContinueWatchingStampedNextUpRanksByItsSeriesRecency() async {
        // Models the real provider pipeline: each provider stamps a "Next Up"
        // suggestion with its SERIES' recency before the feed reaches the aggregator
        // (JellyfinProvider/PlexProvider stampingSeriesRecency). A properly-stamped
        // Next Up therefore ranks by real recency — here A's active show and its next
        // episode both lead server B's older card — via the correct mechanism
        // (provider stamping) rather than the removed positional carry-forward.
        let recent = Date(timeIntervalSince1970: 5_000)
        let seriesStamp = Date(timeIntervalSince1970: 4_900)
        let older = Date(timeIntervalSince1970: 3_000)
        let aInProgress = MediaItem(id: "a-ip", title: "A In Progress", kind: .episode,
                                    resumePosition: 60, lastPlayedAt: recent)
        let aNextUp = MediaItem(id: "a-next", title: "A Next Up", kind: .episode,
                                lastPlayedAt: seriesStamp)
        let bInProgress = MediaItem(id: "b-ip", title: "B In Progress", kind: .episode,
                                    resumePosition: 60, lastPlayedAt: older)
        let a = AggregatorStub(continueWatching: [aInProgress, aNextUp])
        let b = AggregatorStub(continueWatching: [bInProgress])
        let accounts = [
            resolved("acct-a", user: "A", server: "S-A", kind: .plex, provider: a),
            resolved("acct-b", user: "B", server: "S-B", kind: .jellyfin, provider: b)
        ]

        let content = await HomeAggregator().content(from: accounts)

        XCTAssertEqual(
            content.continueWatching.map(\.id),
            ["a-ip", "a-next", "b-ip"],
            "A provider-stamped Next Up ranks by its series recency, above a staler foreign server's card"
        )
    }


    func testContentCapsMergedRowsToRequestedLimits() async {
        let a = AggregatorStub(
            continueWatching: [item("a1"), item("a2"), item("a3")],
            latest: [item("al1"), item("al2"), item("al3")]
        )
        let b = AggregatorStub(
            continueWatching: [item("b1"), item("b2"), item("b3")],
            latest: [item("bl1"), item("bl2"), item("bl3")]
        )
        let accounts = [
            resolved("acct-a", user: "A", server: "S-A", kind: .jellyfin, provider: a),
            resolved("acct-b", user: "B", server: "S-B", kind: .plex, provider: b)
        ]

        let content = await HomeAggregator().content(
            from: accounts,
            continueWatchingLimit: 2,
            latestLimit: 3
        )

        XCTAssertEqual(content.continueWatching.map(\.id), ["a1", "b1"])
        XCTAssertEqual(content.latest.map(\.id), ["al1", "bl1", "al2"])
    }

    func testContentBoundsConcurrentAccountFanOut() async {
        let tracker = ConcurrencyTracker()
        let accounts: [ResolvedAccount] = (0..<8).map { index in
            resolved(
                "acct-\(index)",
                user: "U\(index)",
                server: "S\(index)",
                kind: .jellyfin,
                provider: DelayedAggregatorStub(
                    itemID: "i\(index)",
                    tracker: tracker,
                    delayNanoseconds: 50_000_000
                )
            )
        }

        _ = await HomeAggregator().content(from: accounts, continueWatchingLimit: 1, latestLimit: 1)

        // Fan-out is bounded (never unbounded) so a large server list can't swamp
        // the launch-time network/decoding pipeline. The bound is sized to fully
        // parallelize a typical multi-server household (~5) in a single wave while
        // still capping pathological (many-server) cases: 8 accounts here must
        // still run at most 5 at a time.
        XCTAssertLessThanOrEqual(
            tracker.maxConcurrent,
            5,
            "Home aggregation should bound concurrent account fan-out to keep launch responsive"
        )
    }

    func testContentDedupesSeriesAcrossServersWhenExternalIDsPresent() async {
        // Series identity is external-id-only (never title/year), so this must
        // collapse only because both servers carry the same TMDb id AND the same
        // debut year (a genuine cross-server duplicate of one show).
        let plexCopy = MediaItem(id: "p-op", title: "One Piece", kind: .series,
                                 productionYear: 1999, providerIDs: ["Tmdb": "37854"])
        let jellyCopy = MediaItem(id: "j-op", title: "ONE PIECE (Subtitled)", kind: .series,
                                  productionYear: 1999, providerIDs: ["Tmdb": "37854"])
        let plex = AggregatorStub(latest: [plexCopy])
        let jelly = AggregatorStub(latest: [jellyCopy])
        let accounts = [
            resolved("acct-plex", user: "Bob", server: "Plex", kind: .plex, provider: plex),
            resolved("acct-jelly", user: "Alice", server: "Jelly", kind: .jellyfin, provider: jelly)
        ]

        let content = await HomeAggregator().content(from: accounts)

        XCTAssertEqual(content.latest.count, 1)
        let card = content.latest[0]
        XCTAssertEqual(card.id, "p-op")
        XCTAssertEqual(card.sources.count, 2, "Merged card exposes both server sources for the picker")
        XCTAssertEqual(Set(card.allSourceAccountIDs), ["acct-plex", "acct-jelly"])
    }

    func testContentSplitsSeriesWithLargeYearGapDespiteSharedExternalID() async {
        // The One Piece false-merge: the 1999 anime and the 2023 live-action are
        // bridged by one server emitting the same TMDb id for both. A shared id
        // alone would hide one show from Home; the large production-year gap splits
        // them back into two cards so both stay visible.
        let anime = MediaItem(id: "p-op", title: "One Piece", kind: .series,
                              productionYear: 1999, providerIDs: ["Tmdb": "37854"])
        let live = MediaItem(id: "j-op", title: "One Piece", kind: .series,
                             productionYear: 2023, providerIDs: ["Tmdb": "37854"])
        let plex = AggregatorStub(latest: [anime])
        let jelly = AggregatorStub(latest: [live])
        let accounts = [
            resolved("acct-plex", user: "Bob", server: "Plex", kind: .plex, provider: plex),
            resolved("acct-jelly", user: "Alice", server: "Jelly", kind: .jellyfin, provider: jelly)
        ]

        let content = await HomeAggregator().content(from: accounts)

        XCTAssertEqual(content.latest.count, 2, "Anime and live-action must remain two separate cards")
        XCTAssertEqual(Set(content.latest.map(\.id)), ["p-op", "j-op"])
        XCTAssertTrue(content.latest.allSatisfy { $0.sources.isEmpty },
                      "Neither should absorb the other as a source")
    }

    // MARK: - Helpers

    private func item(_ id: String) -> MediaItem {
        MediaItem(id: id, title: id, kind: .movie)
    }

    private func library(_ id: String, _ title: String) -> MediaLibrary {
        MediaLibrary(id: id, title: title, kind: .movie)
    }

    private func resolved(
        _ id: String,
        user: String,
        server: String,
        kind: ProviderKind,
        provider: any MediaProvider
    ) -> ResolvedAccount {
        let mediaServer = MediaServer(
            id: "srv-\(id)",
            name: server,
            baseURL: URL(string: "http://host")!,
            provider: kind
        )
        let account = Account(id: id, server: mediaServer, userID: "u-\(id)", userName: user, deviceID: "d-\(id)")
        return ResolvedAccount(account: account, provider: provider)
    }
}

/// Configurable `MediaProvider` stub for aggregation tests.
private final class AggregatorStub: MediaProvider, @unchecked Sendable {
    let kind: ProviderKind = .jellyfin
    let session: UserSession
    private let stubbedLibraries: [MediaLibrary]
    private let stubbedContinueWatching: [MediaItem]
    private let stubbedLatest: [MediaItem]
    private let shouldFail: Bool

    init(
        libraries: [MediaLibrary] = [],
        continueWatching: [MediaItem] = [],
        latest: [MediaItem] = [],
        shouldFail: Bool = false
    ) {
        self.stubbedLibraries = libraries
        self.stubbedContinueWatching = continueWatching
        self.stubbedLatest = latest
        self.shouldFail = shouldFail
        self.session = UserSession(
            server: MediaServer(id: "s", name: "Home", baseURL: URL(string: "http://host")!, provider: .jellyfin),
            userID: "u", userName: "User", deviceID: "d", accessToken: "TOKEN"
        )
    }

    static func failing() -> AggregatorStub { AggregatorStub(shouldFail: true) }

    func libraries() async throws -> [MediaLibrary] {
        if shouldFail { throw AppError.serverUnreachable }
        return stubbedLibraries
    }

    func continueWatching(limit: Int) async throws -> [MediaItem] {
        if shouldFail { throw AppError.serverUnreachable }
        return stubbedContinueWatching
    }

    func latest(limit: Int) async throws -> [MediaItem] {
        if shouldFail { throw AppError.serverUnreachable }
        return stubbedLatest
    }

    func item(id: String) async throws -> MediaItem { throw AppError.notFound }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        MediaPage(items: [], startIndex: 0, totalCount: 0)
    }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}

private final class DelayedAggregatorStub: MediaProvider, @unchecked Sendable {
    let kind: ProviderKind = .jellyfin
    let session: UserSession
    private let itemID: String
    private let tracker: ConcurrencyTracker
    private let delayNanoseconds: UInt64

    init(itemID: String, tracker: ConcurrencyTracker, delayNanoseconds: UInt64) {
        self.itemID = itemID
        self.tracker = tracker
        self.delayNanoseconds = delayNanoseconds
        self.session = UserSession(
            server: MediaServer(id: "s-\(itemID)", name: "Home", baseURL: URL(string: "http://host")!, provider: .jellyfin),
            userID: "u-\(itemID)", userName: "User", deviceID: "d-\(itemID)", accessToken: "TOKEN"
        )
    }

    func libraries() async throws -> [MediaLibrary] { [] }

    func continueWatching(limit: Int) async throws -> [MediaItem] {
        tracker.enter()
        defer { tracker.leave() }
        try? await Task.sleep(nanoseconds: delayNanoseconds)
        return [MediaItem(id: itemID, title: itemID, kind: .movie)]
    }

    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func item(id: String) async throws -> MediaItem { throw AppError.notFound }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        MediaPage(items: [], startIndex: 0, totalCount: 0)
    }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}

private final class ConcurrencyTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    private var maxSeen = 0

    func enter() {
        lock.lock()
        current += 1
        if current > maxSeen { maxSeen = current }
        lock.unlock()
    }

    func leave() {
        lock.lock()
        current = max(0, current - 1)
        lock.unlock()
    }

    var maxConcurrent: Int {
        lock.lock()
        defer { lock.unlock() }
        return maxSeen
    }
}
