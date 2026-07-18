import Foundation
import XCTest
@testable import MediaTransportCore

private final class BlockingByteSource: MediaTransportByteSource, @unchecked Sendable {
    let gate = AsyncTestGate()
    private let lock = NSLock()
    private var shutdownCountStorage = 0
    let byteSize: Int64 = 1
    var shutdownCount: Int { lock.withLock { shutdownCountStorage } }

    func read(at offset: Int64, length: Int) async throws -> Data {
        await gate.wait()
        return Data([42])
    }

    func shutdown() async {
        lock.withLock { shutdownCountStorage += 1 }
    }
}

private final class RetryingDrainScannerResource: MediaIOScannerResource, @unchecked Sendable {
    enum FakeError: Error { case closeFailed }

    private let lock = NSLock()
    private var drainCheckCountStorage = 0
    private var forceCloseCountStorage = 0

    var isDrained: Bool {
        lock.withLock {
            drainCheckCountStorage += 1
            return false
        }
    }
    var drainCheckCount: Int { lock.withLock { drainCheckCountStorage } }
    var forceCloseCount: Int { lock.withLock { forceCloseCountStorage } }

    func cancel() async {}

    func forceClose() async throws {
        lock.withLock { forceCloseCountStorage += 1 }
        throw FakeError.closeFailed
    }
}

private final class BlockingForceCloseScannerResource: MediaIOScannerResource, @unchecked Sendable {
    enum FakeError: Error { case closeFailed }

    let forceCloseGate = AsyncTestGate()
    var isDrained: Bool { false }

    func cancel() async {}

    func forceClose() async throws {
        await forceCloseGate.wait()
        throw FakeError.closeFailed
    }
}

/// cancel and forceClose both block on gates that the test controls, so neither
/// ever returns on its own — the arbiter must bound both under one deadline.
private final class HangingScannerResource: MediaIOScannerResource, @unchecked Sendable {
    enum FakeError: Error { case closeFailed }

    let cancelGate = AsyncTestGate()
    let forceCloseGate = AsyncTestGate()
    private let lock = NSLock()
    private var cancelCountStorage = 0
    private var forceCloseCountStorage = 0

    var cancelCount: Int { lock.withLock { cancelCountStorage } }
    var forceCloseCount: Int { lock.withLock { forceCloseCountStorage } }
    var isDrained: Bool { false }

    func cancel() async {
        lock.withLock { cancelCountStorage += 1 }
        await cancelGate.wait()
    }

    func forceClose() async throws {
        lock.withLock { forceCloseCountStorage += 1 }
        await forceCloseGate.wait()
        throw FakeError.closeFailed
    }
}

/// cancel blocks forever, but force-close returns cleanly — proves a cancel that
/// consumes its whole graceful slice still leaves the force-close reserve.
private final class CancelHangsForceCloseSucceedsResource: MediaIOScannerResource, @unchecked Sendable {
    let cancelGate = AsyncTestGate()
    private let lock = NSLock()
    private var forceCloseCountStorage = 0

    var forceCloseCount: Int { lock.withLock { forceCloseCountStorage } }
    var isDrained: Bool { false }

    func cancel() async { await cancelGate.wait() }

    func forceClose() async throws {
        lock.withLock { forceCloseCountStorage += 1 }
    }
}

/// cancel returns immediately but the resource never signals drained; force-close
/// then establishes closure within the remaining budget.
private final class NeverDrainsResource: MediaIOScannerResource, @unchecked Sendable {
    private let lock = NSLock()
    private var forceCloseCountStorage = 0

    var forceCloseCount: Int { lock.withLock { forceCloseCountStorage } }
    var isDrained: Bool { false }

    func cancel() async {}

    func forceClose() async throws {
        lock.withLock { forceCloseCountStorage += 1 }
    }
}

