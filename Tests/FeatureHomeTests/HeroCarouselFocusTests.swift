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
final class HeroDirectionalPressGateTests: XCTestCase {
    func testIndirectTouchMovesRemainUnrestricted() {
        let gate = HeroDirectionalPressGate()

        XCTAssertTrue(gate.shouldAllowFocusUpdate(.right, outcome: .advance(toItem: 1, keepButton: 2)))
        XCTAssertTrue(gate.shouldAllowFocusUpdate(.right, outcome: .advance(toItem: 2, keepButton: 2)))
        XCTAssertTrue(gate.shouldAllowFocusUpdate(.left, outcome: .advance(toItem: 1, keepButton: 0)))
    }

    func testHeldPhysicalPressAllowsOnlyFirstPageBeforeDelay() {
        let gate = HeroDirectionalPressGate()

        gate.began(.right)

        XCTAssertTrue(gate.shouldAllowFocusUpdate(.right, outcome: .advance(toItem: 1, keepButton: 2)))
        gate.didCommitFocusUpdate(.right, outcome: .advance(toItem: 1, keepButton: 2))
        XCTAssertFalse(gate.shouldAllowFocusUpdate(.right, outcome: .advance(toItem: 2, keepButton: 2)))
        XCTAssertFalse(gate.shouldAllowFocusUpdate(.right, outcome: .advance(toItem: 0, keepButton: 2)))
    }

    func testRepeatedPreflightQueriesDoNotConsumeFirstPage() {
        let gate = HeroDirectionalPressGate()

        gate.began(.right)

        XCTAssertTrue(gate.shouldAllowFocusUpdate(.right, outcome: .advance(toItem: 1, keepButton: 2)))
        XCTAssertTrue(gate.shouldAllowFocusUpdate(.right, outcome: .advance(toItem: 1, keepButton: 2)))
        gate.didCommitFocusUpdate(.right, outcome: .advance(toItem: 1, keepButton: 2))
        XCTAssertFalse(gate.shouldAllowFocusUpdate(.right, outcome: .advance(toItem: 2, keepButton: 2)))
    }

    func testHeldPhysicalPressDoesNotThrottleInteriorButtons() {
        let gate = HeroDirectionalPressGate()

        gate.began(.right)

        XCTAssertTrue(gate.shouldAllowFocusUpdate(.right, outcome: .moveButton(1)))
        gate.didCommitFocusUpdate(.right, outcome: .moveButton(1))
        XCTAssertTrue(gate.shouldAllowFocusUpdate(.right, outcome: .moveButton(2)))
        gate.didCommitFocusUpdate(.right, outcome: .moveButton(2))
        XCTAssertTrue(gate.shouldAllowFocusUpdate(.right, outcome: .advance(toItem: 1, keepButton: 2)))
        gate.didCommitFocusUpdate(.right, outcome: .advance(toItem: 1, keepButton: 2))
        XCTAssertFalse(gate.shouldAllowFocusUpdate(.right, outcome: .advance(toItem: 2, keepButton: 2)))
    }

    func testBlockedEdgeNeverMovesFocus() {
        let gate = HeroDirectionalPressGate()

        XCTAssertFalse(gate.shouldAllowFocusUpdate(.right, outcome: .blocked))
        XCTAssertFalse(gate.shouldAllowFocusUpdate(.left, outcome: .blocked))
    }

    func testHeldPhysicalPressRepeatsAfterDeliberateDelay() {
        var now: TimeInterval = 100
        let gate = HeroDirectionalPressGate(now: { now })

        gate.began(.right)
        XCTAssertTrue(gate.shouldAllowFocusUpdate(.right, outcome: .advance(toItem: 1, keepButton: 2)))
        gate.didCommitFocusUpdate(.right, outcome: .advance(toItem: 1, keepButton: 2))

        now += 4.99
        XCTAssertFalse(gate.shouldAllowFocusUpdate(.right, outcome: .advance(toItem: 2, keepButton: 2)))

        now += 0.01
        XCTAssertTrue(gate.shouldAllowFocusUpdate(.right, outcome: .advance(toItem: 0, keepButton: 2)))

        now += 0.1
        XCTAssertTrue(gate.shouldAllowFocusUpdate(.right, outcome: .advance(toItem: 1, keepButton: 2)))
    }

    func testRepeatedBeginDoesNotRearmUntilRelease() {
        let gate = HeroDirectionalPressGate()

        gate.began(.right)
        XCTAssertTrue(gate.shouldAllowFocusUpdate(.right, outcome: .advance(toItem: 1, keepButton: 2)))
        gate.didCommitFocusUpdate(.right, outcome: .advance(toItem: 1, keepButton: 2))

        gate.began(.right)
        XCTAssertFalse(gate.shouldAllowFocusUpdate(.right, outcome: .advance(toItem: 2, keepButton: 2)))

        gate.ended(.right)
        gate.began(.right)
        XCTAssertTrue(gate.shouldAllowFocusUpdate(.right, outcome: .advance(toItem: 2, keepButton: 2)))
    }

    func testDirectionsAreTrackedIndependently() {
        let gate = HeroDirectionalPressGate()

        gate.began(.left)
        gate.began(.right)

        XCTAssertTrue(gate.shouldAllowFocusUpdate(.left, outcome: .advance(toItem: 0, keepButton: 0)))
        XCTAssertTrue(gate.shouldAllowFocusUpdate(.right, outcome: .advance(toItem: 2, keepButton: 2)))
        gate.didCommitFocusUpdate(.left, outcome: .advance(toItem: 0, keepButton: 0))
        gate.didCommitFocusUpdate(.right, outcome: .advance(toItem: 2, keepButton: 2))
        XCTAssertFalse(gate.shouldAllowFocusUpdate(.left, outcome: .advance(toItem: 2, keepButton: 0)))
        XCTAssertFalse(gate.shouldAllowFocusUpdate(.right, outcome: .advance(toItem: 0, keepButton: 2)))
    }
}
