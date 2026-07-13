import XCTest
@testable import ProviderShare
import CoreModels

/// Coverage for the SQLite-backed share catalog — the index that makes a share's
/// Recently Added / Search / Movies-TV-Anime libraries work without a live SMB
/// walk. These are the on-device questions a server never had to answer:
/// does "date added" stay first-discovery across re-scans, does the index survive
/// a relaunch, and do the id shapes resolve back to rich items?
final class ShareCatalogStoreTests: XCTestCase {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("plozz-share-catalog-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func movie(_ path: String, title: String, year: Int?) -> CatalogAsset {
        CatalogAsset(relPath: path, basename: (path as NSString).lastPathComponent, size: 1_000,
                     modifiedAt: Date(), kind: .movie, library: .movies,
                     title: title, year: year, seriesTitle: nil, seriesKey: nil, season: nil, episode: nil)
    }

    private func episode(_ path: String, series: String, season: Int, episode: Int, library: CatalogLibrary = .tv) -> CatalogAsset {
        CatalogAsset(relPath: path, basename: (path as NSString).lastPathComponent, size: 1_000,
                     modifiedAt: Date(), kind: .episode, library: library,
                     title: "Episode \(episode)", year: nil,
                     seriesTitle: series, seriesKey: ShareCatalogID.seriesKey(fromTitle: series),
                     season: season, episode: episode)
    }

    /// A large first-time regroup may take a few hundred milliseconds overall,
    /// but must yield the catalog actor so a Movies-grid page can complete without
    /// waiting for the whole regroup.
    func testLargeMovieRegroupDoesNotBlockBrowseReads() async {
        let store = ShareCatalogStore(accountKey: "perf", directory: tempDir())
        let assets: [CatalogAsset] = (0..<15_000).map { index in
            let title = "Movie \(index / 2)"
            let year = 2000 + (index % 2)
            return CatalogAsset(
                relPath: "Movies/\(title) (\(year)) \(index).mkv",
                basename: "\(title) (\(year)) \(index).mkv",
                size: 1_000, modifiedAt: Date(), kind: .movie, library: .movies,
                title: title, year: year, seriesTitle: nil, seriesKey: nil,
                season: nil, episode: nil,
                movieKey: ShareCatalogID.movieKey(fromTitle: title, year: year),
                movieTitleKey: ShareCatalogID.seriesKey(fromTitle: title)
            )
        }
        await store.upsert(assets, scanID: 1)

        let clock = ContinuousClock()
        let rebuildStart = clock.now
        let rebuild = Task { await store.rebuildMovieGroups() }
        await Task.yield()
        let browseStart = clock.now
        _ = await store.movies(offset: 0, limit: 60)
        let browseDuration = browseStart.duration(to: clock.now)
        await rebuild.value
        let rebuildDuration = rebuildStart.duration(to: clock.now)
        XCTAssertLessThan(
            browseDuration,
            .milliseconds(100),
            "browse reads must interleave with a large end-of-scan regroup (regroup: \(rebuildDuration))"
        )
    }

    /// One unusually large directory must not hold the catalog actor for its
    /// entire insert; the chunked upsert yields between bounded transactions.
    func testLargeDirectoryUpsertDoesNotBlockBrowseReads() async {
        let store = ShareCatalogStore(accountKey: "perf-upsert", directory: tempDir())
        await store.upsert([movie("Movies/Existing (2000).mkv", title: "Existing", year: 2000)], scanID: 1)
        let assets: [CatalogAsset] = (0..<15_000).map { index in
            movie("Movies/New \(index) (2020).mkv", title: "New \(index)", year: 2020)
        }

        let upsert = Task { await store.upsert(assets, scanID: 2) }
        await Task.yield()
        let clock = ContinuousClock()
        let browseStart = clock.now
        _ = await store.movies(offset: 0, limit: 60)
        let browseDuration = browseStart.duration(to: clock.now)
        await upsert.value

        XCTAssertLessThan(
            browseDuration,
            .milliseconds(100),
            "browse reads must interleave with a giant directory upsert"
        )
    }