final class SourceLeaseAndArbiterTests: XCTestCase {
    func testBackgroundAdmissionTracksScannerAndPlayback() async throws {
        let arbiter = MediaIOArbiter(accountID: "account")
        var allowed = await arbiter.permitsBackgroundWork()
        XCTAssertTrue(allowed)

        let scanner = try await arbiter.acquireScanner(resource: FakeScannerResource())
        allowed = await arbiter.permitsBackgroundWork()
        XCTAssertFalse(allowed)
        await scanner.finishAndWait()
        allowed = await arbiter.permitsBackgroundWork()
        XCTAssertTrue(allowed)

        let playback = try await arbiter.acquirePlayback()
        allowed = await arbiter.permitsBackgroundWork()
        XCTAssertFalse(allowed)
        await playback.releaseAndWait()
        allowed = await arbiter.permitsBackgroundWork()
        XCTAssertTrue(allowed)
    }

    func testLeaseWithoutCursorShutsDownWhenClosed() async {
        let source = FakeByteSource(data: Data())
        let lease = MediaTransportSourceLease(source: source)

        lease.close()
        await lease.waitForFinalShutdown()

        XCTAssertEqual(source.shutdownCount, 1)
        XCTAssertNil(lease.makeCursor())
    }

    func testClonedCursorsAreIndependentAndFinalCloseShutsDownOnce() async throws {
        let source = FakeByteSource(data: Data([0, 1, 2, 3]))
        let lease = MediaTransportSourceLease(source: source)
        let first = try XCTUnwrap(lease.makeCursor())
        let second = try XCTUnwrap(first.clone())

        first.close()
        XCTAssertEqual(source.shutdownCount, 0)
        let bytes = try await second.read(at: 1, length: 2)
        XCTAssertEqual(bytes, Data([1, 2]))
        second.close()
        await lease.waitForFinalShutdown()
        XCTAssertEqual(source.shutdownCount, 1)
        XCTAssertNil(first.clone())
    }

    func testCursorCancellationDoesNotSkipInflightDrain() async throws {
        let source = BlockingByteSource()
        let lease = MediaTransportSourceLease(source: source)
        let cursor = try XCTUnwrap(lease.makeCursor())
        let read = Task { try await cursor.read(at: 0, length: 1) }
        await source.gate.waitUntilEntered()

        cursor.cancel()
        cursor.close()
        XCTAssertEqual(source.shutdownCount, 0)
        source.gate.open()
        _ = try await read.value
        await lease.waitForFinalShutdown()
        XCTAssertEqual(source.shutdownCount, 1)
    }

    func testPlaybackCancelsAndDrainsScannerAndRejectsLateCompletion() async throws {
        let arbiter = MediaIOArbiter(
            accountID: "account",
            deadline: FakeDrainDeadline(drains: true)
        )
        let scannerResource = FakeScannerResource()
        let scanner = try await arbiter.acquireScanner(resource: scannerResource)
        let playback = try await arbiter.acquirePlayback()

        XCTAssertEqual(scannerResource.cancelCount, 1)
        XCTAssertEqual(scannerResource.forceCloseCount, 0)
        scanner.finish()
        do {
            _ = try await arbiter.acquireScanner(resource: FakeScannerResource())
            XCTFail("scanner admitted during playback")
        } catch let error as MediaTransportError {
            XCTAssertEqual(error, .resourceBusy)
        }
        playback.release()
        var nextScanner: MediaIOScannerLease?
        for _ in 0..<1_000 {
            if let admitted = try? await arbiter.acquireScanner(resource: FakeScannerResource()) {
                nextScanner = admitted
                break
            }
            await Task.yield()
        }
        XCTAssertNotNil(nextScanner)
    }

    func testTimeoutForceClosesScannerBeforePlayback() async throws {
        let arbiter = MediaIOArbiter(
            accountID: "account",
            deadline: FakeDrainDeadline(drains: false)
        )
        let scanner = FakeScannerResource()
        let scannerLease = try await arbiter.acquireScanner(resource: scanner)
        let playback = try await arbiter.acquirePlayback()

        XCTAssertEqual(scanner.cancelCount, 1)
        XCTAssertEqual(scanner.forceCloseCount, 1)
        scannerLease.finish()
        playback.release()
    }

