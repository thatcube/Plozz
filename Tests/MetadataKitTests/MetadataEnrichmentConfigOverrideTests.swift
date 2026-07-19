import XCTest
import CoreModels
@testable import MetadataKit

/// Locks the Step 6 user-override merge on top of the Step 5 Info.plist baseline:
/// empty overrides are a no-op (baseline preserved), role overrides replace exactly
/// their source, and an order override leads while omitted sources are appended.
final class MetadataEnrichmentConfigOverrideTests: XCTestCase {
    func testEmptyOverridesReturnIdenticalConfig() {
        let baseline = MetadataEnrichmentConfig(
            roles: [.tmdb: .secondary],
            baseOrder: [.tvdb, .tmdb, .anilist]
        )
        let merged = baseline.merged(withUserOverrides: .default)
        XCTAssertEqual(merged.roles, baseline.roles)
        XCTAssertEqual(merged.baseOrder, baseline.baseOrder)
    }

    func testRoleOverrideReplacesOnlyThatSource() {
        let baseline = MetadataEnrichmentConfig(
            roles: [.tmdb: .secondary, .anilist: .primary],
            baseOrder: [.tvdb, .tmdb, .anilist]
        )
        var overrides = MetadataProviderSettings()
        overrides.setRole(.disabled, for: .tmdb)
        let merged = baseline.merged(withUserOverrides: overrides)

        XCTAssertEqual(merged.role(of: .tmdb), .disabled)         // overridden
        XCTAssertEqual(merged.role(of: .anilist), .primary)       // baseline preserved
        XCTAssertFalse(merged.isEnabled(.tmdb))
        // Baseline order is untouched when only roles change.
        XCTAssertEqual(merged.baseOrder, baseline.baseOrder)
    }

    func testOrderOverrideLeadsAndPreservesOmittedBaselineSources() {
        let baseline = MetadataEnrichmentConfig(
            baseOrder: [.tvdb, .tmdb, .anilist, .tvmaze]
        )
        var overrides = MetadataProviderSettings()
        overrides.setOrder([.anilist, .tvdb]) // user reorders only two sources
        let merged = baseline.merged(withUserOverrides: overrides)

        // User order leads; omitted baseline sources keep original order, appended.
        XCTAssertEqual(merged.baseOrder, [.anilist, .tvdb, .tmdb, .tvmaze])
    }

    func testResetIsEmptyOverride() {
        let baseline = MetadataEnrichmentConfig(roles: [.omdb: .disabled])
        var overrides = MetadataProviderSettings()
        overrides.setRole(.primary, for: .omdb)
        overrides.setOrder([.tmdb])
        // "Reset to build defaults" == applying an empty override.
        let reset = baseline.merged(withUserOverrides: .default)
        XCTAssertEqual(reset.roles, baseline.roles)
        XCTAssertEqual(reset.baseOrder, baseline.baseOrder)
    }

    func testOverrideAffectsOrderedSourcesOutput() {
        let baseline = MetadataEnrichmentConfig(baseOrder: [.tvdb, .tmdb])
        var overrides = MetadataProviderSettings()
        overrides.setRole(.disabled, for: .tvdb)
        let merged = baseline.merged(withUserOverrides: overrides)
        let query = MetadataQuery(
            contentType: .movie,
            kind: .movie,
            title: "X",
            alternateTitle: nil,
            year: nil,
            seasonNumber: nil,
            episodeNumber: nil,
            animeIDs: AnimeIDs(),
            providerIDs: [:]
        )
        let sources = merged.orderedSources(for: .title, query: query)
        XCTAssertFalse(sources.contains(.tvdb), "disabled source must be dropped from the chain")
    }
}
