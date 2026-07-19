#if canImport(SwiftUI)
import CoreModels
@testable import FeatureSettings
import XCTest

/// Locks the pure provider-list logic behind the metadata Settings page: the single
/// ordered list split by the "Disabled" divider (enabled above, disabled below),
/// derived from the sparse override + build baseline, plus clamped reordering and
/// cross-divider enable/disable.
final class MetadataProviderListLogicTests: XCTestCase {
    private let baseline: [MetadataSource] = [.tvdb, .tmdb, .anilist, .tvmaze]

    private func sections(
        _ settings: MetadataProviderSettings,
        baselineDisabled: Set<MetadataSource> = []
    ) -> MetadataProviderListLogic.Sections {
        MetadataProviderListLogic.sections(
            settings: settings,
            baselineOrder: baseline,
            baselineDisabled: baselineDisabled
        )
    }

    func testDefaultShowsAllEnabledInBaselineOrder() {
        let s = sections(.default)
        XCTAssertEqual(s.enabled, baseline)
        XCTAssertTrue(s.disabled.isEmpty)
    }

    func testUserOrderLeadsAndBaselineFillsTheRest() {
        let s = sections(MetadataProviderSettings(enabledOrder: ["anilist", "tvdb"]))
        XCTAssertEqual(s.enabled, [.anilist, .tvdb, .tmdb, .tvmaze])
        XCTAssertTrue(s.disabled.isEmpty)
    }

    func testDisabledSourcesGoBelowTheDivider() {
        let s = sections(MetadataProviderSettings(disabledOrder: ["tmdb"]))
        XCTAssertEqual(s.enabled, [.tvdb, .anilist, .tvmaze])
        XCTAssertEqual(s.disabled, [.tmdb])
    }

    func testBaselineDisabledShownDisabledUnlessUserEnables() {
        let s = sections(.default, baselineDisabled: [.tvmaze])
        XCTAssertEqual(s.enabled, [.tvdb, .tmdb, .anilist])
        XCTAssertEqual(s.disabled, [.tvmaze])

        let reEnabled = sections(
            MetadataProviderSettings(enabledOrder: ["tvmaze"]),
            baselineDisabled: [.tvmaze]
        )
        XCTAssertTrue(reEnabled.enabled.contains(.tvmaze))
        XCTAssertTrue(reEnabled.disabled.isEmpty)
    }

    func testSectionsIgnoreForeignTokens() {
        let s = sections(MetadataProviderSettings(enabledOrder: ["tvmaze", "ghostsource", "tmdb"]))
        XCTAssertEqual(s.enabled, [.tvmaze, .tmdb, .tvdb, .anilist])
        XCTAssertFalse(s.enabled.contains(MetadataSource(rawValue: "ghostsource")))
    }

    // MARK: Reordering + cross-divider

    func testMovedSwapsWithinBounds() {
        let moved = MetadataProviderListLogic.moved(.anilist, by: -1, in: baseline)
        XCTAssertEqual(moved, [.tvdb, .anilist, .tmdb, .tvmaze])
    }

    func testMovedIsNoOpAtEdges() {
        XCTAssertEqual(MetadataProviderListLogic.moved(.tvdb, by: -1, in: baseline), baseline)
        XCTAssertEqual(MetadataProviderListLogic.moved(.tvmaze, by: 1, in: baseline), baseline)
        XCTAssertEqual(MetadataProviderListLogic.moved(.omdb, by: 1, in: baseline), baseline) // absent
    }

    func testDisablingMovesToTopOfDisabled() {
        let start = MetadataProviderListLogic.Sections(enabled: [.tvdb, .tmdb, .anilist], disabled: [.omdb])
        let next = MetadataProviderListLogic.disabling(.tmdb, in: start)
        XCTAssertEqual(next.enabled, [.tvdb, .anilist])
        XCTAssertEqual(next.disabled, [.tmdb, .omdb])
    }

    func testEnablingMovesToBottomOfEnabled() {
        let start = MetadataProviderListLogic.Sections(enabled: [.tvdb, .tmdb], disabled: [.omdb, .anilist])
        let next = MetadataProviderListLogic.enabling(.anilist, in: start)
        XCTAssertEqual(next.enabled, [.tvdb, .tmdb, .anilist])
        XCTAssertEqual(next.disabled, [.omdb])
    }
}
#endif
