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
