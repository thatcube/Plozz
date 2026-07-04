import XCTest
@testable import CoreUI

/// Drives `LoadingMessageModel`'s async loop deterministically by gating every
/// `sleep` call, so we can assert state between the threshold and each cycle.
private final class GatedSleeper: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func sleep(_ seconds: TimeInterval) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            waiters.append(continuation)
            lock.unlock()
        }
    }

    /// Releases the earliest pending sleep, if any.
    func releaseNext() {
        lock.lock()
        let next = waiters.isEmpty ? nil : waiters.removeFirst()
        lock.unlock()
        next?.resume()
    }

    var pendingCount: Int {
        lock.lock(); defer { lock.unlock() }
        return waiters.count
    }
}

@MainActor
final class LoadingMessageModelTests: XCTestCase {
    private func makeMessages(_ count: Int) -> [LoadingMessage] {
        (0..<count).map { LoadingMessage(id: "m\($0)", text: "Message \($0)") }
    }

    /// Yields repeatedly until `predicate` holds or we exhaust `tries`.
    private func waitUntil(_ predicate: () -> Bool, tries: Int = 500) async -> Bool {
        for _ in 0..<tries {
            if predicate() { return true }
            await Task.yield()
        }
        return predicate()
    }

    private func assertEventually(
        _ predicate: () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let ok = await waitUntil(predicate)
        XCTAssertTrue(ok, file: file, line: line)
    }

    private func makeModel(
        _ messages: [LoadingMessage],
        _ sleeper: GatedSleeper,
        cycleInterval: TimeInterval = 3.0
    ) -> LoadingMessageModel {
        LoadingMessageModel(
            sequencer: LoadingMessageSequencer(messages: messages, initialDelay: 3.5, cycleInterval: cycleInterval),
            shufflesMessages: false,
            sleep: { await sleeper.sleep($0) }
        )
    }

    func testStartsSpinnerOnly() async {
        let messages = makeMessages(3)
        let sleeper = GatedSleeper()
        let model = makeModel(messages, sleeper)
        model.start()
        // The loop should be parked on the initial-delay sleep, no message yet.
        await assertEventually { sleeper.pendingCount == 1 }
        XCTAssertNil(model.currentMessage)
        XCTAssertEqual(model.phase, .spinnerOnly)
        model.stop()
    }

    func testShowsFirstMessageAfterThresholdThenCycles() async {
        let messages = makeMessages(3)
        let sleeper = GatedSleeper()
        let model = makeModel(messages, sleeper)
        model.start()

        // Release the initial delay -> first message appears.
        await assertEventually { sleeper.pendingCount == 1 }
        sleeper.releaseNext()
        await assertEventually { model.currentMessage == messages[0] }

        // Release the first cycle -> second message.
        await assertEventually { sleeper.pendingCount == 1 }
        sleeper.releaseNext()
        await assertEventually { model.currentMessage == messages[1] }

        // Release the second cycle -> third message.
        await assertEventually { sleeper.pendingCount == 1 }
        sleeper.releaseNext()
        await assertEventually { model.currentMessage == messages[2] }

        model.stop()
    }

    func testStopReturnsToSpinnerOnly() async {
        let messages = makeMessages(2)
        let sleeper = GatedSleeper()
        let model = makeModel(messages, sleeper)
        model.start()
        await assertEventually { sleeper.pendingCount == 1 }
        sleeper.releaseNext()
        await assertEventually { model.currentMessage == messages[0] }

        model.stop()
        XCTAssertEqual(model.phase, .spinnerOnly)
        XCTAssertNil(model.currentMessage)
    }

    /// A non-positive cycle interval must show the first message once and then
    /// *stop sleeping* — never busy-loop on a zero-duration timer.
    func testZeroCycleIntervalShowsFirstMessageAndDoesNotBusyLoop() async {
        let messages = makeMessages(3)
        let sleeper = GatedSleeper()
        let model = makeModel(messages, sleeper, cycleInterval: 0)
        model.start()

        // Parked on the initial delay.
        await assertEventually { sleeper.pendingCount == 1 }
        sleeper.releaseNext()

        // First message shows…
        await assertEventually { model.currentMessage == messages[0] }
        // …and the loop exits: no further sleeps are ever requested.
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(sleeper.pendingCount, 0)
        XCTAssertEqual(model.currentMessage, messages[0])

        model.stop()
    }
}

/// In-memory `LoadingMessageDeckStore` so the shuffle-bag persistence can be
/// exercised across simulated app launches without touching `UserDefaults`.
private final class InMemoryDeckStore: LoadingMessageDeckStore, @unchecked Sendable {
    private let lock = NSLock()
    private var decks: [String: (order: [String], cursor: Int)] = [:]

    func loadDeck(signature: String) -> (order: [String], cursor: Int)? {
        lock.lock(); defer { lock.unlock() }
        return decks[signature]
    }

    func saveDeck(signature: String, order: [String], cursor: Int) {
        lock.lock(); defer { lock.unlock() }
        decks[signature] = (order, cursor)
    }
}

@MainActor
final class LoadingMessageShuffleBagTests: XCTestCase {
    private func makeMessages(_ count: Int) -> [LoadingMessage] {
        (0..<count).map { LoadingMessage(id: "m\($0)", text: "Message \($0)") }
    }

