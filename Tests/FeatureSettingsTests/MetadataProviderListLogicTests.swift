#if canImport(SwiftUI)
import CoreModels
@testable import FeatureSettings
import XCTest

/// Locks the pure provider-list logic behind the Step 6 metadata Settings page:
/// display order (user order leads, baseline fills), and clamped reordering.
final class MetadataProviderListLogicTests: XCTestCase {
    private let baseline: [MetadataSource] = [.tvdb, .tmdb, .anilist, .tvmaze]

    func testDisplayOrderFallsBackToBaselineWhenNoUserOrder() {
        let order = MetadataProviderListLogic.displayOrder(userOrder: [], baselineOrder: baseline)
        XCTAssertEqual(order, baseline)
    }

    func testUserOrderLeadsAndBaselineFillsTheRest() {
        let order = MetadataProviderListLogic.displayOrder(
            userOrder: ["anilist", "tvdb"], baselineOrder: baseline
        )
        // User-placed first (in user order), then omitted baseline sources in order.
        XCTAssertEqual(order, [.anilist, .tvdb, .tmdb, .tvmaze])
    }

    func testDisplayOrderDedupesAndDropsUnknownExtras() {
        let order = MetadataProviderListLogic.displayOrder(
            userOrder: ["tmdb", "tmdb"], baselineOrder: baseline
        )
        XCTAssertEqual(order, [.tmdb, .tvdb, .anilist, .tvmaze])
    }

    func testDisplayOrderIgnoresForeignTokens() {
        // A stale/foreign persisted token is filtered against the known baseline set,
        // so it never appears as a phantom row; real sources still order correctly.
        let order = MetadataProviderListLogic.displayOrder(
            userOrder: ["tvmaze", "ghostsource", "tmdb"], baselineOrder: baseline
        )
        XCTAssertEqual(order, [.tvmaze, .tmdb, .tvdb, .anilist])
        XCTAssertFalse(order.contains(MetadataSource(rawValue: "ghostsource")))
    }

    func testMovedSwapsWithinBounds() {
        let moved = MetadataProviderListLogic.moved(.anilist, by: -1, in: baseline)
        XCTAssertEqual(moved, [.tvdb, .anilist, .tmdb, .tvmaze])
    }

    func testMovedIsNoOpAtEdges() {
        XCTAssertEqual(MetadataProviderListLogic.moved(.tvdb, by: -1, in: baseline), baseline)
        XCTAssertEqual(MetadataProviderListLogic.moved(.tvmaze, by: 1, in: baseline), baseline)
        XCTAssertEqual(MetadataProviderListLogic.moved(.omdb, by: 1, in: baseline), baseline) // absent
    }
}
#endif
