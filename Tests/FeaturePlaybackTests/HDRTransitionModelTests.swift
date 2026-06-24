#if canImport(AVFoundation)
import XCTest
@testable import FeaturePlayback

/// Gated sleeper that records each requested duration so a test can release a
/// specific pending sleep (the safety timeout vs. the settle min-hold).
private final class TaggedSleeper: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [(seconds: TimeInterval, continuation: CheckedContinuation<Void, Error>)] = []

    func sleep(_ seconds: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            waiters.append((seconds, continuation))
            lock.unlock()
        }
    }

    /// Resumes the first pending sleep whose duration matches `seconds`.
    func release(matching seconds: TimeInterval) {
        lock.lock()
        let index = waiters.firstIndex { abs($0.seconds - seconds) < 1e-6 }
        let waiter = index.map { waiters.remove(at: $0) }
        lock.unlock()
        waiter?.continuation.resume()
    }

    var pendingCount: Int {
        lock.lock(); defer { lock.unlock() }
        return waiters.count
    }
}

@MainActor
final class HDRTransitionModelTests: XCTestCase {
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

    private func makeModel(_ sleeper: TaggedSleeper) -> HDRTransitionModel {
        HDRTransitionModel(
            configuration: HDRTransitionModel.Configuration(maxBlackout: 4.5, minVeil: 0.35),
            sleep: { try await sleeper.sleep($0) }
        )
    }

    // MARK: Decision logic

    func testDynamicRangeWillSwitch() {
        XCTAssertTrue(HDRTransitionModel.dynamicRangeWillSwitch(from: .sdr, to: .dolbyVision))
        XCTAssertTrue(HDRTransitionModel.dynamicRangeWillSwitch(from: .sdr, to: .hdr10))
        XCTAssertTrue(HDRTransitionModel.dynamicRangeWillSwitch(from: .dolbyVision, to: .sdr))
        XCTAssertFalse(HDRTransitionModel.dynamicRangeWillSwitch(from: .sdr, to: .sdr))
        XCTAssertFalse(HDRTransitionModel.dynamicRangeWillSwitch(from: .hdr10, to: .hdr10))
    }

    func testBeginTransitionRaisesVeilOnlyWhenRangeSwitches() {
        let model = HDRTransitionModel()
        XCTAssertFalse(model.beginTransition(from: .sdr, to: .sdr))
        XCTAssertEqual(model.veilOpacity, 0)
        XCTAssertFalse(model.isVeiled)

        XCTAssertTrue(model.beginTransition(from: .sdr, to: .dolbyVision))
        XCTAssertEqual(model.veilOpacity, 1)
        XCTAssertTrue(model.isVeiled)
    }

    func testHDRToSDRLeaveAlsoVeils() {
        let model = HDRTransitionModel()
        XCTAssertTrue(model.beginTransition(from: .dolbyVision, to: .sdr))
        XCTAssertEqual(model.veilOpacity, 1)
    }

    func testHDR10ToDolbyVisionAlsoVeils() {
        // A cross-range switch (HDR10 -> Dolby Vision) still re-syncs the panel.
        let model = HDRTransitionModel()
        XCTAssertTrue(model.beginTransition(from: .hdr10, to: .dolbyVision))
        XCTAssertEqual(model.veilOpacity, 1)
    }

    // MARK: Reveal on settle

    func testSettleLowersVeilAfterMinHold() async {
        let sleeper = TaggedSleeper()
        let model = makeModel(sleeper)

        model.raiseVeil()
        XCTAssertEqual(model.veilOpacity, 1)
        await assertEventually { sleeper.pendingCount == 1 } // safety timeout armed

        model.displayDidSettle()
        await assertEventually { sleeper.pendingCount == 2 } // settle min-hold armed
        sleeper.release(matching: 0.35)

        await assertEventually { model.veilOpacity == 0 }
        XCTAssertFalse(model.isVeiled)
    }

    // MARK: Safety timeout — never strand on black

    func testTimeoutLowersVeilWithoutSettle() async {
        let sleeper = TaggedSleeper()
        let model = makeModel(sleeper)

        model.raiseVeil()
        XCTAssertEqual(model.veilOpacity, 1)
        await assertEventually { sleeper.pendingCount == 1 }

        // No settle ever arrives; the safety timeout must still reveal the UI.
        sleeper.release(matching: 4.5)
        await assertEventually { model.veilOpacity == 0 }
    }

    func testSettleIsNoOpWhenNotVeiled() {
        let model = HDRTransitionModel()
        model.displayDidSettle()
        XCTAssertEqual(model.veilOpacity, 0)
    }

    func testLowerVeilClearsImmediately() {
        let model = HDRTransitionModel()
        model.raiseVeil()
        XCTAssertEqual(model.veilOpacity, 1)
        model.lowerVeil()
        XCTAssertEqual(model.veilOpacity, 0)
    }

    func testDuplicateSettleArmsHoldOnlyOnce() async {
        let sleeper = TaggedSleeper()
        let model = makeModel(sleeper)

        model.raiseVeil()
        await assertEventually { sleeper.pendingCount == 1 }

        model.displayDidSettle()
        await assertEventually { sleeper.pendingCount == 2 }
        // A second settle while one is pending must not arm another min-hold.
        model.displayDidSettle()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(sleeper.pendingCount, 2)
    }
}
#endif