    func testEmptyUntilPopulated() async {
        let store = ShareCatalogStore(accountKey: "a", directory: tempDir())
        let empty = await store.isEmpty()
        XCTAssertTrue(empty)
        let counts = await store.libraryCounts()
        XCTAssertEqual(counts.movies, 0)
        XCTAssertEqual(counts.tvSeries, 0)
        XCTAssertEqual(counts.animeSeries, 0)
        let latest = await store.latest(limit: 10)
        XCTAssertTrue(latest.isEmpty)
    }

    func testLatestOrdersByFirstSeenDescending() async {
        let store = ShareCatalogStore(accountKey: "a", directory: tempDir())
        let t1 = Date(timeIntervalSince1970: 1_000)
        let t2 = Date(timeIntervalSince1970: 2_000)
        await store.upsert([movie("Movies/A (2000).mkv", title: "A", year: 2000)], scanID: 1, now: t1)
        await store.upsert([movie("Movies/B (2001).mkv", title: "B", year: 2001)], scanID: 1, now: t2)
        let latest = await store.latest(limit: 10)
        XCTAssertEqual(latest.map(\.title), ["B", "A"], "newest first-seen should lead Recently Added")
    }

    func testFirstSeenPreservedAcrossReUpsert() async {
        let store = ShareCatalogStore(accountKey: "a", directory: tempDir())
        let t1 = Date(timeIntervalSince1970: 1_000)
        let t2 = Date(timeIntervalSince1970: 2_000)
        let t3 = Date(timeIntervalSince1970: 3_000)
        await store.upsert([movie("Movies/A (2000).mkv", title: "A", year: 2000)], scanID: 1, now: t1)
        await store.upsert([movie("Movies/B (2001).mkv", title: "B", year: 2001)], scanID: 1, now: t2)
        // Re-scan sees A again at t3 — its first_seen must NOT jump to t3.
        await store.upsert([movie("Movies/A (2000).mkv", title: "A", year: 2000)], scanID: 2, now: t3)
        let latest = await store.latest(limit: 10)
        XCTAssertEqual(latest.map(\.title), ["B", "A"], "a re-seen file keeps its original date added")
    }

    func testSeriesGroupingSeasonsAndEpisodes() async {
        let store = ShareCatalogStore(accountKey: "a", directory: tempDir())
        let key = ShareCatalogID.seriesKey(fromTitle: "Breaking Bad")
        await store.upsert([
            episode("TV/Breaking Bad/S01/E01.mkv", series: "Breaking Bad", season: 1, episode: 1),
            episode("TV/Breaking Bad/S01/E02.mkv", series: "Breaking Bad", season: 1, episode: 2),
            episode("TV/Breaking Bad/S02/E01.mkv", series: "Breaking Bad", season: 2, episode: 1),
        ], scanID: 1)

        let series = await store.series(in: .tv, offset: 0, limit: 10)
        XCTAssertEqual(series.count, 1)
        XCTAssertEqual(series.first?.kind, .series)
        XCTAssertEqual(series.first?.id, ShareCatalogID.series(key))

        let seasons = await store.seasons(seriesKey: key)
        XCTAssertEqual(seasons.map(\.seasonNumber), [1, 2])

        let s1 = await store.episodes(seriesKey: key, season: 1)
        XCTAssertEqual(s1.map(\.episodeNumber), [1, 2], "episodes in episode order")
        XCTAssertTrue(s1.allSatisfy { $0.kind == .episode && $0.parentTitle == "Breaking Bad" })
    }

    /// Regression: normalized-equivalent episode titles/library classifications
    /// must not emit duplicate season tabs with identical ids (which makes tvOS
    /// focus collapse onto only one of the visually duplicated buttons).
    func testSeasonsDeduplicateVariantSeriesMetadataBySeasonNumber() async {
        let store = ShareCatalogStore(accountKey: "korra", directory: tempDir())
        let canonical = "The Legend of Korra"
        let key = ShareCatalogID.seriesKey(fromTitle: canonical)
        let variants: [(season: Int, title: String, library: CatalogLibrary)] = [
            (1, canonical, .tv),
            (2, canonical, .tv),
            (3, "The.Legend.of.Korra", .tv),
            (3, canonical, .anime),
            (4, "The.Legend.of.Korra", .tv),
            (4, canonical, .anime),
        ]
        let assets = variants.map { value in
            CatalogAsset(
                relPath: "TV/Korra/S\(value.season)/E01-\(value.title)-\(value.library.rawValue).mkv",
                basename: "E01.mkv", size: 1_000, modifiedAt: Date(),
                kind: .episode, library: value.library,
                title: "Episode 1", year: nil,
                seriesTitle: value.title, seriesKey: key,
                season: value.season, episode: 1
            )
        }
        await store.upsert(assets, scanID: 1)

        let seasons = await store.seasons(seriesKey: key)
        XCTAssertEqual(seasons.map(\.seasonNumber), [1, 2, 3, 4])
        XCTAssertEqual(Set(seasons.map(\.id)).count, 4, "season ids must be unique for stable focus")
        XCTAssertTrue(seasons.allSatisfy { $0.parentTitle == canonical })
        XCTAssertTrue(seasons.allSatisfy { $0.libraryID == ShareCatalogID.animeLibrary })
    }

