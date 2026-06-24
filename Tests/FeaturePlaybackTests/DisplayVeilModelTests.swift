#if canImport(AVFoundation)
import XCTest
@testable import FeaturePlayback

/// Gated sleeper that records each requested duration so a test can release a
/// specific pending sleep by its duration (the cap vs. the fallback vs. an
/// adaptive post-settle hold). Unlike the simpler helper in
/// `HDRTransitionModelTests`, this one is **cancellation-aware**: cancelling the
/// awaiting task (as the model does when it re-arms a timer) removes the sleep
/// from the pending set, so `hasPending`/`pendingCount` reflect only live timers.
private final class TaggedSleeper: @unchecked Sendable {
    private let lock = NSLock()
    private struct Waiter { let id: Int; let seconds: TimeInterval; let continuation: CheckedContinuation<Void, Error> }
    private var waiters: [Waiter] = []
    private var cancelledIDs: Set<Int> = []
    private var nextID = 0

    func sleep(_ seconds: TimeInterval) async throws {
        let id: Int = {
            lock.lock(); defer { lock.unlock() }
            let i = nextID; nextID += 1; return i
        }()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                lock.lock()
                if cancelledIDs.remove(id) != nil {
                    // Cancellation raced ahead of registration — resolve immediately.
                    lock.unlock()
                    cont.resume(throwing: CancellationError())
                } else {
                    waiters.append(Waiter(id: id, seconds: seconds, continuation: cont))
                    lock.unlock()
                }
            }
        } onCancel: {
            lock.lock()
            if let idx = waiters.firstIndex(where: { $0.id == id }) {
                let w = waiters.remove(at: idx)
                lock.unlock()
                w.continuation.resume(throwing: CancellationError())
            } else {
                cancelledIDs.insert(id)
                lock.unlock()
            }
        }
    }

    /// Resumes the first pending sleep whose duration matches `seconds`. A no-op if
    /// none is pending (e.g. it was already cancelled/removed).
    func release(matching seconds: TimeInterval) {
        lock.lock()
        let index = waiters.firstIndex { abs($0.seconds - seconds) < 1e-6 }
        let waiter = index.map { waiters.remove(at: $0) }
        lock.unlock()
        waiter?.continuation.resume()
    }

    /// Whether a sleep of the given duration is currently pending.
    func hasPending(_ seconds: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return waiters.contains { abs($0.seconds - seconds) < 1e-6 }
    }

    var pendingCount: Int {
        lock.lock(); defer { lock.unlock() }
        return waiters.count
    }
}

/// A clock whose value the test sets explicitly, so the engage→settle gap that
/// drives the adaptive hold is fully deterministic.
private final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval
    init(_ start: TimeInterval = 0) { value = start }
    func set(_ v: TimeInterval) { lock.lock(); value = v; lock.unlock() }
    func read() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return value }
}

@MainActor
final class DisplayVeilModelTests: XCTestCase {
    private func waitUntil(_ predicate: () -> Bool, tries: Int = 500) async -> Bool {
        for _ in 0..<tries {
            if predicate() { return true }
            await Task.yield()
        }
        return predicate()
    }

    private func assertEventually(
        _ predicate: () -> Bool,
        _ message: @autoclosure () -> String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let ok = await waitUntil(predicate)
        XCTAssertTrue(ok, message(), file: file, line: line)
    }

    private func makeModel(
        _ sleeper: TaggedSleeper,
        clock: MutableClock,
        config: DisplayVeilModel.Configuration = DisplayVeilModel.Configuration(
            noSettleHold: 2.5,
            minPostSettle: 0.8,
            maxPostSettle: 2.2,
            settleLagMultiplier: 1.0,
            safetyCap: 6.0
        )
    ) -> DisplayVeilModel {
        DisplayVeilModel(
            configuration: config,
            now: { clock.read() },
            sleep: { try await sleeper.sleep($0) }
        )
    }

    // MARK: Pure adaptive-hold math

    func testPostSettleHoldClampsAndScales() {
        let model = DisplayVeilModel(
            configuration: .init(minPostSettle: 0.8, maxPostSettle: 2.2, settleLagMultiplier: 1.0)
        )
        XCTAssertEqual(model.postSettleHold(forGap: 0.0), 0.8, accuracy: 1e-9) // floor
        XCTAssertEqual(model.postSettleHold(forGap: 0.2), 0.8, accuracy: 1e-9) // floor
        XCTAssertEqual(model.postSettleHold(forGap: 1.5), 1.5, accuracy: 1e-9) // proportional
        XCTAssertEqual(model.postSettleHold(forGap: 5.0), 2.2, accuracy: 1e-9) // ceiling
    }

    func testPostSettleHoldHonorsMultiplier() {
        let model = DisplayVeilModel(
            configuration: .init(minPostSettle: 0.1, maxPostSettle: 10, settleLagMultiplier: 0.5)
        )
        XCTAssertEqual(model.postSettleHold(forGap: 2.0), 1.0, accuracy: 1e-9)
    }

    // MARK: Engage

    func testEngageRaisesVeilAndArmsFallbackAndCap() async {
        let sleeper = TaggedSleeper()
        let clock = MutableClock()
        let model = makeModel(sleeper, clock: clock)

        model.engage()
        XCTAssertEqual(model.veilOpacity, 1)
        XCTAssertTrue(model.isEngaged)
        XCTAssertTrue(model.isVeiled)
        // Both the no-settle fallback (2.5) and the absolute safety cap (6.0) are
        // armed immediately, so coverage is guaranteed even with zero callbacks.
        await assertEventually { sleeper.pendingCount == 2 }
        XCTAssertTrue(sleeper.hasPending(2.5))
        XCTAssertTrue(sleeper.hasPending(6.0))
    }

