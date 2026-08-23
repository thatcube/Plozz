import CoreModels
import XCTest
@testable import FeatureHomeCore

final class HeroRandomRollStoreTests: XCTestCase {
    private func item(_ id: String) -> MediaItem {
        MediaItem(id: id, title: id, kind: .movie)
    }

    private func key(
        libraries: [String] = ["movies"],
        limit: Int = 8,
        hideWatched: Bool = true
    ) -> HeroRandomRollStore.Key {
        HeroRandomRollStore.Key(
            libraries: libraries.map {
                HeroRandomLibrary(accountID: "a", libraryID: $0, kind: .movie)
            },
            limit: limit,
            hideWatched: hideWatched
        )
    }

    func testASecondCurationReusesTheSameDraw() async {
        let store = HeroRandomRollStore()
        let rolls = Counter()

        let first = await store.items(for: key()) {
            await rolls.increment()
            return [self.item("r1")]
        }
        let second = await store.items(for: key()) {
            await rolls.increment()
            return [self.item("r2")]
        }

        XCTAssertEqual(first.map(\.id), ["r1"])
        XCTAssertEqual(second.map(\.id), ["r1"])
        let count = await rolls.value
        XCTAssertEqual(count, 1)
    }

    func testADifferentLibrarySelectionDrawsAgain() async {
        let store = HeroRandomRollStore()

        _ = await store.items(for: key(libraries: ["movies"])) { [self.item("r1")] }
        let second = await store.items(for: key(libraries: ["shows"])) {
            [self.item("r2")]
        }

        XCTAssertEqual(second.map(\.id), ["r2"])
    }

    func testADifferentCarouselSizeDrawsAgain() async {
        let store = HeroRandomRollStore()

        _ = await store.items(for: key(limit: 8)) { [self.item("r1")] }
        let second = await store.items(for: key(limit: 12)) { [self.item("r2")] }

        XCTAssertEqual(second.map(\.id), ["r2"])
    }

    func testTheDrawGoesStaleAfterItsLifetime() async {
        let store = HeroRandomRollStore(lifetime: 60)
        let start = Date(timeIntervalSince1970: 1_000_000)

        _ = await store.items(for: key(), now: start) { [self.item("r1")] }
        let withinLifetime = await store.items(
            for: key(),
            now: start.addingTimeInterval(59)
        ) { [self.item("r2")] }
        let afterLifetime = await store.items(
            for: key(),
            now: start.addingTimeInterval(61)
        ) { [self.item("r3")] }

        XCTAssertEqual(withinLifetime.map(\.id), ["r1"])
        XCTAssertEqual(afterLifetime.map(\.id), ["r3"])
    }

    func testAnEmptyDrawIsNotKept() async {
        // A library that momentarily failed to answer must not silence the Random
        // source for the rest of the lifetime.
        let store = HeroRandomRollStore()

        let first = await store.items(for: key()) { [] }
        let second = await store.items(for: key()) { [self.item("r1")] }

        XCTAssertTrue(first.isEmpty)
        XCTAssertEqual(second.map(\.id), ["r1"])
    }

    func testTogglingHideWatchedDrawsAgain() {
        // The Random provider filters finished titles itself, so a draw made under
        // one setting is not a valid answer under the other.
        XCTAssertNotEqual(key(hideWatched: true), key(hideWatched: false))
    }

    func testADifferentProfileScopeDrawsAgain() {
        // Scope lives in the key rather than needing an explicit invalidation,
        // which a shell can forget to wire up and which can lose a race against
        // the curation the same scope change kicks off.
        XCTAssertNotEqual(
            HeroRandomRollStore.Key(libraries: [], limit: 8, hideWatched: true, scope: "a"),
            HeroRandomRollStore.Key(libraries: [], limit: 8, hideWatched: true, scope: "b")
        )
    }

    func testOverlappingCurationsShareOneDraw() async {
        // The draw is a fan-out across every visible library on every connected
        // server — the single most expensive part of a curation.
        let store = HeroRandomRollStore()
        let rolls = Counter()
        let gate = Gate()

        async let first = store.items(for: key()) {
            await rolls.increment()
            await gate.wait()
            return [self.item("r1")]
        }
        async let second = store.items(for: key()) {
            await rolls.increment()
            await gate.wait()
            return [self.item("r2")]
        }
        try? await Task.sleep(for: .milliseconds(50))
        await gate.open()

        let results = await [first, second]
        // Which caller wins the race to start the draw is not the property — that
        // both get the SAME one, from a single fan-out, is.
        XCTAssertEqual(results[0].map(\.id), results[1].map(\.id))
        XCTAssertEqual(results[0].count, 1)
        let count = await rolls.value
        XCTAssertEqual(count, 1)
    }
}

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

/// Holds a roll open until the test lets it finish, so two curations genuinely
/// overlap rather than running one after the other.
private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}