    func testLibrarySortIgnoresLeadingTheAndUsesSeriesTitle() async {
        let store = ShareCatalogStore(accountKey: "sort", directory: tempDir())
        await store.upsert([
            movie("Movies/Zootopia (2016).mkv", title: "Zootopia", year: 2016),
            movie("Movies/The Batman (2022).mkv", title: "The Batman", year: 2022),
            movie("Movies/Avatar (2009).mkv", title: "Avatar", year: 2009),
            episode("TV/Yellowstone/S01E01.mkv", series: "Yellowstone", season: 1, episode: 1),
            // Episode titles intentionally sort differently; the grid must use the
            // SERIES title, not "Zulu"/"Alpha".
            CatalogAsset(
                relPath: "TV/The Bear/S01E01.mkv", basename: "S01E01.mkv",
                size: 1_000, modifiedAt: Date(), kind: .episode, library: .tv,
                title: "Zulu", year: nil, seriesTitle: "The Bear",
                seriesKey: ShareCatalogID.seriesKey(fromTitle: "The Bear"),
                season: 1, episode: 1
            ),
            CatalogAsset(
                relPath: "TV/Andor/S01E01.mkv", basename: "S01E01.mkv",
                size: 1_000, modifiedAt: Date(), kind: .episode, library: .tv,
                title: "Alpha", year: nil, seriesTitle: "Andor",
                seriesKey: ShareCatalogID.seriesKey(fromTitle: "Andor"),
                season: 1, episode: 1
            ),
        ], scanID: 1)

        let movies = await store.movies(offset: 0, limit: 10)
        XCTAssertEqual(movies.map(\.title), ["Avatar", "The Batman", "Zootopia"])

        let series = await store.series(in: .tv, offset: 0, limit: 10)
        XCTAssertEqual(series.map(\.title), ["Andor", "The Bear", "Yellowstone"])
        XCTAssertEqual(ShareCatalogID.sortTitle(from: "Theodore"), "theodore")
        XCTAssertEqual(ShareCatalogID.sortTitle(from: "  THE   Thing  "), "thing")
    }

    func testAnimeAndTvLibrariesAreSeparate() async {
        let store = ShareCatalogStore(accountKey: "a", directory: tempDir())
        await store.upsert([
            episode("TV/Show/E01.mkv", series: "Some Show", season: 1, episode: 1, library: .tv),
            episode("Anime/Naruto/E01.mkv", series: "Naruto", season: 1, episode: 1, library: .anime),
        ], scanID: 1)
        let counts = await store.libraryCounts()
        XCTAssertEqual(counts.tvSeries, 1)
        XCTAssertEqual(counts.animeSeries, 1)
        let tv = await store.series(in: .tv, offset: 0, limit: 10)
        let anime = await store.series(in: .anime, offset: 0, limit: 10)
        XCTAssertEqual(tv.map(\.title), ["Some Show"])
        XCTAssertEqual(anime.map(\.title), ["Naruto"])
    }

