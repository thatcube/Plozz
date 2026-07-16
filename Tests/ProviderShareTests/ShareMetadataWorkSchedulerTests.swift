import XCTest
@testable import ProviderShare

final class ShareMetadataWorkSchedulerTests: XCTestCase {
    private actor Recorder {
        var events: [String] = []
        var active = 0
        var maxActive = 0
        var sliceCalls: [String: Int] = [:]
        var cancelled = 0

        func begin(_ event: String) {
            events.append(event)
            active += 1
            maxActive = max(maxActive, active)
        }

        func end() {
            active -= 1
        }

        func nextSlice(_ account: String) -> Int {
            let next = (sliceCalls[account] ?? 0) + 1
            sliceCalls[account] = next
            return next
        }

        func noteCancelled() {
            cancelled += 1
        }
    }

    private actor Gate {
        var isOpen = false
        func open() { isOpen = true }
    }

    private actor AdmissionGate {
        private var isFirstCall = true
        private var firstCallStarted = false
        private var firstCallContinuation: CheckedContinuation<Void, Never>?
        private var startWaiters: [CheckedContinuation<Void, Never>] = []
        private var laterCallsAllowed = false

        func mayRun() async -> Bool {
            if isFirstCall {
                isFirstCall = false
                firstCallStarted = true
                let waiters = startWaiters
                startWaiters.removeAll()
                waiters.forEach { $0.resume() }
                await withCheckedContinuation { continuation in
                    firstCallContinuation = continuation
                }
                return true
            }
            return laterCallsAllowed
        }

        func waitUntilFirstCallStarts() async {
            guard !firstCallStarted else { return }
            await withCheckedContinuation { continuation in
                startWaiters.append(continuation)
            }
        }

        func releaseFirstCall() {
            firstCallContinuation?.resume()
            firstCallContinuation = nil
        }

        func allowLaterCalls() {
            laterCallsAllowed = true
        }
    }

    private actor WorkGate {
        private var started = false
        private var continuation: CheckedContinuation<Void, Never>?
        private var startWaiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            started = true
            let waiters = startWaiters
            startWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { continuation = $0 }
        }

        func waitUntilStarted() async {
            guard !started else { return }
            await withCheckedContinuation { startWaiters.append($0) }
        }

