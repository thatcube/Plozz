import XCTest
import CoreModels
@testable import MetadataKit

/// Locks the user-override merge (enabled + order) on top of the Info.plist baseline:
/// Recommended is a no-op, Custom uses its single global order and disabled set,
/// and stale/foreign tokens are
/// filtered without re-enabling a disabled provider.
final class MetadataEnrichmentConfigOverrideTests: XCTestCase {
    private func makeQuery(_ type: ContentType = .movie) -> MetadataQuery {
        MetadataQuery(
            contentType: type,
            kind: type == .movie ? .movie : .series,
            title: "X",
            alternateTitle: nil,
            year: nil,
            seasonNumber: nil,
            episodeNumber: nil,
            animeIDs: AnimeIDs(),
            providerIDs: [:]
        )
    }

    func testEmptyOverridesReturnIdenticalConfig() {
        let baseline = MetadataEnrichmentConfig(
            disabledSources: [.omdb],
            order: [.tvdb, .tmdb, .anilist]
        )
        let merged = baseline.merged(withUserOverrides: .default)
        XCTAssertEqual(merged.disabledSources, baseline.disabledSources)
        XCTAssertEqual(merged.order, baseline.order)
        XCTAssertFalse(merged.usesGlobalOrder)
    }

    func testRecommendedIgnoresSavedCustomLists() {
        let baseline = MetadataEnrichmentConfig(order: [.tvdb, .tmdb, .anilist])
        let overrides = MetadataProviderSettings(
            orderMode: .recommended,
            enabledOrder: ["anilist", "tvdb"],
            disabledOrder: ["tmdb"]
        )
        let merged = baseline.merged(withUserOverrides: overrides)
        XCTAssertEqual(merged.disabledSources, baseline.disabledSources)
        XCTAssertEqual(merged.order, baseline.order)
        XCTAssertFalse(merged.usesGlobalOrder)
    }

    func testArtworkPreferenceAppliesInRecommendedMode() {
        let baseline = MetadataEnrichmentConfig(order: [.tvdb, .tmdb])
        let overrides = MetadataProviderSettings(preferOnlineArtwork: true)
        let merged = baseline.merged(withUserOverrides: overrides)

        XCTAssertFalse(merged.usesGlobalOrder)
        XCTAssertTrue(merged.preferOnlineArtwork)
        XCTAssertEqual(
            Array(merged.precedenceSources(for: .posterURL, query: makeQuery()).prefix(2)),
            [.tmdb, .tvdb]
        )
    }

    func testArtworkPreferenceOffKeepsLocalAheadOfOnline() throws {
        let config = MetadataEnrichmentConfig(order: [.tvdb, .tmdb])
        let sources = config.precedenceSources(for: .posterURL, query: makeQuery())
        XCTAssertLessThan(
            try XCTUnwrap(sources.firstIndex(of: .localArtwork)),
            try XCTUnwrap(sources.firstIndex(of: .tmdb))
        )
    }

    func testArtworkPreferenceNeverChangesTextPrecedence() throws {
        let config = MetadataEnrichmentConfig(
            order: [.tvdb, .tmdb],
            preferOnlineArtwork: true
        )
        let sources = config.precedenceSources(for: .overview, query: makeQuery())
        XCTAssertLessThan(
            try XCTUnwrap(sources.firstIndex(of: .localNFO)),
            try XCTUnwrap(sources.firstIndex(of: .tvdb))
        )
    }

    func testArtworkPreferenceIsScopedToEveryArtworkField() {
        let artworkFields: [MetadataField] = [
            .posterURL, .backdropURL, .homeHero, .detailBackdrop, .logoURL,
            .episodeThumbnail, .seasonPoster, .banner,
        ]
        XCTAssertTrue(artworkFields.allSatisfy(MetadataEnrichmentConfig.isArtwork))
        XCTAssertFalse([
            .title, .overview, .genres, .taglines, .providerID("tmdb"),
        ].contains(where: MetadataEnrichmentConfig.isArtwork))
    }

    func testArtworkPreferenceAppliesInCustomMode() {
        let baseline = MetadataEnrichmentConfig(order: [.tvdb, .tmdb])
        let overrides = MetadataProviderSettings(
            orderMode: .custom,
            preferOnlineArtwork: true,
            enabledOrder: ["tmdb", "tvdb"]
        )
        let merged = baseline.merged(withUserOverrides: overrides)
        XCTAssertTrue(merged.usesGlobalOrder)
        XCTAssertTrue(merged.preferOnlineArtwork)
        XCTAssertEqual(
            Array(merged.precedenceSources(for: .posterURL, query: makeQuery()).prefix(2)),
            [.tmdb, .tvdb]
        )
    }

