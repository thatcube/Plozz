import XCTest
import CoreModels
@testable import MetadataKit

// MARK: - Fakes

private struct FakeScheduleTVmaze: TVmazeEnriching {
    var resolved: TVmazeResolved?
    var next: TVmazeNextEpisode?
    func resolve(_ query: MetadataQuery, wantEpisodeStill: Bool, wantOverview: Bool) async -> TVmazeResolved? { resolved }
    func nextEpisode(_ query: MetadataQuery) async -> TVmazeNextEpisode? { next }
}

private struct FakeScheduleTVDB: TVDBEnriching {
    var byID: TVDBMetadata?
    var next: ProviderNextEpisode?
    let calls = ScheduleCallLog()
    func resolve(byTVDBID id: String, isMovie: Bool) async -> TVDBMetadata? { calls.record("byID:\(id)"); return byID }
    func resolve(titles: [String], year: Int?, isMovie: Bool, episodeHints: [SeriesEpisodeHint]) async -> TVDBMetadata? {
        calls.record("byTitle"); return nil
    }
    func backdropURL(title: String, year: Int?, isMovie: Bool, tvdbID: String?) async -> URL? { nil }
    func nextAired(byTVDBID id: String) async -> ProviderNextEpisode? { calls.record("nextAired:\(id)"); return next }
}

private struct FakeScheduleAniList: AniListEnriching {
    var media: AniListArtworkProvider.Media?
    func fetchMedia(for query: MetadataQuery) async -> AniListArtworkProvider.Media? { media }
}

private final class ScheduleCallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    func record(_ s: String) { lock.lock(); entries.append(s); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return entries }
}

private final class SpyScheduleProvider: MetadataEnrichmentProvider, @unchecked Sendable {
    let id: MetadataSource = .tvmaze
    let capabilities: Set<MetadataCapability> = [.nextAiringEpisode]
    let policy = ProviderPolicy()
    private let lock = NSLock()
    private var _calls = 0
    var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
    var upcoming: UpcomingEpisode?
    init(upcoming: UpcomingEpisode?) { self.upcoming = upcoming }
    func enrich(_ query: MetadataQuery, missing: Set<MetadataField>) async -> MetadataEnrichment {
        lock.lock(); _calls += 1; lock.unlock()
        var out = MetadataEnrichment()
        if missing.contains(.nextAiringEpisode) { out.upcomingEpisode = upcoming }
        return out
    }
}

final class SeriesScheduleTests: XCTestCase {
    private func seriesQuery(_ type: ContentType, ids: [String: String] = [:]) -> MetadataQuery {
        MetadataQuery(
            contentType: type, kind: .series, title: "Show", alternateTitle: nil, year: 2020,
            seasonNumber: nil, episodeNumber: nil, animeIDs: AnimeIDs(), providerIDs: ids
        )
    }

