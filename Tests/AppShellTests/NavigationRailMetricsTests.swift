#if os(tvOS)
import XCTest
@testable import AppShell

final class NavigationRailMetricsTests: XCTestCase {
    func testExpandedPanelUsesUniformOuterMargins() {
        XCTAssertEqual(NavigationRailMetrics.expandedPanelOuterMargin, 32)
        XCTAssertEqual(NavigationRailMetrics.expandedPanelLayoutInset, 36)
        XCTAssertEqual(NavigationRailMetrics.expandedWidth, 426)
        XCTAssertEqual(NavigationRailMetrics.itemIconSize, 24)
        XCTAssertEqual(NavigationRailMetrics.expandedRowHeight, 64)
    }

    func testExpandedRowsRemainInsetFromPanelEdges() {
        let horizontalInset = NavigationRailMetrics.expandedContentHorizontalPadding
            - NavigationRailMetrics.expandedRowBackgroundOutset
            - NavigationRailMetrics.expandedPanelLayoutInset
        let safeAreaInset: CGFloat = 49
        let verticalInset = NavigationRailMetrics.expandedContentVerticalPadding(
            safeAreaInset: safeAreaInset
        )
            + NavigationRailMetrics.bumperHeight
            + NavigationRailMetrics.itemVerticalPadding
            - NavigationRailMetrics.expandedPanelVerticalPadding(
                safeAreaInset: safeAreaInset
            )

        XCTAssertEqual(horizontalInset, NavigationRailMetrics.expandedPanelContentInset)
        XCTAssertEqual(verticalInset, NavigationRailMetrics.expandedPanelContentInset)
    }

    func testCollapsedIconPositionOnlyChangesHorizontallyDuringExpansion() {
        XCTAssertEqual(NavigationRailMetrics.leadingInset, 28)
        XCTAssertGreaterThan(
            NavigationRailMetrics.expandedContentHorizontalPadding,
            NavigationRailMetrics.leadingInset
        )
        XCTAssertEqual(
            NavigationRailMetrics.expandedTrailingPadding
                - NavigationRailMetrics.expandedContentHorizontalOffset,
            NavigationRailMetrics.expandedContentHorizontalPadding
        )
        XCTAssertEqual(NavigationRailMetrics.expandedRowContentWidth, 296)
        XCTAssertEqual(
            NavigationRailMetrics.expandedLabelWidth
                + NavigationRailMetrics.expandedLabelOffset,
            NavigationRailMetrics.expandedRowContentWidth
        )
        XCTAssertEqual(NavigationRailMetrics.verticalPadding, 14)
    }
}
#endif
