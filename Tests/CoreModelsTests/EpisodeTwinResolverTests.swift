import XCTest
@testable import CoreModels

/// Exercises ``EpisodeTwinResolver`` — the per-episode cross-server twin finder
/// that closes the "an episode watch only converges on its origin server" gap.
/// Confidence gating and inconclusive-vs-conclusive outcomes are the contract
/// under test, so every assertion is about *whether a twin target is emitted* and
/// *whether the account is retried*.
final class EpisodeTwinResolverTests: XCTestCase {
    // MARK: - Fixtures

    private func series(id: String, title: String = "Euphoria", tmdb: String? = "85552", tvdb: String? = nil) -> MediaItem {
        var ids: [String: String] = [:]
        if let tmdb { ids["Tmdb"] = tmdb }
        if let tvdb { ids["Tvdb"] = tvdb }
        return MediaItem(id: id, title: title, kind: .series, providerIDs: ids)
    }

    private func season(id: String, number: Int) -> MediaItem {
        MediaItem(id: id, title: "Season \(number)", kind: .season, seasonNumber: number)
    }

    private func episode(id: String, season: Int, episode: Int) -> MediaItem {
        MediaItem(id: id, title: "E\(episode)", kind: .episode, seasonNumber: season, episodeNumber: episode)
    }

    /// A single-server library tree the closures read from, keyed by container id.
    private struct Library {
        var seriesHits: [MediaItem]
        var children: [String: [MediaItem]]
    }

    private func resolve(
        originSeries: MediaItem,
        season: Int,
        episode: Int,
        libraries: [String: Library?],          // accountID → library (nil ⇒ probe fails)
        kinds: [String: ProviderKind] = [:]
    ) async -> WatchTargetExpansion {
        await EpisodeTwinResolver.resolve(
            originSeries: originSeries,
            seasonNumber: season,
            episodeNumber: episode,
            otherAccountIDs: Array(libraries.keys).sorted(),
            searchSeries: { accountID, _ in
                guard let library = libraries[accountID] else { return [] }
                return library?.seriesHits   // nil library ⇒ search failed
            },
            children: { accountID, containerID in
                guard let library = libraries[accountID] else { return [] }
                return library?.children[containerID]   // nil library or missing key ⇒ fail
            },
            providerKind: { kinds[$0] }
        )
    }

    // MARK: - Confident match

    func testConfidentTwinResolvedByExactSeriesIdentityAndEpisode() async throws {
        let origin = series(id: "A-series")
        let library = Library(
            seriesHits: [series(id: "B-series")],   // same TMDb id, different local id
            children: [
                "B-series": [season(id: "B-s1", number: 1), season(id: "B-s2", number: 2)],
                "B-s1": [episode(id: "B-s1e1", season: 1, episode: 1), episode(id: "B-s1e2", season: 1, episode: 2)]
            ]
        )
        let result = await resolve(
            originSeries: origin, season: 1, episode: 2,
            libraries: ["B": library], kinds: ["B": .plex]
        )
        XCTAssertEqual(result.targets, [WatchMutationTarget(accountID: "B", itemID: "B-s1e2", providerKind: .plex)])
        XCTAssertTrue(result.isConclusive)
    }

    func testMatchByTvdbWhenTitlesDiffer() async throws {
        let origin = series(id: "A-series", title: "Euphoria", tmdb: nil, tvdb: "85552")
        // Other server stores the show under a different display title but same TVDb.
        var hit = series(id: "B-series", title: "Euphoria (US)", tmdb: nil, tvdb: "85552")
        hit.title = "Euphoria — Original"
        let library = Library(
            seriesHits: [hit],
            children: [
                "B-series": [season(id: "B-s1", number: 1)],
                "B-s1": [episode(id: "B-s1e3", season: 1, episode: 3)]
            ]
        )
        let result = await resolve(originSeries: origin, season: 1, episode: 3, libraries: ["B": library])
        XCTAssertEqual(result.targets.map(\.itemID), ["B-s1e3"])
        XCTAssertTrue(result.isConclusive)
    }

    func testEpisodesDirectlyUnderSeriesAreMatched() async throws {
        // A server that returns episodes flat under the series (no season layer).
        let origin = series(id: "A-series")
        let library = Library(
            seriesHits: [series(id: "B-series")],
            children: ["B-series": [episode(id: "B-flat", season: 2, episode: 4)]]
        )
        let result = await resolve(originSeries: origin, season: 2, episode: 4, libraries: ["B": library])
        XCTAssertEqual(result.targets.map(\.itemID), ["B-flat"])
        XCTAssertTrue(result.isConclusive)
    }

