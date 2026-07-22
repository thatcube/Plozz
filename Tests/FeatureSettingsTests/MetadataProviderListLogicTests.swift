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

    func testRecommendedCustomRoundTripSeedsOnceAndPreservesCustomOrder() {
        let seeded = MetadataProviderListLogic.settings(
            .default,
            selecting: .custom,
            baselineOrder: baseline,
            baselineDisabled: [.tvmaze]
        )
        XCTAssertEqual(seeded.orderMode, .custom)
        XCTAssertEqual(seeded.enabledOrder, baseline.dropLast().map(\.rawValue))
        XCTAssertEqual(seeded.disabledOrder, [MetadataSource.tvmaze.rawValue])

        var reordered = seeded
        reordered.setLists(
            enabled: [.anilist, .tvdb, .tmdb],
            disabled: [.tvmaze]
        )
        let recommended = MetadataProviderListLogic.settings(
            reordered,
            selecting: .recommended,
            baselineOrder: baseline,
            baselineDisabled: [.tvmaze]
        )
        let restored = MetadataProviderListLogic.settings(
            recommended,
            selecting: .custom,
            baselineOrder: baseline,
            baselineDisabled: [.tvmaze]
        )

        XCTAssertEqual(recommended.orderMode, .recommended)
        XCTAssertEqual(restored.orderMode, .custom)
        XCTAssertEqual(restored.enabledOrder, reordered.enabledOrder)
        XCTAssertEqual(restored.disabledOrder, reordered.disabledOrder)
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

    // MARK: Lifted-row single-step move (continuous list across the divider)

    func testStepUpWithinEnabled() {
        let s = MetadataProviderListLogic.Sections(enabled: [.tvdb, .tmdb, .anilist], disabled: [])
        let next = MetadataProviderListLogic.stepped(.anilist, up: true, in: s)
        XCTAssertEqual(next.enabled, [.tvdb, .anilist, .tmdb])
    }

    func testStepDownWithinEnabled() {
        let s = MetadataProviderListLogic.Sections(enabled: [.tvdb, .tmdb, .anilist], disabled: [])
        let next = MetadataProviderListLogic.stepped(.tvdb, up: false, in: s)
        XCTAssertEqual(next.enabled, [.tmdb, .tvdb, .anilist])
    }

    func testStepUpAtTopIsNoOp() {
        let s = MetadataProviderListLogic.Sections(enabled: [.tvdb, .tmdb], disabled: [])
        XCTAssertEqual(MetadataProviderListLogic.stepped(.tvdb, up: true, in: s), s)
    }

    func testStepDownFromLastEnabledCrossesDividerToDisable() {
        let s = MetadataProviderListLogic.Sections(enabled: [.tvdb, .tmdb], disabled: [.omdb])
        let next = MetadataProviderListLogic.stepped(.tmdb, up: false, in: s)
        XCTAssertEqual(next.enabled, [.tvdb])
        XCTAssertEqual(next.disabled, [.tmdb, .omdb], "disabled at top of the disabled group")
    }

    func testStepUpFromFirstDisabledCrossesDividerToEnable() {
        let s = MetadataProviderListLogic.Sections(enabled: [.tvdb], disabled: [.tmdb, .omdb])
        let next = MetadataProviderListLogic.stepped(.tmdb, up: true, in: s)
        XCTAssertEqual(next.enabled, [.tvdb, .tmdb], "re-enabled at the bottom of enabled")
        XCTAssertEqual(next.disabled, [.omdb])
    }

    func testStepDownAtBottomIsNoOp() {
        let s = MetadataProviderListLogic.Sections(enabled: [.tvdb], disabled: [.tmdb, .omdb])
        XCTAssertEqual(MetadataProviderListLogic.stepped(.omdb, up: false, in: s), s)
    }

    func testStepWithinDisabled() {
        let s = MetadataProviderListLogic.Sections(enabled: [.tvdb], disabled: [.tmdb, .omdb, .anilist])
        XCTAssertEqual(
            MetadataProviderListLogic.stepped(.omdb, up: false, in: s).disabled,
            [.tmdb, .anilist, .omdb]
        )
        XCTAssertEqual(
            MetadataProviderListLogic.stepped(.omdb, up: true, in: s).disabled,
            [.omdb, .tmdb, .anilist]
        )
    }

    // MARK: Native iOS/iPadOS onMove

    func testNativeMoveReordersWithinEnabled() {
        let s = MetadataProviderListLogic.Sections(
            enabled: [.tvdb, .tmdb, .anilist],
            disabled: [.omdb]
        )
        let next = MetadataProviderListLogic.moving(
            fromOffsets: IndexSet(integer: 2),
            toOffset: 1,
            in: s
        )
        XCTAssertEqual(next.enabled, [.tvdb, .anilist, .tmdb])
        XCTAssertEqual(next.disabled, [.omdb])
    }

    func testNativeMoveAcrossDividerDisables() {
        let s = MetadataProviderListLogic.Sections(
            enabled: [.tvdb, .tmdb],
            disabled: [.omdb]
        )
        // Flattened: tvdb, tmdb, divider, omdb. Move tmdb after divider.
        let next = MetadataProviderListLogic.moving(
            fromOffsets: IndexSet(integer: 1),
            toOffset: 3,
            in: s
        )
        XCTAssertEqual(next.enabled, [.tvdb])
        XCTAssertEqual(next.disabled, [.tmdb, .omdb])
    }

    func testNativeMoveAcrossDividerEnables() {
        let s = MetadataProviderListLogic.Sections(
            enabled: [.tvdb],
            disabled: [.tmdb, .omdb]
        )
        // Flattened: tvdb, divider, tmdb, omdb. Move tmdb before divider.
        let next = MetadataProviderListLogic.moving(
            fromOffsets: IndexSet(integer: 2),
            toOffset: 1,
            in: s
        )
        XCTAssertEqual(next.enabled, [.tvdb, .tmdb])
        XCTAssertEqual(next.disabled, [.omdb])
    }

    func testNativeMoveCannotMoveDivider() {
        let s = MetadataProviderListLogic.Sections(
            enabled: [.tvdb],
            disabled: [.tmdb]
        )
        XCTAssertEqual(
            MetadataProviderListLogic.moving(
                fromOffsets: IndexSet(integer: 1),
                toOffset: 0,
                in: s
            ),
            s
        )
    }
}
#endif
