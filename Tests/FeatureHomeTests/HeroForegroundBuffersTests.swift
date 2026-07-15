import XCTest
@testable import FeatureHome

/// Locks down `HeroForegroundBuffers` — the pure ring-buffer index math behind
/// the experimental double-buffered hero foreground
/// (`PLZHERO_BUFFERED_FOREGROUND`). The whole point of isolating this from the
/// SwiftUI view is that every paging/seed/refresh transition is exhaustively
/// testable here with zero UI.
final class HeroForegroundBuffersTests: XCTestCase {

    /// Convenience: the item indices held by physical slots 0, 1, 2.
    private func slots(_ b: HeroForegroundBuffers) -> [Int?] {
        (0..<HeroForegroundBuffers.slotCount).map { b.itemIndex(forSlot: $0) }
    }

    // MARK: Seeding

    func testSeedsPreviousCurrentNextAroundIndex() {
        let b = HeroForegroundBuffers(itemCount: 5, index: 2)
        XCTAssertEqual(b.currentItemIndex, 2)
        // current slot holds 2, next holds 3, previous holds 1.
        XCTAssertEqual(b.itemIndex(forSlot: b.currentSlot), 2)
        XCTAssertEqual(b.itemIndex(forSlot: b.nextSlot), 3)
        XCTAssertEqual(b.itemIndex(forSlot: b.previousSlot), 1)
    }

    func testSeedWrapsAtStart() {
        let b = HeroForegroundBuffers(itemCount: 5, index: 0)
        XCTAssertEqual(b.currentItemIndex, 0)
        XCTAssertEqual(b.itemIndex(forSlot: b.nextSlot), 1)
        // previous of 0 wraps to the last item.
        XCTAssertEqual(b.itemIndex(forSlot: b.previousSlot), 4)
    }

    func testSeedWrapsAtEnd() {
        let b = HeroForegroundBuffers(itemCount: 5, index: 4)
        XCTAssertEqual(b.currentItemIndex, 4)
        // next of the last item wraps to 0.
        XCTAssertEqual(b.itemIndex(forSlot: b.nextSlot), 0)
        XCTAssertEqual(b.itemIndex(forSlot: b.previousSlot), 3)
    }

    func testSeedClampsOutOfRangeIndex() {
        let b = HeroForegroundBuffers(itemCount: 5, index: 99)
        XCTAssertEqual(b.currentItemIndex, 4)
    }

    // MARK: slot(forItemIndex:)

    func testSlotForItemIndexFindsPreparedItems() {
        let b = HeroForegroundBuffers(itemCount: 5, index: 2)
        XCTAssertEqual(b.slot(forItemIndex: 2), b.currentSlot)
        XCTAssertEqual(b.slot(forItemIndex: 3), b.nextSlot)
        XCTAssertEqual(b.slot(forItemIndex: 1), b.previousSlot)
        // An item that isn't prepared in any slot.
        XCTAssertNil(b.slot(forItemIndex: 0))
    }

    // MARK: Adjacent paging (the hot path)

    func testForwardPageRotatesToPreparedSlot() {
        var b = HeroForegroundBuffers(itemCount: 5, index: 2)
        let expectedSlot = b.nextSlot          // where item 3 is already prepared
        let expectedItem = b.itemIndex(forSlot: expectedSlot)
        let before = slots(b)

        XCTAssertTrue(b.page(toIndex: 3, itemCount: 5))
        // Fronted the already-prepared destination slot...
        XCTAssertEqual(b.currentSlot, expectedSlot)
        XCTAssertEqual(b.currentItemIndex, expectedItem)
        XCTAssertEqual(b.currentItemIndex, 3)
        // ...WITHOUT changing any slot's content this frame (only the pointer moved).
        XCTAssertEqual(slots(b), before)
    }

    func testBackwardPageRotatesToPreparedSlot() {
        var b = HeroForegroundBuffers(itemCount: 5, index: 2)
        let expectedSlot = b.previousSlot
        let before = slots(b)

        XCTAssertTrue(b.page(toIndex: 1, itemCount: 5))
        XCTAssertEqual(b.currentSlot, expectedSlot)
        XCTAssertEqual(b.currentItemIndex, 1)
        XCTAssertEqual(slots(b), before)
    }

    func testForwardPageWrapAroundIsAdjacent() {
        var b = HeroForegroundBuffers(itemCount: 5, index: 4)
        // 4 -> 0 is a forward ±1 wrap; item 0 is prepared in nextSlot.
        XCTAssertTrue(b.page(toIndex: 0, itemCount: 5))
        XCTAssertEqual(b.currentItemIndex, 0)
    }

    func testBackwardPageWrapAroundIsAdjacent() {
        var b = HeroForegroundBuffers(itemCount: 5, index: 0)
        // 0 -> 4 is a backward ±1 wrap; item 4 is prepared in previousSlot.
        XCTAssertTrue(b.page(toIndex: 4, itemCount: 5))
        XCTAssertEqual(b.currentItemIndex, 4)
    }

