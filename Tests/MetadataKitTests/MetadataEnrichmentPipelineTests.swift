import XCTest
import CoreModels
@testable import MetadataKit

/// A deterministic, call-recording ``MetadataEnrichmentProvider`` fake for exercising
/// the pipeline's routing/stop/merge logic without any network.
final class FakeEnrichmentProvider: MetadataEnrichmentProvider, @unchecked Sendable {
    let id: MetadataSource
    let capabilities: Set<MetadataCapability>
    let policy: ProviderPolicy
    private let output: MetadataEnrichment
    private let lock = NSLock()
    private var _calls: [(query: MetadataQuery, missing: Set<MetadataField>)] = []

    init(
        id: MetadataSource,
        capabilities: Set<MetadataCapability>,
        output: MetadataEnrichment,
        policy: ProviderPolicy = ProviderPolicy()
    ) {
        self.id = id
        self.capabilities = capabilities
        self.output = output
        self.policy = policy
    }

    func enrich(_ query: MetadataQuery, missing: Set<MetadataField>) async -> MetadataEnrichment {
        lock.lock()
        _calls.append((query, missing))
        lock.unlock()
        return output
    }

    var calls: [(query: MetadataQuery, missing: Set<MetadataField>)] {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }

    var callCount: Int { calls.count }
}

final class MetadataEnrichmentPipelineTests: XCTestCase {
    // MARK: Helpers

    private func makeQuery(
        type: ContentType = .movie,
        ids: [String: String] = [:]
    ) -> MetadataQuery {
        MetadataQuery(
            contentType: type,
            kind: .movie,
            title: "Test Title",
            alternateTitle: nil,
            year: 2020,
            seasonNumber: nil,
            episodeNumber: nil,
            animeIDs: AnimeIDs(),
            providerIDs: ids
        )
    }

    /// A config whose ordering is exactly `order` for every field (empty priority
    /// table ⇒ base order drives every field), so tests are fully deterministic.
    private func makeConfig(
        order: [MetadataSource],
        roles: [MetadataSource: ProviderRole] = [:]
    ) -> MetadataEnrichmentConfig {
        MetadataEnrichmentConfig(
            roles: roles,
            baseOrder: order,
            priority: MetadataPriorityPolicy(rules: [])
        )
    }

    private func sourced(_ text: String, _ source: MetadataSource) -> SourcedValue<String> {
        SourcedValue(value: text, source: source)
    }

    // MARK: Missing-field stop

    func testStopsOnceRequestedFieldsFilled() async {
        let a = FakeEnrichmentProvider(
            id: .tvdb,
            capabilities: [.canonicalText],
            output: MetadataEnrichment(overview: sourced("A overview", .tvdb))
        )
        let b = FakeEnrichmentProvider(
            id: .tmdb,
            capabilities: [.canonicalText],
            output: MetadataEnrichment(overview: sourced("B overview", .tmdb))
        )
        let pipeline = MetadataEnrichmentPipeline(
            providers: [a, b],
            config: makeConfig(order: [.tvdb, .tmdb])
        )

        let result = await pipeline.enrich(
            makeQuery(),
            requesting: [.overview],
            tier: .foregroundFill
        )

        XCTAssertEqual(result.overview?.value, "A overview")
        XCTAssertEqual(a.callCount, 1)
        XCTAssertEqual(b.callCount, 0, "The second provider must not run once overview is filled")
    }

    // MARK: Provenance / priority merge

    func testHigherPriorityProviderWins() async {
        let a = FakeEnrichmentProvider(
            id: .tvdb,
            capabilities: [.canonicalText],
            output: MetadataEnrichment(overview: sourced("canonical", .tvdb))
        )
        let b = FakeEnrichmentProvider(
            id: .tmdb,
            capabilities: [.canonicalText],
            output: MetadataEnrichment(overview: sourced("secondary", .tmdb))
        )
        let pipeline = MetadataEnrichmentPipeline(
            providers: [a, b],
            config: makeConfig(order: [.tvdb, .tmdb])
        )

        let result = await pipeline.enrich(
            makeQuery(),
            requesting: [.overview],
            tier: .foregroundFill
        )

        XCTAssertEqual(result.overview?.value, "canonical")
        XCTAssertEqual(result.overview?.source, .tvdb)
    }