        func open() {
            continuation?.resume()
            continuation = nil
        }
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ predicate: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await predicate() { return true }
            try? await clock.sleep(for: .milliseconds(5))
        }
        return await predicate()
    }

    func testBacklogSlicesAreSerializedAcrossAccounts() async {
        let recorder = Recorder()
        let scheduler = ShareMetadataWorkScheduler(configuration: .init(
            maxItemsPerSlice: 3,
            maxSliceDuration: .milliseconds(50),
            delayBetweenSlices: .milliseconds(1),
            interactiveIdleDelay: .milliseconds(10),
            blockedPollDelay: .milliseconds(1)
        ))

        for account in ["a", "b"] {
            await scheduler.register(
                accountKey: account,
                mayRun: { true },
                runSlice: { _, _ in
                    await recorder.begin("slice-\(account)")
                    try? await Task.sleep(for: .milliseconds(10))
                    await recorder.end()
                    let call = await recorder.nextSlice(account)
                    return ShareEnrichmentSliceResult(attempted: 1, hasMore: call < 2)
                },
                runItem: { _ in }
            )
        }

        await scheduler.enqueueBacklog(accountKey: "a")
        await scheduler.enqueueBacklog(accountKey: "b")
        let finished = await waitUntil {
            let snapshot = await scheduler.snapshot()
            let calls = await recorder.sliceCalls
            return snapshot.queuedBacklogs == 0
                && snapshot.runningAccountKey == nil
                && calls["a"] == 2
                && calls["b"] == 2
        }

        XCTAssertTrue(finished)
        let maxActive = await recorder.maxActive
        XCTAssertEqual(maxActive, 1)
    }

    func testOpenedItemJumpsAheadOfBlockedBacklog() async {
        let recorder = Recorder()
        let gate = Gate()
        let scheduler = ShareMetadataWorkScheduler(configuration: .init(
            maxItemsPerSlice: 1,
            maxSliceDuration: .seconds(1),
            delayBetweenSlices: .milliseconds(1),
            interactiveIdleDelay: .milliseconds(1),
            blockedPollDelay: .milliseconds(1)
        ))
        await scheduler.register(
            accountKey: "a",
            mayRun: { await gate.isOpen },
            runSlice: { _, _ in
                await recorder.begin("backlog")
                await recorder.end()
                return ShareEnrichmentSliceResult(attempted: 1, hasMore: false)
            },
            runItem: { itemID in
                await recorder.begin("item-\(itemID)")
                await recorder.end()
            }
        )

        await scheduler.enqueueBacklog(accountKey: "a")
        await scheduler.enqueueItem(accountKey: "a", itemID: "opened")
        await gate.open()
        let finished = await waitUntil {
            (await recorder.events).count == 2
        }

        XCTAssertTrue(finished)
        let events = await recorder.events
        XCTAssertEqual(events, ["item-opened", "backlog"])
    }

    func testInteractiveActivityCancelsCurrentBacklogSlice() async {
        let recorder = Recorder()
        let scheduler = ShareMetadataWorkScheduler(configuration: .init(
            maxItemsPerSlice: 10,
            maxSliceDuration: .seconds(2),
            delayBetweenSlices: .milliseconds(1),
            interactiveIdleDelay: .seconds(1),
            blockedPollDelay: .milliseconds(1)
        ))
        await scheduler.register(
            accountKey: "a",
            mayRun: { true },
            runSlice: { _, _ in
                await recorder.begin("slice")
                do {
                    try await Task.sleep(for: .seconds(5))
                } catch {
                    await recorder.noteCancelled()
                }
                await recorder.end()
                return ShareEnrichmentSliceResult(attempted: 0, hasMore: true)
            },
            runItem: { _ in }
        )

        await scheduler.enqueueBacklog(accountKey: "a")
        let started = await waitUntil { await recorder.active == 1 }
        XCTAssertTrue(started)
        await scheduler.noteInteractiveActivity(accountKey: "a")
        let cancelled = await waitUntil { await recorder.cancelled == 1 }
        await scheduler.remove(accountKey: "a")

        XCTAssertTrue(cancelled)
    }

    func testInterruptInvalidatesAdmissionAlreadyInFlight() async {
        let recorder = Recorder()
        let gate = AdmissionGate()
        let scheduler = ShareMetadataWorkScheduler(configuration: .init(
            maxItemsPerSlice: 1,
            maxSliceDuration: .seconds(1),
            delayBetweenSlices: .milliseconds(1),
            interactiveIdleDelay: .milliseconds(1),
            blockedPollDelay: .milliseconds(1)
        ))
        await scheduler.register(
            accountKey: "a",
            mayRun: { await gate.mayRun() },
            runSlice: { _, _ in
                await recorder.begin("slice")
                await recorder.end()
                return .init(attempted: 1, hasMore: false)
            },
            runItem: { _ in }
        )

        await scheduler.enqueueBacklog(accountKey: "a")
        await gate.waitUntilFirstCallStarts()
        await scheduler.interrupt(accountKey: "a")
        await gate.releaseFirstCall()
        try? await Task.sleep(for: .milliseconds(30))
        let beforeRecovery = await recorder.events
        XCTAssertTrue(beforeRecovery.isEmpty, "stale admission must not start work")

        await gate.allowLaterCalls()
        let recovered = await waitUntil { (await recorder.events).count == 1 }
        await scheduler.remove(accountKey: "a")
        XCTAssertTrue(recovered)
    }

    func testSuspensionBlocksRetryAcrossAdmissionTransition() async {
        let recorder = Recorder()
        let gate = AdmissionGate()
        let scheduler = ShareMetadataWorkScheduler(configuration: .init(
            maxItemsPerSlice: 1,
            maxSliceDuration: .seconds(1),
            delayBetweenSlices: .milliseconds(1),
            interactiveIdleDelay: .milliseconds(1),
            blockedPollDelay: .milliseconds(1)
        ))
        await scheduler.register(
            accountKey: "a",
            mayRun: { await gate.mayRun() },
            runSlice: { _, _ in
                await recorder.begin("slice")
                await recorder.end()
                return .init(attempted: 1, hasMore: false)
            },
            runItem: { _ in }
        )

        await scheduler.enqueueBacklog(accountKey: "a")
        await gate.waitUntilFirstCallStarts()
        await scheduler.suspend(accountKey: "a")
        await gate.allowLaterCalls()
        await gate.releaseFirstCall()
        try? await Task.sleep(for: .milliseconds(30))
        let whileSuspended = await recorder.events
        XCTAssertTrue(whileSuspended.isEmpty)

        await scheduler.resume(accountKey: "a")
        let resumed = await waitUntil { (await recorder.events).count == 1 }
        await scheduler.remove(accountKey: "a")
        XCTAssertTrue(resumed)
    }

    func testRemovalInvalidatesAdmissionAndWaitsForRunningWork() async {
        let recorder = Recorder()
        let gate = AdmissionGate()
        let scheduler = ShareMetadataWorkScheduler(configuration: .init(
            maxItemsPerSlice: 1,
            maxSliceDuration: .seconds(1),
            delayBetweenSlices: .milliseconds(1),
            interactiveIdleDelay: .milliseconds(1),
            blockedPollDelay: .milliseconds(1)
        ))
        await scheduler.register(
            accountKey: "a",
            mayRun: { await gate.mayRun() },
            runSlice: { _, _ in
                await recorder.begin("slice")
                try? await Task.sleep(for: .seconds(5))
                await recorder.end()
                return .init(attempted: 0, hasMore: true)
            },
            runItem: { _ in }
        )

        await scheduler.enqueueBacklog(accountKey: "a")
        await gate.waitUntilFirstCallStarts()
        let removal = Task { await scheduler.remove(accountKey: "a") }
        await gate.allowLaterCalls()
        await gate.releaseFirstCall()
        await removal.value
        try? await Task.sleep(for: .milliseconds(30))

        let events = await recorder.events
        let snapshot = await scheduler.snapshot()
        XCTAssertTrue(events.isEmpty)
        XCTAssertNil(snapshot.runningAccountKey)
        XCTAssertEqual(snapshot.queuedBacklogs, 0)
    }

    func testRemovedWorkCannotRequeueIntoReplacementRegistration() async {
        let recorder = Recorder()
        let gate = WorkGate()
        let scheduler = ShareMetadataWorkScheduler(configuration: .init(
            maxItemsPerSlice: 1,
            maxSliceDuration: .seconds(1),
            delayBetweenSlices: .milliseconds(1),
            interactiveIdleDelay: .milliseconds(1),
            blockedPollDelay: .milliseconds(1)
        ))
        await scheduler.register(
            accountKey: "a",
            mayRun: { true },
            runSlice: { _, _ in
                await recorder.begin("old")
                await gate.wait()
                await recorder.end()
                return .init(attempted: 0, hasMore: true)
            },
            runItem: { _ in }
        )
        await scheduler.enqueueBacklog(accountKey: "a")
        await gate.waitUntilStarted()

        let removal = Task { await scheduler.remove(accountKey: "a") }
        try? await Task.sleep(for: .milliseconds(10))
        await scheduler.register(
            accountKey: "a",
            mayRun: { true },
            runSlice: { _, _ in
                await recorder.begin("new")
                await recorder.end()
                return .init(attempted: 1, hasMore: false)
            },
            runItem: { _ in }
        )
        await scheduler.enqueueBacklog(accountKey: "a")
        await gate.open()
        await removal.value
        let replacementRan = await waitUntil {
            (await recorder.events).filter { $0 == "new" }.count == 1
        }
        try? await Task.sleep(for: .milliseconds(20))
        let events = await recorder.events
        await scheduler.remove(accountKey: "a")

        XCTAssertTrue(replacementRan)
        XCTAssertEqual(events.filter { $0 == "new" }.count, 1)
    }
}