    func testForceCloseFailureReturnsResourceBusy() async throws {
        let arbiter = MediaIOArbiter(
            accountID: "account",
            deadline: FakeDrainDeadline(drains: false)
        )
        let scanner = FakeScannerResource()
        scanner.forceCloseFails = true
        let scannerLease = try await arbiter.acquireScanner(resource: scanner)

        do {
            _ = try await arbiter.acquirePlayback()
            XCTFail("playback admitted after failed force close")
        } catch let error as MediaTransportError {
            XCTAssertEqual(error, .resourceBusy)
        }
        scanner.forceCloseFails = false
        let playback = try await arbiter.acquirePlayback()
        XCTAssertEqual(scanner.forceCloseCount, 2)
        playback.release()
        scannerLease.finish()
    }

    func testOverlappingPlaybackLeasesBlockScannerUntilAllRelease() async throws {
        let arbiter = MediaIOArbiter(accountID: "account")
        let firstPlayback = try await arbiter.acquirePlayback()
        let secondPlayback = try await arbiter.acquirePlayback()
        do {
            _ = try await arbiter.acquireScanner(resource: FakeScannerResource())
            XCTFail("scanner admitted during overlapping playback")
        } catch let error as MediaTransportError {
            XCTAssertEqual(error, .resourceBusy)
        }
        await firstPlayback.releaseAndWait()
        do {
            _ = try await arbiter.acquireScanner(resource: FakeScannerResource())
            XCTFail("scanner admitted before final playback released")
        } catch let error as MediaTransportError {
            XCTAssertEqual(error, .resourceBusy)
        }
        await secondPlayback.releaseAndWait()
        let scanner = try await arbiter.acquireScanner(resource: FakeScannerResource())
        await scanner.finishAndWait()
    }

    func testReplacingScannerCreatesDisposableGeneration() async throws {
        let arbiter = MediaIOArbiter(
            accountID: "account",
            deadline: FakeDrainDeadline(drains: true)
        )
        let firstResource = FakeScannerResource()
        let secondResource = FakeScannerResource()
        let first = try await arbiter.acquireScanner(resource: firstResource)
        let second = try await arbiter.acquireScanner(resource: secondResource)
        XCTAssertNotEqual(first.generation, second.generation)
        XCTAssertEqual(firstResource.cancelCount, 1)

        first.finish()
        let playback = try await arbiter.acquirePlayback()
        XCTAssertEqual(secondResource.cancelCount, 1)
        second.finish()
        playback.release()
    }

    func testPlaybackReservationPreemptsScannerReplacement() async throws {
        // Scanner A active, replacement B mid-drain, then playback arrives. Playback
        // reserves ahead of the replacement; B must yield resourceBusy and playback
        // must win deterministically after A drains (finding A2).
        let drainGate = AsyncTestGate()
        let arbiter = MediaIOArbiter(
            accountID: "account",
            deadline: ControlledDrainDeadline(results: [true], gate: drainGate)
        )
        let firstResource = FakeScannerResource()
        let first = try await arbiter.acquireScanner(resource: firstResource)
        let secondResource = FakeScannerResource()
        let replacement = Task {
            try await arbiter.acquireScanner(resource: secondResource)
        }
        // Wait until B is inside the drain-verification of A (blocked on the gate).
        await drainGate.waitUntilEntered()

        let playbackTask = Task { try await arbiter.acquirePlayback() }
        // Deterministically wait for playback to register its priority reservation.
        _ = await waitUntilAsync { await arbiter.pendingPlaybackReservations() == 1 }

        // Completing A's drain lets the replacement observe the reservation and yield.
        drainGate.open()

        do {
            _ = try await replacement.value
            XCTFail("scanner replacement installed despite a playback reservation")
        } catch let error as MediaTransportError {
            XCTAssertEqual(error, .resourceBusy)
        }
        let playback = try await playbackTask.value
        XCTAssertEqual(firstResource.cancelCount, 1)
        _ = first
        playback.release()
    }