    func testDisabledSourceIsSkipped() async {
        let a = FakeEnrichmentProvider(
            id: .tvdb,
            capabilities: [.canonicalText],
            output: MetadataEnrichment(overview: sourced("disabled winner", .tvdb))
        )
        let b = FakeEnrichmentProvider(
            id: .tmdb,
            capabilities: [.canonicalText],
            output: MetadataEnrichment(overview: sourced("enabled winner", .tmdb))
        )
        let pipeline = MetadataEnrichmentPipeline(
            providers: [a, b],
            config: makeConfig(order: [.tvdb, .tmdb], roles: [.tvdb: .disabled])
        )

        let result = await pipeline.enrich(
            makeQuery(),
            requesting: [.overview],
            tier: .foregroundFill
        )

        XCTAssertEqual(result.overview?.source, .tmdb)
        XCTAssertEqual(a.callCount, 0)
    }

    func testSecondaryRoleIsDemotedBelowPrimary() async {
        // tvdb listed first, but demoted to secondary — tmdb (primary) should win.
        let a = FakeEnrichmentProvider(
            id: .tvdb,
            capabilities: [.canonicalText],
            output: MetadataEnrichment(overview: sourced("secondary", .tvdb))
        )
        let b = FakeEnrichmentProvider(
            id: .tmdb,
            capabilities: [.canonicalText],
            output: MetadataEnrichment(overview: sourced("primary", .tmdb))
        )
        let pipeline = MetadataEnrichmentPipeline(
            providers: [a, b],
            config: makeConfig(order: [.tvdb, .tmdb], roles: [.tvdb: .secondary])
        )

        let result = await pipeline.enrich(
            makeQuery(),
            requesting: [.overview],
            tier: .foregroundFill
        )

        XCTAssertEqual(result.overview?.source, .tmdb)
    }

    // MARK: Backdrop candidate set (one response serves both screens)

    func testBackdropCandidateSetServesBothScreens() async {
        let u1 = URL(string: "https://art/1.jpg")!
        let u2 = URL(string: "https://art/2.jpg")!
        let u3 = URL(string: "https://art/3.jpg")!
        let provider = FakeEnrichmentProvider(
            id: .tmdb,
            capabilities: [.backdrop],
            output: MetadataEnrichment(backdropCandidates: [
                SourcedValue(value: u1, source: .tmdb),
                SourcedValue(value: u2, source: .tmdb),
                SourcedValue(value: u3, source: .tmdb),
            ])
        )
        let pipeline = MetadataEnrichmentPipeline(
            providers: [provider],
            config: makeConfig(order: [.tmdb])
        )

        let result = await pipeline.enrich(
            makeQuery(),
            requesting: [.homeHero, .detailBackdrop, .backdropURL],
            tier: .visiblePrefetch
        )

        XCTAssertEqual(result.homeHero?.value, u1)
        XCTAssertEqual(result.detailBackdrop?.value, u2, "Detail should use a distinct candidate")
        XCTAssertEqual(result.backdropCandidates.count, 3)
        XCTAssertEqual(
            provider.callCount, 1,
            "One response must satisfy hero + detail without a second search"
        )
    }

    func testSingleBackdropFallsBackForDetail() async {
        let only = URL(string: "https://art/only.jpg")!
        let provider = FakeEnrichmentProvider(
            id: .tmdb,
            capabilities: [.backdrop],
            output: MetadataEnrichment(backdropCandidates: [SourcedValue(value: only, source: .tmdb)])
        )
        let pipeline = MetadataEnrichmentPipeline(
            providers: [provider],
            config: makeConfig(order: [.tmdb])
        )

        let result = await pipeline.enrich(
            makeQuery(),
            requesting: [.homeHero, .detailBackdrop],
            tier: .visiblePrefetch
        )

        XCTAssertEqual(result.homeHero?.value, only)
        XCTAssertEqual(result.detailBackdrop?.value, only)
    }