    private func waitUntil(_ predicate: () -> Bool, tries: Int = 500) async -> Bool {
        for _ in 0..<tries {
            if predicate() { return true }
            await Task.yield()
        }
        return predicate()
    }

    /// Runs one "short load" (a single message then the loop parks) and returns
    /// the message ID that was shown.
    private func runOneLoad(
        _ messages: [LoadingMessage],
        store: LoadingMessageDeckStore,
        shuffle: @escaping @Sendable ([String]) -> [String]
    ) async -> String? {
        let sleeper = GatedSleeper()
        let model = LoadingMessageModel(
            sequencer: LoadingMessageSequencer(messages: messages, initialDelay: 3.5, cycleInterval: 0),
            shufflesMessages: true,
            deckStore: store,
            shuffle: shuffle,
            sleep: { await sleeper.sleep($0) }
        )
        model.start()
        _ = await waitUntil { sleeper.pendingCount == 1 }
        sleeper.releaseNext()
        _ = await waitUntil { model.currentMessage != nil }
        let shown = model.currentMessage?.id
        model.stop()
        return shown
    }

    /// Every message must be dealt exactly once before any repeat, and the deck
    /// must resume from where the previous load left off (persistence).
    func testDealsEveryMessageOnceBeforeRepeatingAcrossLoads() async {
        let messages = makeMessages(4)
        let store = InMemoryDeckStore()
        // Identity shuffle keeps the deck deterministic: [m0, m1, m2, m3].
        let shuffle: @Sendable ([String]) -> [String] = { $0 }

        var firstPass: [String] = []
        for _ in 0..<4 {
            if let id = await runOneLoad(messages, store: store, shuffle: shuffle) {
                firstPass.append(id)
            }
        }
        // All four, each exactly once, in deck order.
        XCTAssertEqual(firstPass, ["m0", "m1", "m2", "m3"])
        XCTAssertEqual(Set(firstPass).count, 4)

        // A fifth load exhausts the deck and reshuffles — repeats are only
        // allowed now that the whole set has been shown.
        let fifth = await runOneLoad(messages, store: store, shuffle: shuffle)
        XCTAssertEqual(fifth, "m0")
    }

    /// When a fresh deck would start on the same message that just ended the
    /// previous deck (within one continuous load), the first two are swapped to
    /// avoid an adjacent repeat.
    func testAvoidsAdjacentRepeatAcrossDeckBoundary() async {
        let messages = makeMessages(3)
        let store = InMemoryDeckStore()
        // Stateful shuffle: the first deck ends on m2, and the next shuffle would
        // *start* on m2 — the guard must swap it away.
        final class Shuffles: @unchecked Sendable {
            private let lock = NSLock()
            private var call = 0
            func next(_ ids: [String]) -> [String] {
                lock.lock(); defer { lock.unlock() }
                call += 1
                return call == 1 ? ["m0", "m1", "m2"] : ["m2", "m1", "m0"]
            }
        }
        let shuffles = Shuffles()
        let sleeper = GatedSleeper()
        let model = LoadingMessageModel(
            sequencer: LoadingMessageSequencer(messages: messages, initialDelay: 3.5, cycleInterval: 3.0),
            shufflesMessages: true,
            deckStore: store,
            shuffle: { shuffles.next($0) },
            sleep: { await sleeper.sleep($0) }
        )

        var shown: [String] = []
        model.start()
        _ = await waitUntil { sleeper.pendingCount == 1 }
        sleeper.releaseNext() // past initial delay → first message
        for _ in 0..<4 {
            let prev = shown.last
            _ = await waitUntil { model.currentMessage != nil && model.currentMessage?.id != prev }
            if let id = model.currentMessage?.id { shown.append(id) }
            _ = await waitUntil { sleeper.pendingCount == 1 }
            sleeper.releaseNext()
        }
        model.stop()

        // First deck deals m0, m1, m2. The boundary reshuffle would start on m2
        // (== last shown), so the guard swaps → the 4th message is m1, not m2.
        XCTAssertEqual(Array(shown.prefix(4)), ["m0", "m1", "m2", "m1"])
    }

    /// Changing the message set (a different signature) must not reuse a saved
    /// deck belonging to the old set.
    func testDifferentMessageSetStartsFreshDeck() async {
        let store = InMemoryDeckStore()
        let shuffle: @Sendable ([String]) -> [String] = { $0 }

        let setA = makeMessages(3)
        _ = await runOneLoad(setA, store: store, shuffle: shuffle) // deals m0

        // A larger set has a different signature → its own deck starting at m0.
        let setB = makeMessages(5)
        let shown = await runOneLoad(setB, store: store, shuffle: shuffle)
        XCTAssertEqual(shown, "m0")

        // Signatures differ for different membership, match for the same set.
        XCTAssertNotEqual(
            LoadingMessageModel.signature(of: setA.map(\.id)),
            LoadingMessageModel.signature(of: setB.map(\.id))
        )
        XCTAssertEqual(
            LoadingMessageModel.signature(of: ["a", "b", "c"]),
            LoadingMessageModel.signature(of: ["c", "b", "a"])
        )
    }
}