    func testPermanentlyBlockedCancelAndForceCloseReturnsBoundedFailure() async throws {
        let resource = HangingScannerResource()
        let drainTimeout = Duration.milliseconds(300)
        let arbiter = MediaIOArbiter(
            accountID: "account",
            drainTimeout: drainTimeout
        )
        let scanner = try await arbiter.acquireScanner(resource: resource)

        let clock = ContinuousClock()
        let start = clock.now
        do {
            _ = try await arbiter.acquirePlayback()
            XCTFail("playback admitted despite an unclosable scanner")
        } catch let error as MediaTransportError {
            XCTAssertEqual(error, .resourceBusy)
        }
        let elapsed = start.duration(to: clock.now)

        XCTAssertEqual(
            resource.forceCloseCount,
            1,
            "force-close must be invoked within the absolute deadline even when cancel blocks"
        )
        // ONE absolute deadline: a blocked cancel is bounded at its start-anchored
        // cutoff, then the blocked force-close is bounded at the same start-anchored
        // final deadline — so total elapsed tracks drainTimeout, NOT the additive sum
        // of per-stage durations (which would be ~2x). The tolerance covers CI
        // actor-scheduling jitter around the two start-anchored cutoffs.
        let tolerance = Duration.milliseconds(150)
        XCTAssertGreaterThanOrEqual(
            elapsed,
            drainTimeout - tolerance,
            "escalation returned before exhausting the single transition deadline"
        )
        XCTAssertLessThan(
            elapsed,
            drainTimeout + tolerance,
            "elapsed exceeded one absolute deadline (stages summed instead of sharing it)"
        )

        scanner.finish()
        resource.cancelGate.open()
        resource.forceCloseGate.open()
    }

    /// Contract for a literal zero / fully-elapsed transition deadline: force-close
    /// is granted exactly `remaining(until: finalDeadline)` with no hidden minimum,
    /// so a zero deadline reserves no force-close window at all. The transition must
    /// then report bounded failure (no lease / `resourceBusy`) rather than borrowing
    /// extra time to squeeze in an attempt — that borrowing would silently exceed the
    /// promised absolute bound. This is the direct guard against reintroducing a
    /// `minimumForceCloseAttempt`-style floor.
    func testZeroDeadlineReservesNoForceCloseAndReportsBoundedFailure() async throws {
        let resource = HangingScannerResource()
        let arbiter = MediaIOArbiter(
            accountID: "account",
            drainTimeout: .zero
        )
        let scanner = try await arbiter.acquireScanner(resource: resource)

        let clock = ContinuousClock()
        let start = clock.now
        do {
            _ = try await arbiter.acquirePlayback()
            XCTFail("playback admitted under a zero transition deadline")
        } catch let error as MediaTransportError {
            XCTAssertEqual(error, .resourceBusy)
        }
        let elapsed = start.duration(to: clock.now)

        XCTAssertEqual(
            resource.forceCloseCount,
            0,
            "a zero deadline must reserve no force-close window (no hidden minimum floor)"
        )
        XCTAssertEqual(
            resource.cancelCount,
            0,
            "a zero deadline must reserve no graceful-cancel window either"
        )
        // No blocking stage was awaited, so the failure is reported almost
        // immediately; the only slack is actor-scheduling jitter, never a floor.
        XCTAssertLessThan(
            elapsed,
            .milliseconds(50),
            "zero deadline returned late — an implicit minimum window was granted"
        )

        scanner.finish()
        resource.cancelGate.open()
        resource.forceCloseGate.open()
    }

    func testBlockedCancelPreservesForceCloseReserve() async throws {
        let resource = CancelHangsForceCloseSucceedsResource()
        let arbiter = MediaIOArbiter(
            accountID: "account",
            drainTimeout: .milliseconds(300)
        )
        let scanner = try await arbiter.acquireScanner(resource: resource)
        let playback = try await arbiter.acquirePlayback()

        XCTAssertEqual(
            resource.forceCloseCount,
            1,
            "a cancel that consumes its whole graceful slice still leaves the force-close reserve"
        )
        playback.release()
        scanner.finish()
        resource.cancelGate.open()
    }

