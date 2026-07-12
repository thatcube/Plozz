import XCTest
import CoreModels
@testable import FeatureHome

/// Locks down `HeroCarouselFocus` — the exact carousel focus/paging model:
/// interior button moves, edge-advance keeping the button index, always-forward
/// wrap, backward-wrap only in Top-Bar nav, and Sidebar-escape at the first
/// item's left edge.
final class HeroCarouselFocusTests: XCTestCase {
    private func resolve(
        _ direction: HeroFocusDirection,
        itemIndex: Int,
        itemCount: Int = 3,
        focusedButton: Int,
        buttonCount: Int = 3,
        nav: NavigationStyle = .sidebar
    ) -> HeroFocusOutcome {
        HeroCarouselFocus.resolve(
            direction: direction,
            itemIndex: itemIndex,
            itemCount: itemCount,
            focusedButton: focusedButton,
            buttonCount: buttonCount,
            navigationStyle: nav
        )
    }

    // MARK: Interior moves

    func testRightMovesToNextButtonInterior() {
        XCTAssertEqual(resolve(.right, itemIndex: 0, focusedButton: 0), .moveButton(1))
        XCTAssertEqual(resolve(.right, itemIndex: 0, focusedButton: 1), .moveButton(2))
    }

    func testLeftMovesToPreviousButtonInterior() {
        XCTAssertEqual(resolve(.left, itemIndex: 1, focusedButton: 2), .moveButton(1))
        XCTAssertEqual(resolve(.left, itemIndex: 1, focusedButton: 1), .moveButton(0))
    }

    // MARK: Forward advance + wrap

    func testRightAtLastButtonAdvancesKeepingButton() {
        // 3 buttons (last = 2); right at button 2 advances to next item.
        XCTAssertEqual(resolve(.right, itemIndex: 0, focusedButton: 2), .advance(toItem: 1, keepButton: 2))
    }

    func testForwardWrapsFromLastItem() {
        XCTAssertEqual(resolve(.right, itemIndex: 2, itemCount: 3, focusedButton: 2), .advance(toItem: 0, keepButton: 2))
    }

    func testForwardWrapsEvenInSidebarNav() {
        // Forward wrap is unconditional (both nav styles).
        XCTAssertEqual(resolve(.right, itemIndex: 2, itemCount: 3, focusedButton: 2, nav: .sidebar), .advance(toItem: 0, keepButton: 2))
    }

    // MARK: Backward step + wrap rules

    func testLeftAtFirstButtonOfLaterItemGoesPrevious() {
        XCTAssertEqual(resolve(.left, itemIndex: 2, focusedButton: 0), .advance(toItem: 1, keepButton: 0))
    }

    func testLeftAtFirstItemFirstButtonEscapesInSidebar() {
        XCTAssertEqual(resolve(.left, itemIndex: 0, focusedButton: 0, nav: .sidebar), .escape)
    }

    func testLeftAtFirstItemFirstButtonWrapsBackwardInTopBar() {
        XCTAssertEqual(resolve(.left, itemIndex: 0, itemCount: 3, focusedButton: 0, nav: .tabBar), .advance(toItem: 2, keepButton: 0))
    }

    // MARK: Single-item / degenerate

    func testSingleItemRightAtLastButtonIsBlocked() {
        XCTAssertEqual(resolve(.right, itemIndex: 0, itemCount: 1, focusedButton: 2), .blocked)
    }

    func testSingleItemLeftAtFirstButtonTopBarIsBlocked() {
        XCTAssertEqual(resolve(.left, itemIndex: 0, itemCount: 1, focusedButton: 0, nav: .tabBar), .blocked)
    }

    func testSingleItemLeftAtFirstButtonSidebarEscapes() {
        XCTAssertEqual(resolve(.left, itemIndex: 0, itemCount: 1, focusedButton: 0, nav: .sidebar), .escape)
    }

    func testZeroButtonsIsBlocked() {
        XCTAssertEqual(resolve(.right, itemIndex: 0, focusedButton: 0, buttonCount: 0), .blocked)
    }

