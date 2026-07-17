import XCTest
@testable import ProviderShare
import MediaTransportCore

/// Coverage for `ShareScannerResource`, the `MediaIOScannerResource` the arbiter
/// drives to stop a superseded scan. The critical invariant: `forceClose()` must
/// reach active lister closure (the operation that actually tears down in-flight
/// transport I/O) even when the graceful-cancel dependency — scan-generation
/// invalidation on the store — is blocked/hung. If `forceClose()` awaited the same
/// cancel path first, a hung invalidation would prevent lister closure entirely.
final class ShareScannerResourceTests: XCTestCase {
    /// A generation invalidator whose call blocks until a gate opens, simulating a
    /// hung/cancellation-insensitive graceful-cancel dependency (e.g. a store actor
    /// saturated by an in-flight operation).
    private final class BlockingInvalidator: ScanGenerationInvalidating, @unchecked Sendable {
        private let lock = NSLock()
        private var entered = false
        private var opened = false
        private var callCount = 0
        private var enterWaiters: [CheckedContinuation<Void, Never>] = []
        private var openWaiters: [CheckedContinuation<Void, Never>] = []

        var invalidateCount: Int { lock.withLock { callCount } }

        func invalidateScanGeneration() async {
            let enterWaiters: [CheckedContinuation<Void, Never>] = lock.withLock {
                callCount += 1
                entered = true
                let waiters = self.enterWaiters
                self.enterWaiters.removeAll()
                return waiters
            }
            enterWaiters.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                let isOpen = lock.withLock { () -> Bool in
                    guard !opened else { return true }
                    openWaiters.append(continuation)
                    return false
                }
                if isOpen { continuation.resume() }
            }
        }

        func waitUntilEntered() async {
            await withCheckedContinuation { continuation in
                let hasEntered = lock.withLock { () -> Bool in
                    guard !entered else { return true }
                    enterWaiters.append(continuation)
                    return false
                }
                if hasEntered { continuation.resume() }
            }
        }

        func open() {
            let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
                opened = true
                let waiters = openWaiters
                openWaiters.removeAll()
                return waiters
            }
            waiters.forEach { $0.resume() }
        }
    }

    private final class RecordingListerCloser: ScanListerForceClosing, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var closeCount: Int { lock.withLock { count } }

        func forceCloseActiveListers() async {
            lock.withLock { count += 1 }
        }
    }

    func testForceCloseReachesListerClosureDespiteBlockedInvalidator() async throws {
        let invalidator = BlockingInvalidator()
        let closer = RecordingListerCloser()
        let resource = ShareScannerResource(scanner: closer, store: invalidator)

        // A graceful cancel that blocks inside the invalidator, mirroring the hung
        // store dependency the arbiter would otherwise inherit through `forceClose()`.
        let cancelTask = Task { await resource.cancel() }
        await invalidator.waitUntilEntered()

        // Force-close runs while the graceful-cancel dependency is still blocked. It
        // must reach active lister closure and mark drained without first awaiting
        // that dependency.
        let forceCloseTask = Task { try await resource.forceClose() }

        let reachedClosure = await waitUntilTrue { closer.closeCount >= 1 }
        XCTAssertTrue(
            reachedClosure,
            "force-close did not reach active lister closure while graceful cancel was blocked"
        )
        let markedDrained = await waitUntilTrue { resource.isDrained }
        XCTAssertTrue(
            markedDrained,
            "force-close should mark drained after closing listers, before its own invalidation"
        )
        XCTAssertEqual(closer.closeCount, 1)

        // Release the blocked dependency so both tasks finish cleanly.
        invalidator.open()
        await cancelTask.value
        try await forceCloseTask.value
        // Idempotent bookkeeping: cancel + force-close each invalidate exactly once.
        XCTAssertEqual(invalidator.invalidateCount, 2)
        XCTAssertEqual(closer.closeCount, 1)
    }

    func testForceCloseCancelsInFlightScanTaskSynchronously() async throws {
        let invalidator = BlockingInvalidator()
        let closer = RecordingListerCloser()
        let resource = ShareScannerResource(scanner: closer, store: invalidator)

        let observedCancellation = CancellationProbe()
        let scanTask = Task {
            // Runs until the resource cancels it. No dependency on the invalidator.
            while !Task.isCancelled {
                await Task.yield()
            }
            observedCancellation.mark()
        }
        resource.attach(scanTask)

        let forceCloseTask = Task { try await resource.forceClose() }
        let cancelledPromptly = await waitUntilTrue { observedCancellation.isMarked }
        XCTAssertTrue(
            cancelledPromptly,
            "force-close must cancel the in-flight scan task synchronously, independent of the blocked invalidator"
        )

        invalidator.open()
        await scanTask.value
        try await forceCloseTask.value
    }

    private final class CancellationProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var marked = false
        var isMarked: Bool { lock.withLock { marked } }
        func mark() { lock.withLock { marked = true } }
    }

    private func waitUntilTrue(
        iterations: Int = 2_000,
        _ predicate: @Sendable () -> Bool
    ) async -> Bool {
        for _ in 0..<iterations {
            if predicate() { return true }
            await Task.yield()
        }
        return predicate()
    }
}