    func testCancelReturnsButDrainNeverSignalsThenForceCloseSucceeds() async throws {
        let resource = NeverDrainsResource()
        let arbiter = MediaIOArbiter(
            accountID: "account",
            drainTimeout: .milliseconds(120)
        )
        let scanner = try await arbiter.acquireScanner(resource: resource)
        let playback = try await arbiter.acquirePlayback()

        XCTAssertGreaterThanOrEqual(
            resource.forceCloseCount,
            1,
            "force-close establishes closure when the resource never signals drained"
        )
        playback.release()
        scanner.finish()
    }

    func testArbiterRetiresWhileResourceOperationNeverReturns() async throws {
        let resource = HangingScannerResource()
        weak var weakArbiter: MediaIOArbiter?
        var lease: MediaIOScannerLease?
        do {
            let arbiter = MediaIOArbiter(
                accountID: "account",
                drainTimeout: .milliseconds(80)
            )
            weakArbiter = arbiter
            lease = try await arbiter.acquireScanner(resource: resource)
            // Force a drain that times out against a permanently blocked resource.
            do {
                _ = try await arbiter.acquirePlayback()
                XCTFail("playback admitted despite an unclosable scanner")
            } catch let error as MediaTransportError {
                XCTAssertEqual(error, .resourceBusy)
            }
        }
        // Drop the only arbiter-retaining handle. The detached cancel/force-close
        // operation tasks hold the resource and their latch, never the arbiter.
        lease = nil
        _ = await waitUntilAsync(iterations: 5_000) { weakArbiter == nil }
        XCTAssertNil(
            weakArbiter,
            "arbiter must retire even while a resource operation never returns"
        )
        resource.cancelGate.open()
        resource.forceCloseGate.open()
    }

    func testRepeatedFailedForceCloseUsesBoundedDrainPolling() async throws {
        let arbiter = MediaIOArbiter(
            accountID: "account",
            drainTimeout: .milliseconds(50)
        )
        let resource = RetryingDrainScannerResource()
        let scanner = try await arbiter.acquireScanner(resource: resource)

        for _ in 0..<2 {
            do {
                _ = try await arbiter.acquirePlayback()
                XCTFail("playback admitted after failed force close")
            } catch let error as MediaTransportError {
                XCTAssertEqual(error, .resourceBusy)
            }
        }

        XCTAssertGreaterThanOrEqual(resource.drainCheckCount, 2)
        XCTAssertEqual(resource.forceCloseCount, 2)
        scanner.finish()
    }

    func testScannerFinishDuringFailedPlaybackHandoffIsNotRestored() async throws {
        let arbiter = MediaIOArbiter(
            accountID: "account",
            deadline: FakeDrainDeadline(drains: false)
        )
        let resource = BlockingForceCloseScannerResource()
        let scanner = try await arbiter.acquireScanner(resource: resource)
        let playbackRequest = Task {
            try await arbiter.acquirePlayback()
        }
        await resource.forceCloseGate.waitUntilEntered()

        await scanner.finishAndWait()
        resource.forceCloseGate.open()
        do {
            _ = try await playbackRequest.value
            XCTFail("playback admitted after force close failed")
        } catch let error as MediaTransportError {
            XCTAssertEqual(error, .resourceBusy)
        }

        let replacement = try await arbiter.acquireScanner(resource: FakeScannerResource())
        replacement.finish()
    }

    // MARK: - shutdownAndDrain (finding A7 primitive)

    func testShutdownAndDrainRejectsNewAdmissionWithNoLeases() async throws {
        let arbiter = MediaIOArbiter(accountID: "shutdown-empty")
        // No scanner and no lease: retirement completes immediately.
        await arbiter.shutdownAndDrain()

        let permits = await arbiter.permitsBackgroundWork()
        XCTAssertFalse(permits, "a retired arbiter permits no background work")
        do {
            _ = try await arbiter.acquireScanner(resource: FakeScannerResource())
            XCTFail("a retired arbiter must reject scanner admission")
        } catch let error as MediaTransportError {
            XCTAssertEqual(error, .resourceBusy)
        }
        do {
            _ = try await arbiter.acquirePlayback()
            XCTFail("a retired arbiter must reject playback admission")
        } catch let error as MediaTransportError {
            XCTAssertEqual(error, .resourceBusy)
        }
    }