    // MARK: - Confident skips (no retry)

    func testDifferentSeriesIsConclusiveNoTarget() async throws {
        let origin = series(id: "A-series", tmdb: "85552")
        let library = Library(seriesHits: [series(id: "B-other", tmdb: "999")], children: [:])
        let result = await resolve(originSeries: origin, season: 1, episode: 1, libraries: ["B": library])
        XCTAssertTrue(result.targets.isEmpty)
        XCTAssertTrue(result.isConclusive, "A server that clearly lacks the show must not be retried")
    }

    func testMissingEpisodeIsConclusiveNoTarget() async throws {
        let origin = series(id: "A-series")
        let library = Library(
            seriesHits: [series(id: "B-series")],
            children: [
                "B-series": [season(id: "B-s1", number: 1)],
                "B-s1": [episode(id: "B-s1e1", season: 1, episode: 1)]   // no E5
            ]
        )
        let result = await resolve(originSeries: origin, season: 1, episode: 5, libraries: ["B": library])
        XCTAssertTrue(result.targets.isEmpty)
        XCTAssertTrue(result.isConclusive)
    }

    func testAmbiguousDuplicateEpisodesSkipButConclusive() async throws {
        let origin = series(id: "A-series")
        let library = Library(
            seriesHits: [series(id: "B-series")],
            children: [
                "B-series": [season(id: "B-s1", number: 1)],
                "B-s1": [episode(id: "B-dup1", season: 1, episode: 1), episode(id: "B-dup2", season: 1, episode: 1)]
            ]
        )
        let result = await resolve(originSeries: origin, season: 1, episode: 1, libraries: ["B": library])
        XCTAssertTrue(result.targets.isEmpty, "Two candidate ids ⇒ skip rather than guess")
        XCTAssertTrue(result.isConclusive, "Ambiguity won't resolve on retry, so don't keep retrying")
    }

    func testNoStrongSeriesIdentityGivesUpConclusively() async throws {
        // Series with no imdb/tmdb/tvdb id ⇒ can't match a twin safely.
        let origin = series(id: "A-series", tmdb: nil, tvdb: nil)
        let library = Library(seriesHits: [series(id: "B-series")], children: [:])
        let result = await resolve(originSeries: origin, season: 1, episode: 1, libraries: ["B": library])
        XCTAssertEqual(result, .none)
    }

    // MARK: - Inconclusive (retry)

    func testSearchFailureIsInconclusive() async throws {
        let origin = series(id: "A-series")
        let result = await resolve(originSeries: origin, season: 1, episode: 1, libraries: ["B": Library?.none])
        XCTAssertTrue(result.targets.isEmpty)
        XCTAssertEqual(result.inconclusiveAccountIDs, ["B"], "An unreachable server must be retried, never guessed")
    }

    func testChildrenFailureIsInconclusive() async throws {
        let origin = series(id: "A-series")
        // Series matches, but the series' children can't be enumerated.
        let library = Library(seriesHits: [series(id: "B-series")], children: [:])
        let result = await resolve(originSeries: origin, season: 1, episode: 1, libraries: ["B": library])
        XCTAssertTrue(result.targets.isEmpty)
        XCTAssertEqual(result.inconclusiveAccountIDs, ["B"])
    }

    func testConfidentTwinOnOneServerWhileAnotherIsInconclusive() async throws {
        let origin = series(id: "A-series")
        let good = Library(
            seriesHits: [series(id: "B-series")],
            children: ["B-series": [season(id: "B-s1", number: 1)], "B-s1": [episode(id: "B-ep", season: 1, episode: 1)]]
        )
        let result = await resolve(
            originSeries: origin, season: 1, episode: 1,
            libraries: ["B": good, "C": Library?.none]
        )
        XCTAssertEqual(result.targets.map(\.itemID), ["B-ep"], "Write the server we're sure about…")
        XCTAssertEqual(result.inconclusiveAccountIDs, ["C"], "…and retry the one we couldn't reach")
    }

    // MARK: - Single-server no-op

    func testNoOtherAccountsIsNoOpWithoutProbing() async throws {
        let probed = LockedFlag()
        let origin = series(id: "A-series")
        let result = await EpisodeTwinResolver.resolve(
            originSeries: origin,
            seasonNumber: 1, episodeNumber: 1,
            otherAccountIDs: [],
            searchSeries: { _, _ in probed.set(); return [] },
            children: { _, _ in probed.set(); return [] }
        )
        XCTAssertEqual(result, .none)
        XCTAssertFalse(probed.value, "A single-server household must never probe the network")
    }
}

/// Minimal thread-safe flag for asserting a closure never ran.
private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}