    func testCustomDisablingExcludesSourceAndUsesGlobalOrder() {
        let baseline = MetadataEnrichmentConfig(order: [.tvdb, .tmdb, .anilist])
        var overrides = MetadataProviderSettings(orderMode: .custom)
        overrides.setDisabledOrder([.tmdb])
        let merged = baseline.merged(withUserOverrides: overrides)

        XCTAssertTrue(merged.disabledSources.contains(.tmdb))       // disabled
        XCTAssertFalse(merged.isEnabled(.tmdb))
        XCTAssertTrue(merged.isEnabled(.anilist))                   // untouched
        XCTAssertTrue(merged.usesGlobalOrder)
        let sources = merged.orderedSources(for: .title, query: makeQuery())
        XCTAssertFalse(sources.contains(.tmdb), "disabled source dropped from every chain")
        XCTAssertEqual(sources, [.tvdb, .anilist])
    }

    func testReorderingEnabledSwitchesToGlobalOrder() {
        let baseline = MetadataEnrichmentConfig(order: [.tvdb, .tmdb, .anilist, .tvmaze])
        var overrides = MetadataProviderSettings(orderMode: .custom)
        overrides.setEnabledOrder([.anilist, .tvdb]) // user promotes two sources
        let merged = baseline.merged(withUserOverrides: overrides)

        // User order leads; omitted baseline sources keep their order, appended.
        XCTAssertEqual(merged.order, [.anilist, .tvdb, .tmdb, .tvmaze])
        XCTAssertTrue(merged.usesGlobalOrder)
        // The single global order now drives every field.
        XCTAssertEqual(merged.orderedSources(for: .title, query: makeQuery()).first, .anilist)
    }

    func testReenablingBuildDisabledSourceViaEnabledList() {
        let baseline = MetadataEnrichmentConfig(disabledSources: [.omdb], order: [.tvdb, .tmdb, .omdb])
        var overrides = MetadataProviderSettings(orderMode: .custom)
        overrides.setEnabledOrder([.tvdb, .tmdb, .omdb]) // user places omdb above the divider
        let merged = baseline.merged(withUserOverrides: overrides)
        XCTAssertTrue(merged.isEnabled(.omdb), "user can re-enable a build-disabled source")
        XCTAssertFalse(merged.disabledSources.contains(.omdb))
    }

    func testResetIsEmptyOverride() {
        let baseline = MetadataEnrichmentConfig(disabledSources: [.omdb])
        let reset = baseline.merged(withUserOverrides: .default)
        XCTAssertEqual(reset.disabledSources, baseline.disabledSources)
        XCTAssertEqual(reset.order, baseline.order)
    }

    func testOrderOverrideIgnoresUnknownTokens() {
        let baseline = MetadataEnrichmentConfig(order: [.tvdb, .tmdb, .anilist])
        // A persisted order carrying a stale/foreign token must not add a phantom source.
        let overrides = MetadataProviderSettings(
            orderMode: .custom,
            enabledOrder: ["anilist", "ghostsource", "tvdb"]
        )
        let merged = baseline.merged(withUserOverrides: overrides)
        XCTAssertEqual(merged.order, [.anilist, .tvdb, .tmdb])
        XCTAssertFalse(merged.order.contains(MetadataSource(rawValue: "ghostsource")))
    }

    func testUnknownDisabledTokenCannotEnableAnything() {
        let baseline = MetadataEnrichmentConfig(order: [.tvdb, .tmdb])
        // A foreign disabled token is simply dropped (no such source to disable) and
        // never flips any real source on.
        let overrides = MetadataProviderSettings(
            orderMode: .custom,
            disabledOrder: ["ghostsource"]
        )
        let merged = baseline.merged(withUserOverrides: overrides)
        XCTAssertTrue(merged.disabledSources.isEmpty)
        XCTAssertEqual(merged.order, [.tvdb, .tmdb])
    }

    func testOverrideAffectsOrderedSourcesOutput() {
        let baseline = MetadataEnrichmentConfig(order: [.tvdb, .tmdb])
        var overrides = MetadataProviderSettings(orderMode: .custom)
        overrides.setDisabledOrder([.tvdb])
        let merged = baseline.merged(withUserOverrides: overrides)
        let sources = merged.orderedSources(for: .title, query: makeQuery())
        XCTAssertFalse(sources.contains(.tvdb), "disabled source must be dropped from the chain")
    }
}