    func testZeroItemsIsBlocked() {
        XCTAssertEqual(resolve(.right, itemIndex: 0, itemCount: 0, focusedButton: 0), .blocked)
    }
}

final class HeroFocusRailTopologyTests: XCTestCase {
    func testForwardWraps() {
        XCTAssertEqual(HeroFocusRailTopology.nextIndex(currentIndex: 2, itemCount: 3), 0)
    }

    func testBackwardWrapsOnlyForTopBar() {
        XCTAssertEqual(
            HeroFocusRailTopology.previousIndex(
                currentIndex: 0,
                itemCount: 3,
                navigationStyle: .tabBar
            ),
            2
        )
        XCTAssertNil(
            HeroFocusRailTopology.previousIndex(
                currentIndex: 0,
                itemCount: 3,
                navigationStyle: .sidebar
            )
        )
    }

    func testInteriorNeighbors() {
        XCTAssertEqual(
            HeroFocusRailTopology.previousIndex(
                currentIndex: 1,
                itemCount: 3,
                navigationStyle: .sidebar
            ),
            0
        )
        XCTAssertEqual(HeroFocusRailTopology.nextIndex(currentIndex: 1, itemCount: 3), 2)
    }

    func testDegenerateTopologyHasNoNeighbors() {
        XCTAssertNil(
            HeroFocusRailTopology.previousIndex(
                currentIndex: 0,
                itemCount: 1,
                navigationStyle: .tabBar
            )
        )
        XCTAssertNil(HeroFocusRailTopology.nextIndex(currentIndex: 0, itemCount: 1))
    }
}

@MainActor
final class HeroTwoBankHoldControllerTests: XCTestCase {
    func testCommittedPageWaitsConfiguredDelayBeforeRapidPaging() async {
        let repeated = expectation(description: "edge repeat")
        repeated.expectedFulfillmentCount = 2
        var sleeps: [TimeInterval] = []
        var repeatCount = 0
        let controller = HeroTwoBankHoldController(sleep: { sleeps.append($0) })
        controller.onRapidPage = { direction in
            XCTAssertEqual(direction, .right)
            repeatCount += 1
            controller.didCommitPage(.right)
            if repeatCount == 2 {
                controller.ended(.right)
            }
            repeated.fulfill()
        }

        controller.began(.right)
        controller.didCommitPage(.right)

        await fulfillment(of: [repeated], timeout: 1)
        XCTAssertEqual(sleeps, [0.75, 0.12])
    }

    func testHoldingOntoAnEdgeRequestsInitialPageAfterRepeatOnset() async {
        let requested = expectation(description: "initial edge page")
        var sleeps: [TimeInterval] = []
        let controller = HeroTwoBankHoldController(sleep: { sleeps.append($0) })
        controller.onInitialEdgePage = { direction in
            XCTAssertEqual(direction, .right)
            controller.ended(.right)
            requested.fulfill()
        }

        controller.began(.right)
        controller.selectionChanged(
            selectedButton: 2,
            buttonCount: 3,
            canPageLeft: true,
            canPageRight: true
        )

        await fulfillment(of: [requested], timeout: 1)
        XCTAssertEqual(sleeps, [0.35])
    }

    func testLeftEdgeUsesTheSameContinuationPath() async {
        let requested = expectation(description: "left initial edge page")
        let controller = HeroTwoBankHoldController(sleep: { _ in })
        controller.onInitialEdgePage = { direction in
            XCTAssertEqual(direction, .left)
            controller.ended(.left)
            requested.fulfill()
        }

        controller.began(.left)
        controller.selectionChanged(
            selectedButton: 0,
            buttonCount: 3,
            canPageLeft: true,
            canPageRight: true
        )

        await fulfillment(of: [requested], timeout: 1)
    }

    func testNonPageableEdgeDoesNotRequestPage() {
        let controller = HeroTwoBankHoldController()
        var requestCount = 0
        controller.onInitialEdgePage = { _ in requestCount += 1 }

        controller.began(.left)
        controller.selectionChanged(
            selectedButton: 0,
            buttonCount: 3,
            canPageLeft: false,
            canPageRight: true
        )
        controller.ended(.left)

        XCTAssertEqual(requestCount, 0)
    }
}