    func testNoSettleFallbackLowersVeil() async {
        let sleeper = TaggedSleeper()
        let clock = MutableClock()
        let model = makeModel(sleeper, clock: clock)

        model.engage()
        await assertEventually { sleeper.pendingCount == 2 }

        // No settle ever arrives; the blind fallback must still clear the veil.
        sleeper.release(matching: 2.5)
        await assertEventually { model.veilOpacity == 0 }
        XCTAssertFalse(model.isEngaged)
    }

    func testSafetyCapLowersVeilEvenIfHoldsKeepArming() async {
        let sleeper = TaggedSleeper()
        let clock = MutableClock()
        let model = makeModel(sleeper, clock: clock)

        model.engage()
        await assertEventually { sleeper.pendingCount == 2 }

        // The absolute cap is the last-resort net — releasing it clears the veil
        // regardless of any pending fallback/settle hold.
        sleeper.release(matching: 6.0)
        await assertEventually { model.veilOpacity == 0 }
        XCTAssertFalse(model.isEngaged)
    }

    // MARK: Settle → adaptive hold

    func testSettleSchedulesAdaptiveHoldFromGap() async {
        let sleeper = TaggedSleeper()
        let clock = MutableClock(0)
        let model = makeModel(sleeper, clock: clock)

        model.engage() // engagedAt = 0
        await assertEventually { sleeper.pendingCount == 2 }

        // Reported settle arrives 1.5s after engage → hold ≈ 1.5s (proportional).
        clock.set(1.5)
        model.displayDidSettle()
        // The fallback (2.5) is replaced by the adaptive hold (1.5); the cap (6.0)
        // keeps running underneath.
        await assertEventually { sleeper.hasPending(1.5) }
        XCTAssertTrue(sleeper.hasPending(6.0))
        XCTAssertFalse(sleeper.hasPending(2.5), "no-settle fallback must be cancelled once a settle arrives")
        XCTAssertEqual(model.veilOpacity, 1, "veil stays black across the post-settle hold")

        sleeper.release(matching: 1.5)
        await assertEventually { model.veilOpacity == 0 }
    }

    func testSettleHoldClampedToMinForFastTV() async {
        let sleeper = TaggedSleeper()
        let clock = MutableClock(0)
        let model = makeModel(sleeper, clock: clock)

        model.engage()
        await assertEventually { sleeper.pendingCount == 2 }

        // A near-instant settle (fast TV) still holds the minimum so Home never flashes.
        clock.set(0.1)
        model.displayDidSettle()
        await assertEventually { sleeper.hasPending(0.8) }
        sleeper.release(matching: 0.8)
        await assertEventually { model.veilOpacity == 0 }
    }

    func testSettleHoldClampedToMaxForSlowTV() async {
        let sleeper = TaggedSleeper()
        let clock = MutableClock(0)
        let model = makeModel(sleeper, clock: clock)

        model.engage()
        await assertEventually { sleeper.pendingCount == 2 }

        // A very slow settle is capped so the exit can't feel indefinitely laggy.
        clock.set(10.0)
        model.displayDidSettle()
        await assertEventually { sleeper.hasPending(2.2) }
        sleeper.release(matching: 2.2)
        await assertEventually { model.veilOpacity == 0 }
    }

    func testLateSecondSettleExtendsCoverage() async {
        let sleeper = TaggedSleeper()
        let clock = MutableClock(0)
        let model = makeModel(sleeper, clock: clock)

        model.engage()
        await assertEventually { sleeper.pendingCount == 2 }

        // First settle at +1.0 schedules a 1.0s hold.
        clock.set(1.0)
        model.displayDidSettle()
        await assertEventually { sleeper.hasPending(1.0) }

        // A second mode-switch-end at +2.0 (the real physical switch) reschedules
        // to a 2.0s hold; releasing the now-cancelled 1.0 hold must NOT clear black.
        clock.set(2.0)
        model.displayDidSettle()
        await assertEventually { sleeper.hasPending(2.0) }
        sleeper.release(matching: 1.0)
        for _ in 0..<30 { await Task.yield() }
        XCTAssertEqual(model.veilOpacity, 1, "a stale/cancelled hold must not lower the veil")

        sleeper.release(matching: 2.0)
        await assertEventually { model.veilOpacity == 0 }
    }

    // MARK: Guards

    func testSettleIsNoOpWhenNotEngaged() {
        let model = DisplayVeilModel()
        model.displayDidSettle()
        XCTAssertEqual(model.veilOpacity, 0)
        XCTAssertFalse(model.isEngaged)
    }

    func testLowerClearsImmediately() {
        let model = DisplayVeilModel()
        model.engage()
        XCTAssertEqual(model.veilOpacity, 1)
        model.lower()
        XCTAssertEqual(model.veilOpacity, 0)
        XCTAssertFalse(model.isEngaged)
    }

    func testReengageRestartsTimers() async {
        let sleeper = TaggedSleeper()
        let clock = MutableClock(0)
        let model = makeModel(sleeper, clock: clock)

        model.engage()
        await assertEventually { sleeper.pendingCount == 2 }
        // Re-engaging cancels the prior timers and arms a fresh pair (no stacking).
        model.engage()
        await assertEventually { sleeper.pendingCount == 2 }
        XCTAssertEqual(model.veilOpacity, 1)
        XCTAssertTrue(model.isEngaged)
    }
}
#endif