    private func tempStore() -> SeriesScheduleStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return SeriesScheduleStore(directory: dir)
    }

    // MARK: Provider mapping

    func testTVmazeMapsExactTimestampSchedule() async {
        let next = TVmazeNextEpisode(showID: 42, next: ProviderNextEpisode(
            seasonNumber: 2, episodeNumber: 5, title: "Chapter 5",
            airDate: ScheduleDateParsing.instant("2030-01-02T20:00:00+00:00")!,
            datePrecision: .dateAndTime
        ))
        let provider = TVmazeEnrichmentProvider(client: FakeScheduleTVmaze(next: next))
        let out = await provider.enrich(seriesQuery(.tvShow), missing: [.nextAiringEpisode])
        let up = out.upcomingEpisode
        XCTAssertEqual(up?.seasonNumber, 2)
        XCTAssertEqual(up?.episodeNumber, 5)
        XCTAssertNil(up?.absoluteEpisodeNumber, "Western TV must not fabricate an absolute number")
        XCTAssertEqual(up?.title, "Chapter 5")
        XCTAssertEqual(up?.datePrecision, .dateAndTime)
        XCTAssertEqual(up?.source, .tvmaze)
        XCTAssertEqual(up?.seriesIdentity, .external(source: "tvmaze", value: "42"))
    }

    func testTVmazeScheduleOnlyRequestSkipsShowResolve() async {
        // A resolved payload with ids is available, but a schedule-only request must
        // not consult it (no extra network) — so no externalIDs appear.
        let fake = FakeScheduleTVmaze(
            resolved: TVmazeResolved(showID: 42, imdbID: "tt42", tvdbID: "4242"),
            next: TVmazeNextEpisode(showID: 42, next: ProviderNextEpisode(
                seasonNumber: 1, episodeNumber: 1,
                airDate: Date(timeIntervalSince1970: 1_900_000_000), datePrecision: .dateAndTime))
        )
        let provider = TVmazeEnrichmentProvider(client: fake)
        let out = await provider.enrich(seriesQuery(.tvShow), missing: [.nextAiringEpisode])
        XCTAssertNotNil(out.upcomingEpisode)
        XCTAssertTrue(out.externalIDs.isEmpty, "Schedule-only request must skip the show resolve")
    }

    func testAniListMapsAbsoluteNumberedSchedule() async {
        let media = AniListArtworkProvider.Media(
            id: 21, idMal: nil, averageScore: nil, bannerImage: nil, coverImage: nil,
            nextAiringEpisode: .init(airingAt: 1_900_000_000, episode: 1075)
        )
        let provider = AniListEnrichmentProvider(client: FakeScheduleAniList(media: media))
        let out = await provider.enrich(seriesQuery(.anime), missing: [.nextAiringEpisode])
        let up = out.upcomingEpisode
        XCTAssertEqual(up?.absoluteEpisodeNumber, 1075)
        XCTAssertNil(up?.seasonNumber, "Anime must not fabricate a season/episode from an absolute number")
        XCTAssertNil(up?.episodeNumber)
        XCTAssertEqual(up?.datePrecision, .dateAndTime)
        XCTAssertEqual(up?.airDate, Date(timeIntervalSince1970: 1_900_000_000))
        XCTAssertEqual(up?.seriesIdentity, .external(source: "anilist", value: "21"))
        XCTAssertEqual(up?.source, .anilist)
    }

    func testTVDBMapsDateOnlyScheduleAndUsesKnownIDOnly() async {
        let next = ProviderNextEpisode(
            seasonNumber: 3, episodeNumber: 8, title: "Finale",
            airDate: ScheduleDateParsing.calendarDate("2030-05-01")!,
            datePrecision: .dateOnly
        )
        let fake = FakeScheduleTVDB(next: next)
        let provider = TVDBEnrichmentProvider(client: fake)
        let out = await provider.enrich(seriesQuery(.tvShow, ids: ["Tvdb": "555"]), missing: [.nextAiringEpisode])
        let up = out.upcomingEpisode
        XCTAssertEqual(up?.datePrecision, .dateOnly)
        XCTAssertEqual(up?.seasonNumber, 3)
        XCTAssertEqual(up?.episodeNumber, 8)
        XCTAssertEqual(up?.seriesIdentity, .external(source: "tvdb", value: "555"))
        XCTAssertEqual(fake.calls.all, ["nextAired:555"], "Schedule-only must use nextAired by id, never a resolve")
    }

    func testTVDBScheduleInertWithoutKnownID() async {
        let fake = FakeScheduleTVDB(next: ProviderNextEpisode(
            airDate: Date(), datePrecision: .dateOnly))
        let provider = TVDBEnrichmentProvider(client: fake)
        let out = await provider.enrich(seriesQuery(.tvShow), missing: [.nextAiringEpisode])
        XCTAssertNil(out.upcomingEpisode, "No TVDB id -> no cheap schedule lookup")
        XCTAssertTrue(fake.calls.all.isEmpty, "Schedule-only must not title-search TheTVDB")
    }

    // MARK: TTL policy

    func testTTLPositiveCapsAtSixHoursOrShortlyAfterAir() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        // Air far in the future -> capped at +6h.
        let far = UpcomingEpisode(
            seriesIdentity: .external(source: "tvmaze", value: "1"),
            airDate: now.addingTimeInterval(10 * 24 * 3600),
            datePrecision: .dateAndTime, source: .tvmaze, refreshedAt: now)
        XCTAssertEqual(
            SeriesScheduleTTLPolicy.refreshDue(upcomingEpisode: far, seriesEnded: false, refreshedAt: now),
            now.addingTimeInterval(6 * 3600))
        // Air already passed -> due 6h after that air time (sooner than the +6h cap).
        let aired = UpcomingEpisode(
            seriesIdentity: .external(source: "tvmaze", value: "1"),
            airDate: now.addingTimeInterval(-3600),
            datePrecision: .dateAndTime, source: .tvmaze, refreshedAt: now)
        XCTAssertEqual(
            SeriesScheduleTTLPolicy.refreshDue(upcomingEpisode: aired, seriesEnded: false, refreshedAt: now),
            now.addingTimeInterval(-3600 + 6 * 3600))
    }

    func testTTLNegativeUsesContinuingVsEnded() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(
            SeriesScheduleTTLPolicy.refreshDue(upcomingEpisode: nil, seriesEnded: false, refreshedAt: now),
            now.addingTimeInterval(3 * 24 * 3600))
        XCTAssertEqual(
            SeriesScheduleTTLPolicy.refreshDue(upcomingEpisode: nil, seriesEnded: true, refreshedAt: now),
            now.addingTimeInterval(30 * 24 * 3600))
    }

    // MARK: Store

    func testStoreRoundTripsRegardlessOfFreshness() async {
        let store = tempStore()
        let stale = SeriesScheduleRecord(
            seriesKey: "k1", upcomingEpisode: nil, refreshedAt: .distantPast, refreshDueAt: .distantPast)
        await store.store(stale)
        let read = await store.record(for: "k1")
        XCTAssertNotNil(read, "Readers get the stored record even when a refresh is due")
        XCTAssertTrue(read!.isRefreshDue())
        let count = await store.allRecords().count
        XCTAssertEqual(count, 1)
        await store.clear()
        let afterClear = await store.record(for: "k1")
        XCTAssertNil(afterClear)
    }

    func testStorePersistsAcrossInstances() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let record = SeriesScheduleRecord(
            seriesKey: "persist", upcomingEpisode: nil, refreshedAt: Date(), refreshDueAt: Date().addingTimeInterval(3600))
        await SeriesScheduleStore(directory: dir).store(record)
        let reopened = await SeriesScheduleStore(directory: dir).record(for: "persist")
        XCTAssertEqual(reopened?.seriesKey, "persist")
    }

    // MARK: Resolver (cache-first via the real pipeline)

    func testResolverCachesAndSkipsNetworkWhenFresh() async {
        let store = tempStore()
        let upcoming = UpcomingEpisode(
            seriesIdentity: .external(source: "tvmaze", value: "42"),
            seasonNumber: 1, episodeNumber: 2,
            airDate: Date().addingTimeInterval(3 * 24 * 3600),
            datePrecision: .dateAndTime, source: .tvmaze, refreshedAt: Date())
        let spy = SpyScheduleProvider(upcoming: upcoming)
        let pipeline = MetadataEnrichmentPipeline(providers: [spy])
        let resolver = SeriesScheduleResolver(pipeline: pipeline, store: store)
        let query = seriesQuery(.tvShow, ids: ["Tvmaze": "42"])

        let first = await resolver.refresh(query, tier: .idleBacklog)
        XCTAssertEqual(first.upcomingEpisode?.episodeNumber, 2)
        XCTAssertEqual(spy.calls, 1)

        // A second refresh with a still-fresh record must not hit the pipeline again.
        _ = await resolver.refresh(query, tier: .idleBacklog)
        XCTAssertEqual(spy.calls, 1, "A fresh record short-circuits with zero network")

        // Cached read never touches the pipeline.
        let cached = await resolver.cachedRecord(for: query)
        XCTAssertEqual(cached?.upcomingEpisode?.episodeNumber, 2)
        XCTAssertEqual(spy.calls, 1)
    }

    func testResolverForceRefetchesEvenWhenFresh() async {
        let store = tempStore()
        let spy = SpyScheduleProvider(upcoming: nil)
        let pipeline = MetadataEnrichmentPipeline(providers: [spy])
        let resolver = SeriesScheduleResolver(pipeline: pipeline, store: store)
        let query = seriesQuery(.tvShow, ids: ["Tvmaze": "42"])
        _ = await resolver.refresh(query, tier: .idleBacklog)
        _ = await resolver.refresh(query, tier: .idleBacklog, force: true)
        XCTAssertEqual(spy.calls, 2)
    }
}
