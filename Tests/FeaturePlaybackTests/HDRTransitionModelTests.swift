#if canImport(AVFoundation)
import XCTest
import CoreModels
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
            configuration: HDRTransitionModel.Configuration(
                maxBlackout: 4.5,
                minVeil: 0.35,
                veilFade: 0.1,
                exitSettleTimeout: 5.0
            ),
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

    func testDisplayModeRecognizesCanonicalDolbyVisionToken() {
        let metadata = MediaSourceMetadata(
            video: .init(videoRangeType: "DOVIWithHDR10")
        )
        XCTAssertEqual(HDRDisplayMode(metadata), .dolbyVision)
    }

    func testDisplayModeRecognizesHDR10PlusAsHDR() {
        let metadata = MediaSourceMetadata(
            video: .init(videoRangeType: "HDR10Plus")
        )
        XCTAssertEqual(HDRDisplayMode(metadata), .hdr10)
    }

    func testProbePendingPreemptivelyRaisesVeil() {
        let model = HDRTransitionModel()

        model.reconcile(
            from: .native(metadata: nil),
            to: .awaitingEngineProbe(hint: nil)
        )

        XCTAssertEqual(model.veilOpacity, 1)
        XCTAssertTrue(model.isVeiled)
    }

    func testSettleBeforeProbeResultWaitsForAuthoritativeHDR() async {
        let sleeper = TaggedSleeper()
        let model = makeModel(sleeper)
        let pending = EffectiveDynamicRange.awaitingEngineProbe(hint: nil)

        model.reconcile(from: .native(metadata: nil), to: pending)
        await assertEventually { sleeper.pendingCount == 1 }
        model.displayDidSettle()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(
            sleeper.pendingCount,
            1,
            "settle must wait until the pending probe identifies the source"
        )

        model.reconcile(
            from: pending,
            to: .resolved(.dolbyVision, authority: .engineProbe)
        )
        await assertEventually { sleeper.pendingCount == 2 }
        sleeper.release(matching: 0.35)
        await assertEventually { model.veilOpacity == 0 }
    }

    func testAuthoritativeSDRProbeLowersPreemptiveVeil() {
        let model = HDRTransitionModel()
        let pending = EffectiveDynamicRange.awaitingEngineProbe(hint: .hdr10)

        model.reconcile(from: .native(metadata: nil), to: pending)
        XCTAssertEqual(model.veilOpacity, 1)

        model.reconcile(
            from: pending,
            to: .resolved(.sdr, authority: .engineProbe)
        )
        XCTAssertEqual(model.veilOpacity, 0)
    }

    func testSDRProbeWaitsWhenPendingLoadReplacedNativeHDR() {
        let model = HDRTransitionModel()
        let previous = EffectiveDynamicRange.resolved(
            .hdr10,
            authority: .providerMetadata
        )
        let pending = EffectiveDynamicRange.awaitingEngineProbe(hint: nil)

        model.reconcile(from: previous, to: pending)
        model.reconcile(
            from: pending,
            to: .resolved(.sdr, authority: .engineProbe)
        )

        XCTAssertEqual(model.veilOpacity, 1)
    }

    func testProbeConfirmationDoesNotRaiseSecondVeilAfterSafetyTimeout() async {
        let sleeper = TaggedSleeper()
        let model = makeModel(sleeper)
        let pending = EffectiveDynamicRange.awaitingEngineProbe(hint: .dolbyVision)

        model.reconcile(from: .native(metadata: nil), to: pending)
        await assertEventually { sleeper.pendingCount == 1 }
        sleeper.release(matching: 4.5)
        await assertEventually { model.veilOpacity == 0 }

        model.reconcile(
            from: pending,
            to: .resolved(.dolbyVision, authority: .engineProbe)
        )
        XCTAssertEqual(model.veilOpacity, 0)
    }

    func testPreservedSameRangeHandoffRevealsWhenProbeConfirmsHint() {
        let model = HDRTransitionModel()
        let pending = EffectiveDynamicRange.awaitingEngineProbe(hint: .dolbyVision)
        model.reconcile(from: .native(metadata: nil), to: pending)
        XCTAssertEqual(model.veilOpacity, 1)

        model.reconcile(
            from: pending,
            to: .resolved(.dolbyVision, authority: .engineProbe),
            inheritedPreservedRange: .dolbyVision
        )

        XCTAssertEqual(model.veilOpacity, 0)
    }

    func testPreservedHandoffCorrectionWaitsForRealDisplaySettle() {
        let model = HDRTransitionModel()
        let pending = EffectiveDynamicRange.awaitingEngineProbe(hint: .dolbyVision)
        model.reconcile(from: .native(metadata: nil), to: pending)

        model.reconcile(
            from: pending,
            to: .resolved(.hdr10, authority: .engineProbe),
            inheritedPreservedRange: .dolbyVision
        )

        XCTAssertEqual(model.veilOpacity, 1)
    }

    func testPreservedHDRHandoffCorrectedToSDRWaitsForSettle() {
        let model = HDRTransitionModel()
        let pending = EffectiveDynamicRange.awaitingEngineProbe(hint: .dolbyVision)
        model.reconcile(from: .native(metadata: nil), to: pending)

        model.reconcile(
            from: pending,
            to: .resolved(.sdr, authority: .engineProbe),
            inheritedPreservedRange: .dolbyVision
        )

        XCTAssertEqual(model.veilOpacity, 1)
    }

    func testRestartProbeTransitionRearmsAfterPriorVeilLowered() {
        let model = HDRTransitionModel()
        model.beginProbeTransition()
        model.lowerVeil()

        model.restartProbeTransition()

        XCTAssertEqual(model.veilOpacity, 1)
    }

    func testPlozzigenToNativeEqualHDRFallbackRaisesVeil() {
        let model = HDRTransitionModel()

        model.reconcile(
            from: .resolved(.hdr10, authority: .engineProbe),
            to: .resolved(.hdr10, authority: .providerMetadata)
        )

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

    // MARK: Exit (HDR/DV → SDR on leaving playback)

    func testSDRExitRaisesNoVeil() {
        // Leaving SDR content has no panel mode switch to hide — no needless black.
        let model = HDRTransitionModel()
        XCTAssertFalse(model.beginExit(isHDR: false))
        XCTAssertEqual(model.veilOpacity, 0)
        XCTAssertFalse(model.isVeiled)
        XCTAssertFalse(model.isExiting)
    }

    func testExitRaisesVeilAndArmsSafetyTimeout() async {
        let sleeper = TaggedSleeper()
        let model = makeModel(sleeper)

        XCTAssertTrue(model.beginExit(isHDR: true))
        XCTAssertEqual(model.veilOpacity, 1)
        XCTAssertTrue(model.isExiting)
        // The exit safety timeout (5.0) is armed up front so a missing settle
        // callback can never strand the user on black.
        await assertEventually { sleeper.pendingCount == 1 }
    }

    func testExitWaitsForSettleNotAFixedDelay() async {
        let sleeper = TaggedSleeper()
        let model = makeModel(sleeper)

        XCTAssertTrue(model.beginExit(isHDR: true))
        await assertEventually { sleeper.pendingCount == 1 } // exit safety timeout

        var exited = false
        let waiter = Task { @MainActor in
            await model.waitForExit()
            exited = true
        }

        // The exit must NOT resolve on any fixed delay — only a real settle (or
        // the safety timeout) ends it. Pump the runloop: still waiting.
        for _ in 0..<50 { await Task.yield() }
        XCTAssertFalse(exited)
        XCTAssertEqual(model.veilOpacity, 1, "veil must stay raised across the exit window")

        // Display reports mode-switch-end; the model holds minVeil (0.35) then
        // resolves the exit.
        model.displayDidSettle()
        await assertEventually { sleeper.pendingCount == 2 } // minVeil hold armed
        XCTAssertFalse(exited)
        XCTAssertEqual(model.veilOpacity, 1, "veil stays black until the hold elapses")

        sleeper.release(matching: 0.35)
        _ = await waiter.value
        XCTAssertTrue(exited)
        // The veil is intentionally left raised — the caller dismisses while black,
        // and the veil is torn down with the player so it covers the handoff.
        XCTAssertEqual(model.veilOpacity, 1)
    }

    func testExitSafetyTimeoutResolvesWithoutSettle() async {
        let sleeper = TaggedSleeper()
        let model = makeModel(sleeper)

        XCTAssertTrue(model.beginExit(isHDR: true))
        await assertEventually { sleeper.pendingCount == 1 }

        var exited = false
        let waiter = Task { @MainActor in
            await model.waitForExit()
            exited = true
        }

        // No settle ever arrives; the exit safety timeout (5.0) must still resolve
        // the wait so the user is never stranded on black.
        for _ in 0..<50 { await Task.yield() }
        XCTAssertFalse(exited)
        XCTAssertEqual(model.veilOpacity, 1)

        sleeper.release(matching: 5.0)
        _ = await waiter.value
        XCTAssertTrue(exited)
    }

    func testWaitForExitReturnsImmediatelyWhenSettledBeforeWaiting() async {
        let sleeper = TaggedSleeper()
        let model = makeModel(sleeper)

        XCTAssertTrue(model.beginExit(isHDR: true))
        await assertEventually { sleeper.pendingCount == 1 }

        // Settle arrives and the hold elapses before anyone awaits the exit.
        model.displayDidSettle()
        await assertEventually { sleeper.pendingCount == 2 }
        sleeper.release(matching: 0.35)
        // Let finishExit run.
        for _ in 0..<20 { await Task.yield() }

        // A late waiter must not hang — the exit already resolved.
        var exited = false
        let waiter = Task { @MainActor in
            await model.waitForExit()
            exited = true
        }
        _ = await waiter.value
        XCTAssertTrue(exited)
    }

    func testAwaitVeilOpaqueWaitsForVeilFade() async {
        let sleeper = TaggedSleeper()
        let model = makeModel(sleeper)

        XCTAssertTrue(model.beginExit(isHDR: true))

        var faded = false
        let waiter = Task { @MainActor in
            await model.awaitVeilOpaque()
            faded = true
        }
        // It must wait the veil-fade (0.1) before letting the caller tear down.
        await assertEventually { sleeper.pendingCount == 2 } // safety timeout + veil fade
        XCTAssertFalse(faded)
        sleeper.release(matching: 0.1)
        _ = await waiter.value
        XCTAssertTrue(faded)
    }

    func testEnterRevealUnaffectedByExitPath() async {
        // The enter transition still fades to black and reveals on settle exactly
        // as before — the exit path doesn't change it.
        let sleeper = TaggedSleeper()
        let model = makeModel(sleeper)

        XCTAssertTrue(model.beginTransition(from: .sdr, to: .dolbyVision))
        XCTAssertEqual(model.veilOpacity, 1)
        XCTAssertFalse(model.isExiting)
        await assertEventually { sleeper.pendingCount == 1 } // enter safety timeout

        model.displayDidSettle()
        await assertEventually { sleeper.pendingCount == 2 } // min-hold
        sleeper.release(matching: 0.35)
        await assertEventually { model.veilOpacity == 0 }
        XCTAssertFalse(model.isVeiled)
    }
}
#endif