    func testShutdownAndDrainDrainsActiveScanner() async throws {
        let arbiter = MediaIOArbiter(
            accountID: "shutdown-scanner",
            deadline: FakeDrainDeadline(drains: true)
        )
        let resource = FakeScannerResource()
        let lease = try await arbiter.acquireScanner(resource: resource)

        await arbiter.shutdownAndDrain()

        XCTAssertEqual(resource.cancelCount, 1, "retirement drains the active scanner")
        let permits = await arbiter.permitsBackgroundWork()
        XCTAssertFalse(permits)
        lease.finish() // a stale finish after retirement is harmless
    }

    func testShutdownAndDrainWaitsForHeldPlaybackLease() async throws {
        let arbiter = MediaIOArbiter(accountID: "shutdown-lease")
        let lease = try await arbiter.acquirePlayback()

        let done = ShutdownDoneFlag()
        let shutdown = Task {
            await arbiter.shutdownAndDrain()
            done.set()
        }

        // The live lease keeps retirement pending, but new admission is already rejected.
        try? await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertFalse(done.isSet, "retirement must wait for the held playback lease to drain")
        do {
            _ = try await arbiter.acquirePlayback()
            XCTFail("a shutting-down arbiter must reject new playback admission")
        } catch let error as MediaTransportError {
            XCTAssertEqual(error, .resourceBusy)
        }

        await lease.releaseAndWait()
        await shutdown.value
        XCTAssertTrue(done.isSet, "retirement completes once the final lease drains")
    }

    // MARK: - shutdownAndDrain vs. in-flight admission races (Batch 3 follow-up)

    func testShutdownDuringScannerReplacementDrainRejectsInstallation() async throws {
        // Scanner A active; replacement B suspended mid-drain of A. Retirement begins
        // while B is draining. When the drain releases, B must observe the retirement at
        // its post-drain installation guard and throw resourceBusy — it must NOT install
        // a scanner after shutdown began, or the coordinator would drop a live arbiter.
        let drainGate = AsyncTestGate()
        let arbiter = MediaIOArbiter(
            accountID: "shutdown-vs-scanner",
            deadline: ControlledDrainDeadline(results: [true], gate: drainGate)
        )
        let firstResource = FakeScannerResource()
        let first = try await arbiter.acquireScanner(resource: firstResource)
        let secondResource = FakeScannerResource()
        let replacement = Task {
            try await arbiter.acquireScanner(resource: secondResource)
        }
        // Wait until B is inside the drain-verification of A (blocked on the gate).
        await drainGate.waitUntilEntered()

        // Retire the arbiter while B is mid-drain, then wait until the flag is set so the
        // gate release is deterministically observed after shutdown began.
        let done = ShutdownDoneFlag()
        let shutdown = Task {
            await arbiter.shutdownAndDrain()
            done.set()
        }
        _ = await waitUntilAsync { await arbiter.isRetired() }

        // Releasing A's drain lets B reach its post-drain guard, which now sees shutdown.
        drainGate.open()

        do {
            _ = try await replacement.value
            XCTFail("scanner replacement installed after retirement began")
        } catch let error as MediaTransportError {
            XCTAssertEqual(error, .resourceBusy)
        }
        await shutdown.value
        XCTAssertTrue(done.isSet)
        let permits = await arbiter.permitsBackgroundWork()
        XCTAssertFalse(permits, "no scanner may remain admitted after retirement")
        do {
            _ = try await arbiter.acquireScanner(resource: FakeScannerResource())
            XCTFail("a retired arbiter must reject fresh scanner admission")
        } catch let error as MediaTransportError {
            XCTAssertEqual(error, .resourceBusy)
        }
        _ = first
    }