    // MARK: ID threading (no duplicate work)

    func testResolvedIDsAreThreadedDownstream() async {
        let idProvider = FakeEnrichmentProvider(
            id: .tvmaze,
            capabilities: [.externalIDs],
            output: MetadataEnrichment(externalIDs: [
                "Imdb": SourcedValue(value: "tt0111161", source: .tvmaze),
                "Tvdb": SourcedValue(value: "12345", source: .tvmaze),
            ])
        )
        let posterProvider = FakeEnrichmentProvider(
            id: .tmdb,
            capabilities: [.poster],
            output: MetadataEnrichment(
                posterURL: SourcedValue(value: URL(string: "https://p/p.jpg")!, source: .tmdb)
            )
        )
        let pipeline = MetadataEnrichmentPipeline(
            providers: [idProvider, posterProvider],
            config: makeConfig(order: [.tvmaze, .tmdb])
        )

        let result = await pipeline.enrich(
            makeQuery(),
            requesting: [.providerID("Imdb"), .posterURL],
            tier: .foregroundFill
        )

        XCTAssertEqual(result.externalIDs["Imdb"]?.value, "tt0111161")
        XCTAssertNotNil(result.posterURL)
        // The poster provider ran after the id provider, so its query must carry the
        // ids the id provider resolved (an exact-id lookup, not a fresh title search).
        let posterQuery = posterProvider.calls.first?.query
        XCTAssertEqual(posterQuery?.providerIDs["Imdb"], "tt0111161")
        XCTAssertEqual(posterQuery?.providerIDs["Tvdb"], "12345")
    }

    // MARK: present-field skipping

    func testPresentFieldsAreNeitherRequestedNorOverwritten() async {
        let provider = FakeEnrichmentProvider(
            id: .tvdb,
            capabilities: [.canonicalText, .poster],
            output: MetadataEnrichment(
                overview: sourced("should be ignored", .tvdb),
                posterURL: SourcedValue(value: URL(string: "https://p/p.jpg")!, source: .tvdb)
            )
        )
        let pipeline = MetadataEnrichmentPipeline(
            providers: [provider],
            config: makeConfig(order: [.tvdb])
        )

        let result = await pipeline.enrich(
            makeQuery(),
            present: [.overview],
            requesting: [.overview, .posterURL],
            tier: .foregroundFill
        )

        XCTAssertNil(result.overview, "A present field must not be overwritten")
        XCTAssertNotNil(result.posterURL)
        XCTAssertEqual(
            provider.calls.first?.missing, [.posterURL],
            "The provider must only be asked for the still-missing field"
        )
    }

    // MARK: tier eligibility

    func testProviderSkippedWhenNotEligibleForTier() async {
        let backlogOnly = FakeEnrichmentProvider(
            id: .wikipedia,
            capabilities: [.canonicalText],
            output: MetadataEnrichment(overview: sourced("wiki", .wikipedia)),
            policy: ProviderPolicy(eligibleTiers: [.idleBacklog])
        )
        let pipeline = MetadataEnrichmentPipeline(
            providers: [backlogOnly],
            config: makeConfig(order: [.wikipedia])
        )

        let foreground = await pipeline.enrich(
            makeQuery(),
            requesting: [.overview],
            tier: .foregroundFill
        )
        XCTAssertNil(foreground.overview)
        XCTAssertEqual(backlogOnly.callCount, 0)

        let backlog = await pipeline.enrich(
            makeQuery(),
            requesting: [.overview],
            tier: .idleBacklog
        )
        XCTAssertEqual(backlog.overview?.value, "wiki")
    }
}
