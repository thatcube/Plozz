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

@MainActor
final class HeroDirectionalRepeatControllerTests: XCTestCase {
    func testEdgeHoldWaitsFiveSecondsBeforeRapidPaging() async {
        let repeated = expectation(description: "edge repeat")
        var sleeps: [TimeInterval] = []
        let controller = HeroDirectionalRepeatController(sleep: {
            sleeps.append($0)
        })
        controller.onRepeat = { direction in
            XCTAssertEqual(direction, .right)
            controller.ended(.right)
            repeated.fulfill()
            return .advance(toItem: 2, keepButton: 2)
        }

        controller.began(.right, initialOutcome: .advance(toItem: 1, keepButton: 2))

        await fulfillment(of: [repeated], timeout: 1)
        XCTAssertEqual(sleeps, [5.0])
    }

    func testInteriorHoldTraversesButtonsThenPausesAtFirstPage() async {
        let repeated = expectation(description: "interior and page repeats")
        repeated.expectedFulfillmentCount = 3
        var sleeps: [TimeInterval] = []
        var outcomes: [HeroFocusOutcome] = [
            .moveButton(2),
            .advance(toItem: 1, keepButton: 2),
            .advance(toItem: 2, keepButton: 2)
        ]
        let controller = HeroDirectionalRepeatController(sleep: {
            sleeps.append($0)
        })
        controller.onRepeat = { direction in
            XCTAssertEqual(direction, .right)
            let outcome = outcomes.removeFirst()
            repeated.fulfill()
            if outcomes.isEmpty {
                controller.ended(.right)
            }
            return outcome
        }

        controller.began(.right, initialOutcome: .moveButton(1))

        await fulfillment(of: [repeated], timeout: 1)
        XCTAssertEqual(sleeps, [0.35, 0.12, 5.0])
    }

    func testLeftHoldUsesTheSameRepeatPath() async {
        let repeated = expectation(description: "left repeat")
        let controller = HeroDirectionalRepeatController(sleep: { _ in })
        controller.onRepeat = { direction in
            XCTAssertEqual(direction, .left)
            controller.ended(.left)
            repeated.fulfill()
            return .advance(toItem: 0, keepButton: 0)
        }

        controller.began(.left, initialOutcome: .advance(toItem: 1, keepButton: 0))

        await fulfillment(of: [repeated], timeout: 1)
    }

    func testEscapeAndBlockedMovesDoNotStartRepeating() {
        let controller = HeroDirectionalRepeatController()
        var repeatCount = 0
        controller.onRepeat = { _ in
            repeatCount += 1
            return .blocked
        }

        controller.began(.left, initialOutcome: .escape)
        controller.began(.right, initialOutcome: .blocked)

        XCTAssertEqual(repeatCount, 0)
    }
}