    func testShutdownWaitsForReservationBlockedBehindTransition() async throws {
        // A playback reservation is parked behind an in-progress scanner transition when
        // retirement begins. Retirement must NOT return while that reservation is still
        // mid-admission; the reservation must be rejected (no lease); only then may
        // shutdown complete.
        let drainGate = AsyncTestGate()
        let arbiter = MediaIOArbiter(
            accountID: "shutdown-vs-reservation",
            deadline: ControlledDrainDeadline(results: [true], gate: drainGate)
        )
        let firstResource = FakeScannerResource()
        let first = try await arbiter.acquireScanner(resource: firstResource)
        let replacement = Task {
            try await arbiter.acquireScanner(resource: FakeScannerResource())
        }
        await drainGate.waitUntilEntered()

        // Reservation R parks behind the in-progress transition.
        let reservation = Task { try await arbiter.acquirePlayback() }
        _ = await waitUntilAsync { await arbiter.pendingPlaybackReservations() == 1 }

        let done = ShutdownDoneFlag()
        let shutdown = Task {
            await arbiter.shutdownAndDrain()
            done.set()
        }
        _ = await waitUntilAsync { await arbiter.isRetired() }

        // While the reservation is still parked, retirement cannot have completed.
        try? await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertFalse(done.isSet, "retirement must not return while a reservation is in-flight")

        // Release the transition: the replacement yields, the reservation is rejected,
        // and only then does retirement complete.
        drainGate.open()

        do {
            _ = try await reservation.value
            XCTFail("a reservation must not be granted a lease after retirement began")
        } catch let error as MediaTransportError {
            XCTAssertEqual(error, .resourceBusy)
        }
        do {
            _ = try await replacement.value
            XCTFail("scanner replacement installed after retirement began")
        } catch let error as MediaTransportError {
            XCTAssertEqual(error, .resourceBusy)
        }
        await shutdown.value
        XCTAssertTrue(done.isSet, "retirement completes once the reservation exits")
        let pending = await arbiter.pendingPlaybackReservations()
        XCTAssertEqual(pending, 0)
        _ = first
    }

    func testShutdownWithMultipleReservationsAndCancellationLeavesCleanCounts() async throws {
        // Two reservations parked behind a transition; one is cancelled and one is
        // rejected by retirement. Both must exit, the reservation count must return to
        // zero, and a second shutdownAndDrain() must be idempotent (no leaked waiter).
        let drainGate = AsyncTestGate()
        let arbiter = MediaIOArbiter(
            accountID: "shutdown-multi-reservation",
            deadline: ControlledDrainDeadline(results: [true], gate: drainGate)
        )
        let firstResource = FakeScannerResource()
        let first = try await arbiter.acquireScanner(resource: firstResource)
        let replacement = Task {
            try await arbiter.acquireScanner(resource: FakeScannerResource())
        }
        await drainGate.waitUntilEntered()

        let cancelled = Task { try await arbiter.acquirePlayback() }
        let rejected = Task { try await arbiter.acquirePlayback() }
        _ = await waitUntilAsync { await arbiter.pendingPlaybackReservations() == 2 }

        let done = ShutdownDoneFlag()
        let shutdown = Task {
            await arbiter.shutdownAndDrain()
            done.set()
        }
        _ = await waitUntilAsync { await arbiter.isRetired() }

        cancelled.cancel()
        drainGate.open()

        do {
            _ = try await cancelled.value
            XCTFail("a cancelled reservation must not be granted a lease")
        } catch is CancellationError {
            // expected
        } catch let error as MediaTransportError {
            // A teardown-timing race may surface as resourceBusy; either is a clean exit.
            XCTAssertEqual(error, .resourceBusy)
        }
        do {
            _ = try await rejected.value
            XCTFail("a reservation must not be granted a lease after retirement began")
        } catch let error as MediaTransportError {
            XCTAssertEqual(error, .resourceBusy)
        }
        _ = try? await replacement.value
        await shutdown.value

        XCTAssertTrue(done.isSet)
        let pending = await arbiter.pendingPlaybackReservations()
        XCTAssertEqual(pending, 0, "all reservation counts released")
        // Idempotent: a second retirement returns immediately with no leaked waiter.
        await arbiter.shutdownAndDrain()
        _ = first
    }
}

/// Thread-safe completion flag for the concurrent shutdown-drain test.
private final class ShutdownDoneFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}
