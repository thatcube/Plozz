import XCTest
@testable import FeatureHome

final class HeroForegroundStaggerTests: XCTestCase {
    private func key(
        _ itemID: String,
        accountID: String? = nil,
        kind: String = "movie"
    ) -> HeroForegroundItemKey {
        HeroForegroundItemKey(
            itemID: itemID,
            sourceAccountID: accountID,
            kind: kind
        )
    }

    func testScheduledUpdateAdvancesVisualIdentityOnlyWhenApplied() {
        let keys = [key("a"), key("b")]
        var state = HeroForegroundStaggerState(itemKeys: keys, canonicalIndex: 0)

        let update = state.schedule(itemKeys: keys, canonicalIndex: 1)

        XCTAssertEqual(state.visualItemKey, key("a"))
        XCTAssertTrue(state.apply(update, itemKeys: keys, canonicalIndex: 1))
        XCTAssertEqual(state.visualItemKey, key("b"))
        XCTAssertEqual(state.visualIndex(in: keys), 1)
    }

    func testRapidPagesRejectEveryStaleGeneration() {
        let keys = [key("a"), key("b"), key("c")]
        var state = HeroForegroundStaggerState(itemKeys: keys, canonicalIndex: 0)
        let first = state.schedule(itemKeys: keys, canonicalIndex: 1)
        let latest = state.schedule(itemKeys: keys, canonicalIndex: 2)

        XCTAssertFalse(state.apply(first, itemKeys: keys, canonicalIndex: 2))
        XCTAssertEqual(state.visualItemKey, key("a"))
        XCTAssertTrue(state.apply(latest, itemKeys: keys, canonicalIndex: 2))
        XCTAssertEqual(state.visualItemKey, key("c"))
    }

    func testReversalNeverAppliesAbandonedTarget() {
        let keys = [key("a"), key("b")]
        var state = HeroForegroundStaggerState(itemKeys: keys, canonicalIndex: 0)
        let forward = state.schedule(itemKeys: keys, canonicalIndex: 1)
        let reversal = state.schedule(itemKeys: keys, canonicalIndex: 0)

        XCTAssertFalse(state.apply(forward, itemKeys: keys, canonicalIndex: 0))
        XCTAssertTrue(state.apply(reversal, itemKeys: keys, canonicalIndex: 0))
        XCTAssertEqual(state.visualItemKey, key("a"))
    }

    func testSetSwapReseedsAndInvalidatesPendingUpdate() {
        let oldKeys = [key("a"), key("b")]
        let newKeys = [key("c"), key("d")]
        var state = HeroForegroundStaggerState(itemKeys: oldKeys, canonicalIndex: 0)
        let pending = state.schedule(itemKeys: oldKeys, canonicalIndex: 1)

        state.reseed(itemKeys: newKeys, canonicalIndex: 1)

        XCTAssertEqual(state.visualItemKey, key("d"))
        XCTAssertFalse(state.apply(pending, itemKeys: newKeys, canonicalIndex: 1))
        XCTAssertEqual(state.visualItemKey, key("d"))
    }

    func testEmptySetHasNoVisualIdentity() {
        var state = HeroForegroundStaggerState(itemKeys: [], canonicalIndex: 0)
        let update = state.schedule(itemKeys: [], canonicalIndex: 0)

        XCTAssertNil(state.visualItemKey)
        XCTAssertTrue(state.apply(update, itemKeys: [], canonicalIndex: 0))
        XCTAssertNil(state.visualIndex(in: []))
    }

    func testSingleItemSetRemainsStable() {
        let keys = [key("a")]
        var state = HeroForegroundStaggerState(itemKeys: keys, canonicalIndex: 0)
        let update = state.schedule(itemKeys: keys, canonicalIndex: 0)

        XCTAssertTrue(state.apply(update, itemKeys: keys, canonicalIndex: 0))
        XCTAssertEqual(state.visualItemKey, key("a"))
        XCTAssertEqual(state.visualIndex(in: keys), 0)
    }

    func testTwoItemSetUsesFirstItemForOutOfRangeCanonicalIndex() {
        let keys = [key("a"), key("b")]
        var state = HeroForegroundStaggerState(itemKeys: keys, canonicalIndex: 9)
        XCTAssertEqual(state.visualItemKey, key("a"))

        let update = state.schedule(itemKeys: keys, canonicalIndex: -1)

        XCTAssertTrue(state.apply(update, itemKeys: keys, canonicalIndex: -1))
        XCTAssertEqual(state.visualItemKey, key("a"))
    }

    func testDuplicateRawIDsResolveByAccountAndKind() {
        let keys = [
            key("42", accountID: "server-a", kind: "movie"),
            key("42", accountID: "server-b", kind: "movie"),
            key("42", accountID: "server-b", kind: "series"),
        ]
        var state = HeroForegroundStaggerState(itemKeys: keys, canonicalIndex: 0)

        let secondAccount = state.schedule(itemKeys: keys, canonicalIndex: 1)
        XCTAssertTrue(state.apply(secondAccount, itemKeys: keys, canonicalIndex: 1))
        XCTAssertEqual(state.visualIndex(in: keys), 1)

        let differentKind = state.schedule(itemKeys: keys, canonicalIndex: 2)
        XCTAssertTrue(state.apply(differentKind, itemKeys: keys, canonicalIndex: 2))
        XCTAssertEqual(state.visualIndex(in: keys), 2)
    }
}
