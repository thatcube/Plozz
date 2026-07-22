import CoreModels
import Foundation
import MetadataKit
@testable import ProviderShare
import XCTest

/// A fake capability provider for driving `PipelineShareResolver` end-to-end without
/// network. Records the `missing` set it was asked for (to prove present-field
/// seeding) and can report a health for outage tests.
private final class FakePipelineProvider: MetadataEnrichmentProvider, @unchecked Sendable {
    let id: MetadataSource
    let capabilities: Set<MetadataCapability>
    let policy: ProviderPolicy
    private let output: MetadataEnrichment
    private let health: ProviderHealth
    private let lock = NSLock()
    private var _lastMissing: Set<MetadataField> = []
    private var _lastQuery: MetadataQuery?

    init(
        id: MetadataSource,
        capabilities: Set<MetadataCapability>,
        output: MetadataEnrichment,
        health: ProviderHealth = .ok
    ) {
        self.id = id
        self.capabilities = capabilities
        self.output = output
        self.health = health
        self.policy = ProviderPolicy()
    }

    func enrich(_ query: MetadataQuery, missing: Set<MetadataField>) async -> MetadataEnrichment {
        await enrichReporting(query, missing: missing).enrichment
    }

    func enrichReporting(_ query: MetadataQuery, missing: Set<MetadataField>) async -> ProviderResponse {
        lock.lock(); _lastMissing = missing; _lastQuery = query; lock.unlock()
        return ProviderResponse(enrichment: output, health: health)
    }

    var lastMissing: Set<MetadataField> { lock.lock(); defer { lock.unlock() }; return _lastMissing }
    var lastQuery: MetadataQuery? { lock.lock(); defer { lock.unlock() }; return _lastQuery }
}

final class PipelineShareResolverTests: XCTestCase {
    private func flatConfig(_ order: [MetadataSource]) -> MetadataEnrichmentConfig {
        MetadataEnrichmentConfig(order: order, priority: MetadataPriorityPolicy(rules: []))
    }

    private func request(
        title: String = "Fixture",
        isMovie: Bool = true,
        isAnime: Bool = false,
        knownProviderIDs: [String: String] = [:]
    ) -> ShareEnrichRequest {
        ShareEnrichRequest(
            itemID: "item-1", title: title, year: 2016, isMovie: isMovie,
            isAnime: isAnime, knownProviderIDs: knownProviderIDs
        )
    }

    func testBareMovieResolvesTheTVDBMetadataWithProvenance() async {
        let tvdb = FakePipelineProvider(
            id: .tvdb,
            capabilities: [.externalIDs, .canonicalText, .poster, .backdrop],
            output: MetadataEnrichment(
                externalIDs: [
                    "Tvdb": SourcedValue(value: "555", source: .tvdb),
                    "Imdb": SourcedValue(value: "tt9", source: .tvdb),
                ],
                overview: SourcedValue(value: "A movie.", source: .tvdb),
                genres: SourcedValue(value: ["Sci-Fi"], source: .tvdb),
                posterURL: SourcedValue(value: URL(string: "https://p/p.jpg")!, source: .tvdb),
                backdropCandidates: [SourcedValue(value: URL(string: "https://b/b.jpg")!, source: .tvdb)]
            )
        )
        let pipeline = MetadataEnrichmentPipeline(providers: [tvdb], config: flatConfig([.tvdb]))
        let resolver = PipelineShareResolver(pipeline: pipeline)

        let record = await resolver.resolve(request())

        XCTAssertEqual(record.providerIDs["Tvdb"], "555")
        XCTAssertEqual(record.providerIDs["Imdb"], "tt9")
        XCTAssertEqual(record.overview, "A movie.")
        XCTAssertEqual(record.genres, ["Sci-Fi"])
        XCTAssertEqual(record.posterURL, URL(string: "https://p/p.jpg"))
        XCTAssertEqual(record.backdropURL, URL(string: "https://b/b.jpg"))
        XCTAssertTrue(record.isUsable)
        // Provenance is preserved (Step 2/3): overview attributed to TheTVDB.
        XCTAssertEqual(record.provenance[.overview]?.source, .tvdb)
        XCTAssertEqual(record.provenance[.providerID("Tvdb")]?.source, .tvdb)
    }

    func testKnownIDsAreSeededAsPresentAndThreadedIntoTheQuery() async {
        let tvdb = FakePipelineProvider(
            id: .tvdb,
            capabilities: [.externalIDs, .canonicalText, .poster, .backdrop],
            output: MetadataEnrichment(overview: SourcedValue(value: "x", source: .tvdb))
        )
        let pipeline = MetadataEnrichmentPipeline(providers: [tvdb], config: flatConfig([.tvdb]))
        let resolver = PipelineShareResolver(pipeline: pipeline)

        _ = await resolver.resolve(request(knownProviderIDs: ["tvdb": "12345"]))

        // The already-known Tvdb id is not re-requested...
        XCTAssertFalse(tvdb.lastMissing.contains(.providerID("Tvdb")))
        // ...and it is present on the query for exact-id lookups.
        XCTAssertEqual(tvdb.lastQuery?.providerIDs.providerID(.tvdb), "12345")
    }

    func testAnimeGetsTheTVDBIdentityAndAniListArt() async {
        let tvdb = FakePipelineProvider(
            id: .tvdb,
            capabilities: [.externalIDs, .canonicalText],
            output: MetadataEnrichment(externalIDs: ["Tvdb": SourcedValue(value: "111", source: .tvdb)])
        )
        let anilist = FakePipelineProvider(
            id: .anilist,
            capabilities: [.externalIDs, .score, .poster, .backdrop],
            output: MetadataEnrichment(
                externalIDs: ["AniList": SourcedValue(value: "21", source: .anilist)],
                posterURL: SourcedValue(value: URL(string: "https://a/cover.jpg")!, source: .anilist),
                backdropCandidates: [SourcedValue(value: URL(string: "https://a/banner.jpg")!, source: .anilist)]
            )
        )
        // anilist ahead of tvdb for art; both contribute ids.
        let pipeline = MetadataEnrichmentPipeline(providers: [anilist, tvdb], config: flatConfig([.anilist, .tvdb]))
        let resolver = PipelineShareResolver(pipeline: pipeline)

        let record = await resolver.resolve(request(isMovie: false, isAnime: true))

        XCTAssertEqual(record.providerIDs["Tvdb"], "111")
        XCTAssertEqual(record.providerIDs["AniList"], "21")
        XCTAssertEqual(record.posterURL, URL(string: "https://a/cover.jpg"))
        XCTAssertEqual(record.provenance[.posterURL]?.source, .anilist)
    }

    func testTotalOutageDegradesToAnUnusableRecord() async {
        let downTVDB = ResilientEnrichmentProvider(
            base: FakePipelineProvider(
                id: .tvdb,
                capabilities: [.externalIDs, .canonicalText, .poster, .backdrop],
                output: MetadataEnrichment(),
                health: .failure(.transient)
            ),
            breaker: ProviderCircuitBreaker(),
            cache: ProviderResultCache()
        )
        let pipeline = MetadataEnrichmentPipeline(providers: [downTVDB], config: flatConfig([.tvdb]))
        let resolver = PipelineShareResolver(pipeline: pipeline)

        let record = await resolver.resolve(request())
        XCTAssertFalse(record.isUsable, "A total outage yields an unusable record (retried later), not a poisoned blank")
    }
}