    func testNonAdjacentPageReturnsFalseAndMutatesNothing() {
        var b = HeroForegroundBuffers(itemCount: 6, index: 2)
        let before = slots(b)
        let currentSlotBefore = b.currentSlot

        XCTAssertFalse(b.page(toIndex: 5, itemCount: 6))
        XCTAssertEqual(b.currentSlot, currentSlotBefore)
        XCTAssertEqual(slots(b), before)
        XCTAssertEqual(b.currentItemIndex, 2)
    }

    func testPageToCurrentIndexReturnsFalse() {
        var b = HeroForegroundBuffers(itemCount: 5, index: 2)
        XCTAssertFalse(b.page(toIndex: 2, itemCount: 5))
        XCTAssertEqual(b.currentItemIndex, 2)
    }

    func testConsecutiveForwardPagesKeepWindowCorrectAfterRefresh() {
        var b = HeroForegroundBuffers(itemCount: 6, index: 0)
        // Page forward one step at a time, refreshing neighbours after each (as the
        // view does off the transition frame). The window must stay consistent.
        for target in 1...5 {
            XCTAssertTrue(b.page(toIndex: target, itemCount: 6), "step to \(target)")
            b.refreshNeighbors(itemCount: 6)
            XCTAssertEqual(b.currentItemIndex, target)
            XCTAssertEqual(b.itemIndex(forSlot: b.nextSlot),
                           (target + 1) % 6)
            XCTAssertEqual(b.itemIndex(forSlot: b.previousSlot),
                           (target + 5) % 6)
        }
    }

    // MARK: refreshNeighbors

    func testRefreshNeighborsIsIdempotent() {
        var b = HeroForegroundBuffers(itemCount: 5, index: 2)
        let before = slots(b)
        b.refreshNeighbors(itemCount: 5)
        XCTAssertEqual(slots(b), before)
        b.refreshNeighbors(itemCount: 5)
        XCTAssertEqual(slots(b), before)
    }

    func testRefreshNeighborsCorrectsNeighborsAfterPage() {
        var b = HeroForegroundBuffers(itemCount: 6, index: 2)
        XCTAssertTrue(b.page(toIndex: 3, itemCount: 6))
        // Before refresh, the far slot still holds stale offscreen content.
        b.refreshNeighbors(itemCount: 6)
        XCTAssertEqual(b.currentItemIndex, 3)
        XCTAssertEqual(b.itemIndex(forSlot: b.nextSlot), 4)
        XCTAssertEqual(b.itemIndex(forSlot: b.previousSlot), 2)
    }

    // MARK: Small carousels

    func testSingleItemCarouselMapsEverySlotToZero() {
        let b = HeroForegroundBuffers(itemCount: 1, index: 0)
        XCTAssertEqual(b.currentItemIndex, 0)
        XCTAssertEqual(b.itemIndex(forSlot: b.nextSlot), 0)
        XCTAssertEqual(b.itemIndex(forSlot: b.previousSlot), 0)
    }

    func testTwoItemCarouselPrevAndNextAreSameItem() {
        let b = HeroForegroundBuffers(itemCount: 2, index: 0)
        XCTAssertEqual(b.currentItemIndex, 0)
        // Both neighbours resolve to the other item (1) — prev==next==1.
        XCTAssertEqual(b.itemIndex(forSlot: b.nextSlot), 1)
        XCTAssertEqual(b.itemIndex(forSlot: b.previousSlot), 1)
    }

    func testTwoItemCarouselPageForwardAndBack() {
        var b = HeroForegroundBuffers(itemCount: 2, index: 0)
        XCTAssertTrue(b.page(toIndex: 1, itemCount: 2))
        XCTAssertEqual(b.currentItemIndex, 1)
        b.refreshNeighbors(itemCount: 2)
        XCTAssertTrue(b.page(toIndex: 0, itemCount: 2))
        XCTAssertEqual(b.currentItemIndex, 0)
    }

    // MARK: Empty carousel

    func testEmptyCarouselHasNoAssignments() {
        let b = HeroForegroundBuffers(itemCount: 0, index: 0)
        XCTAssertNil(b.currentItemIndex)
        XCTAssertNil(b.itemIndex(forSlot: 0))
        XCTAssertNil(b.itemIndex(forSlot: 1))
        XCTAssertNil(b.itemIndex(forSlot: 2))
    }

    func testPageOnEmptyCarouselReturnsFalse() {
        var b = HeroForegroundBuffers(itemCount: 0, index: 0)
        XCTAssertFalse(b.page(toIndex: 0, itemCount: 0))
    }

    func testReseedAllToEmptyClearsWindow() {
        var b = HeroForegroundBuffers(itemCount: 5, index: 2)
        b.reseedAll(itemCount: 0, index: 0)
        XCTAssertNil(b.currentItemIndex)
        XCTAssertEqual(b.currentSlot, 0)
    }

    // MARK: reseedAll (set-swap fallback)

    func testReseedAllRecentersWindow() {
        var b = HeroForegroundBuffers(itemCount: 8, index: 2)
        _ = b.page(toIndex: 3, itemCount: 8)
        // A non-adjacent set-swap jumps to a far index via reseedAll.
        b.reseedAll(itemCount: 8, index: 6)
        XCTAssertEqual(b.currentItemIndex, 6)
        XCTAssertEqual(b.itemIndex(forSlot: b.nextSlot), 7)
        XCTAssertEqual(b.itemIndex(forSlot: b.previousSlot), 5)
    }
}