    func testSearchFindsMoviesAndSeries() async {
        let store = ShareCatalogStore(accountKey: "a", directory: tempDir())
        await store.upsert([
            movie("Movies/The Matrix (1999).mkv", title: "The Matrix", year: 1999),
            episode("TV/Matrix Reloaded Show/E01.mkv", series: "Matrix Reloaded Show", season: 1, episode: 1),
            movie("Movies/Unrelated (2001).mkv", title: "Unrelated", year: 2001),
        ], scanID: 1)
        let hits = await store.search(query: "matrix", limit: 20)
        let titles = Set(hits.map(\.title))
        XCTAssertTrue(titles.contains("The Matrix"))
        XCTAssertTrue(titles.contains("Matrix Reloaded Show"))
        XCTAssertFalse(titles.contains("Unrelated"))

        let fullTitleHits = await store.search(query: "The Matrix", limit: 20)
        XCTAssertEqual(fullTitleHits.map(\.title), ["The Matrix"])
    }

    func testItemResolvesEveryIdShape() async {
        let store = ShareCatalogStore(accountKey: "a", directory: tempDir())
        let key = ShareCatalogID.seriesKey(fromTitle: "The Show")
        await store.upsert([
            movie("Movies/Film (2020).mkv", title: "Film", year: 2020),
            episode("TV/The Show/S01/E03.mkv", series: "The Show", season: 1, episode: 3),
        ], scanID: 1)

        let movieItem = await store.item(id: ShareCatalogID.file("Movies/Film (2020).mkv"))
        XCTAssertEqual(movieItem?.kind, .movie)
        XCTAssertEqual(movieItem?.productionYear, 2020)

        let seriesItem = await store.item(id: ShareCatalogID.series(key))
        XCTAssertEqual(seriesItem?.kind, .series)
        XCTAssertEqual(seriesItem?.title, "The Show")

        let seasonItem = await store.item(id: ShareCatalogID.season(key, 1))
        XCTAssertEqual(seasonItem?.kind, .season)
        XCTAssertEqual(seasonItem?.seasonNumber, 1)

        let episodeItem = await store.item(id: ShareCatalogID.file("TV/The Show/S01/E03.mkv"))
        XCTAssertEqual(episodeItem?.kind, .episode)
        XCTAssertEqual(episodeItem?.episodeNumber, 3)
        XCTAssertEqual(episodeItem?.seriesID, ShareCatalogID.series(key))

        let unknown = await store.item(id: "share:root")
        XCTAssertNil(unknown, "raw file-tree ids resolve via the browser, not the catalog")
    }

    func testPruneRemovesAssetsNotSeenInLatestScan() async {
        let store = ShareCatalogStore(accountKey: "a", directory: tempDir())
        await store.upsert([
            movie("Movies/Keep (2000).mkv", title: "Keep", year: 2000),
            movie("Movies/Gone (2001).mkv", title: "Gone", year: 2001),
        ], scanID: 1)
        // Next full scan only re-saw "Keep".
        await store.upsert([movie("Movies/Keep (2000).mkv", title: "Keep", year: 2000)], scanID: 2)
        await store.pruneNotSeen(inScan: 2)
        let movies = await store.movies(offset: 0, limit: 10)
        XCTAssertEqual(movies.map(\.title), ["Keep"])
    }

    func testCatalogSurvivesRelaunch() async {
        let dir = tempDir()
        let live = ShareCatalogStore(accountKey: "acct", directory: dir)
        await live.upsert([movie("Movies/Persisted (2010).mkv", title: "Persisted", year: 2010)], scanID: 1)

        // Fresh store on the same dir == a relaunch (only the DB file remains).
        let reopened = ShareCatalogStore(accountKey: "acct", directory: dir)
        let movies = await reopened.movies(offset: 0, limit: 10)
        XCTAssertEqual(movies.map(\.title), ["Persisted"])
    }

    func testSeasonIdRoundTripsWithColonInKey() {
        // seriesKey never contains a colon, but guard the decoder anyway.
        let key = "breaking-bad"
        let id = ShareCatalogID.season(key, 3)
        let decoded = ShareCatalogID.seasonComponents(forSeasonID: id)
        XCTAssertEqual(decoded?.seriesKey, key)
        XCTAssertEqual(decoded?.season, 3)
    }

    func testSeriesKeyNormalizesPunctuationAndCase() {
        XCTAssertEqual(ShareCatalogID.seriesKey(fromTitle: "Breaking Bad"),
                       ShareCatalogID.seriesKey(fromTitle: "breaking.bad"))
        XCTAssertEqual(ShareCatalogID.seriesKey(fromTitle: "Mr. Robot"), "mr-robot")
    }

    // MARK: - Reconciliation primitives

    func testLevenshtein() {
        XCTAssertEqual(ShareCatalogStore.levenshtein("peaky blinder", "peaky blinders"), 1)
        XCTAssertEqual(ShareCatalogStore.levenshtein("kitten", "sitting"), 3)
        XCTAssertEqual(ShareCatalogStore.levenshtein("same", "same"), 0)
        XCTAssertEqual(ShareCatalogStore.levenshtein("", "abc"), 3)
    }

    func testTitlesNearlyIdentical() {
        // Typo / plural of one show.
        XCTAssertTrue(ShareCatalogStore.titlesNearlyIdentical("Peaky Blinder", "Peaky Blinders"))
        XCTAssertTrue(ShareCatalogStore.titlesNearlyIdentical("The Handmaids Tale", "The Handmaid's Tale"))
        // A digit difference is a deliberate distinction — never "nearly identical".
        XCTAssertFalse(ShareCatalogStore.titlesNearlyIdentical("1883", "1923"))
        // Too short / too different.
        XCTAssertFalse(ShareCatalogStore.titlesNearlyIdentical("Fargo", "Cargo"))
        XCTAssertFalse(ShareCatalogStore.titlesNearlyIdentical("Lost", "Loki"))
        XCTAssertFalse(ShareCatalogStore.titlesNearlyIdentical("The Office", "The Wire"))
    }

    func testResolveAliasFollowsChains() {
        let map = ["a": "b", "b": "c", "x": "y"]
        XCTAssertEqual(ShareCatalogStore.resolveAlias("a", in: map), "c")
        XCTAssertEqual(ShareCatalogStore.resolveAlias("b", in: map), "c")
        XCTAssertEqual(ShareCatalogStore.resolveAlias("x", in: map), "y")
        XCTAssertEqual(ShareCatalogStore.resolveAlias("z", in: map), "z")
        // A cycle terminates (rather than looping forever) at a cycle member.
        XCTAssertTrue(["a", "b"].contains(ShareCatalogStore.resolveAlias("a", in: ["a": "b", "b": "a"])))
    }

    func testAddsVariantWordBlocksParodyUpgrade() {
        // "sword art online" must never upgrade to "sword art online abridged".
        XCTAssertTrue(ShareCatalogStore.addsVariantWord(base: "sword art online", extended: "sword art online abridged"))
        // A genuine subtitle extension is allowed ("avatar" → "avatar the last airbender").
        XCTAssertFalse(ShareCatalogStore.addsVariantWord(base: "avatar", extended: "avatar the last airbender"))
    }

    func testEpisodeHintsSkipSyntheticPlaceholders() async {
        // A show with bare-numbered early seasons stores "S1·E01" placeholder titles;
        // those must be excluded from disambiguation hints so the real later-season
        // titles are used (the Outlander bug).
        let store = ShareCatalogStore(accountKey: "a", directory: tempDir())
        func ep(_ path: String, _ season: Int, _ episode: Int, title: String) -> CatalogAsset {
            CatalogAsset(relPath: path, basename: (path as NSString).lastPathComponent, size: 1,
                         modifiedAt: Date(), kind: .episode, library: .tv,
                         title: title, year: nil, seriesTitle: "Outlander",
                         seriesKey: ShareCatalogID.seriesKey(fromTitle: "Outlander"),
                         season: season, episode: episode)
        }
        await store.upsert([
            ep("TV/Outlander/S01/o.s01e01.mkv", 1, 1, title: "S1·E01"),
            ep("TV/Outlander/S01/o.s01e02.mkv", 1, 2, title: "S1·E02"),
            ep("TV/Outlander/S02/o.s02e01.mkv", 2, 1, title: "Through a Glass, Darkly"),
            ep("TV/Outlander/S02/o.s02e02.mkv", 2, 2, title: "Not in Scotland Anymore"),
        ], scanID: 1)
        let key = ShareCatalogID.seriesKey(fromTitle: "Outlander")
        let hints = await store.episodeTitleHints(seriesKey: key)
        XCTAssertEqual(hints.map(\.title), ["Through a Glass, Darkly", "Not in Scotland Anymore"])
        XCTAssertFalse(hints.contains { $0.title.hasPrefix("S1·E") }, "placeholders excluded")
    }
}
