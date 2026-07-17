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

    func testPreferredBacklogRunsFirstAndOtherProfilesEventuallyRun() async {
        let recorder = Recorder()
        let gate = Gate()
        let scheduler = ShareMetadataWorkScheduler(configuration: .init(
            maxItemsPerSlice: 1,
            maxSliceDuration: .seconds(1),
            delayBetweenSlices: .milliseconds(1),
            interactiveIdleDelay: .milliseconds(1),
            blockedPollDelay: .milliseconds(1)
        ))
        await scheduler.setPreferredAccountKeys(["active"])

        for account in ["inactive", "active"] {
            await scheduler.register(
                accountKey: account,
                mayRun: { await gate.isOpen },
                runSlice: { _, _ in
                    await recorder.begin(account)
                    await recorder.end()
                    let call = await recorder.nextSlice(account)
                    return ShareEnrichmentSliceResult(
                        attempted: 1,
                        hasMore: account == "active" && call < 2
                    )
                },
                runItem: { _ in }
            )
        }

        await scheduler.enqueueBacklog(accountKey: "inactive")
        await scheduler.enqueueBacklog(accountKey: "active")
        await gate.open()

        let finished = await waitUntil {
            (await recorder.events).count == 3
        }
        XCTAssertTrue(finished)
        let events = await recorder.events
        XCTAssertEqual(events.first, "active")
        XCTAssertEqual(events.filter { $0 == "active" }.count, 2)
        XCTAssertEqual(events.filter { $0 == "inactive" }.count, 1)
    }

    func testBlockedPreferredBacklogFallsBackToOtherProfile() async {
        let recorder = Recorder()
        let scheduler = ShareMetadataWorkScheduler(configuration: .init(
            maxItemsPerSlice: 1,
            maxSliceDuration: .seconds(1),
            delayBetweenSlices: .milliseconds(1),
            interactiveIdleDelay: .milliseconds(1),
            blockedPollDelay: .milliseconds(1)
        ))
        await scheduler.setPreferredAccountKeys(["active"])
        await scheduler.register(
            accountKey: "active",
            mayRun: { false },
            runSlice: { _, _ in
                await recorder.begin("active")
                await recorder.end()
                return ShareEnrichmentSliceResult(attempted: 1, hasMore: false)
            },
            runItem: { _ in }
        )
        await scheduler.register(
            accountKey: "inactive",
            mayRun: { true },
            runSlice: { _, _ in
                await recorder.begin("inactive")
                await recorder.end()
                return ShareEnrichmentSliceResult(attempted: 1, hasMore: false)
            },
            runItem: { _ in }
        )

        await scheduler.enqueueBacklog(accountKey: "active")
        await scheduler.enqueueBacklog(accountKey: "inactive")

        let finished = await waitUntil {
            (await recorder.events) == ["inactive"]
        }
        XCTAssertTrue(finished)
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

    // MARK: - A3: stale work discarded on replacement DURING admission (no requeue)

    /// Regression for finding A3: work taken from the queue and suspended inside
    /// `mayRun` must be DISCARDED — never requeued into or run under — a replacement
    /// registration that received no new enqueue. The existing test above covers the
    /// running path AND enqueues fresh work; this covers the dequeue/admission gap
    /// with NO new enqueue, so a passing result proves the replacement stays idle.
    func testStaleBacklogDiscardedWhenRegistrationReplacedDuringAdmission() async {
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
                await recorder.begin("old")
                await recorder.end()
                return .init(attempted: 1, hasMore: false)
            },
            runItem: { _ in }
        )
        await scheduler.enqueueBacklog(accountKey: "a")
        // Old backlog work is now taken and suspended inside `mayRun`.
        await gate.waitUntilFirstCallStarts()

        // Replace the registration with NO new enqueue.
        await scheduler.remove(accountKey: "a")
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
        // Let the suspended admission resume and the worker settle.
        await gate.releaseFirstCall()
        try? await Task.sleep(for: .milliseconds(60))

        let events = await recorder.events
        let snapshot = await scheduler.snapshot()
        await scheduler.remove(accountKey: "a")

        XCTAssertFalse(events.contains("old"), "stale work must not run under the replacement")
        XCTAssertFalse(
            events.contains("new"),
            "a replacement with no new enqueue must not inherit stale queued work"
        )
        XCTAssertEqual(snapshot.queuedBacklogs, 0, "stale work must be discarded, not requeued")
    }

    /// The same gap for urgent opened-item work: a taken+suspended urgent item must
    /// not requeue into a replacement registration that never re-enqueued it.
    func testStaleUrgentItemDiscardedWhenRegistrationReplacedDuringAdmission() async {
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
            runSlice: { _, _ in .init(attempted: 0, hasMore: false) },
            runItem: { itemID in
                await recorder.begin("old-item-\(itemID)")
                await recorder.end()
            }
        )
        await scheduler.enqueueItem(accountKey: "a", itemID: "x")
        await gate.waitUntilFirstCallStarts()

        await scheduler.remove(accountKey: "a")
        await scheduler.register(
            accountKey: "a",
            mayRun: { true },
            runSlice: { _, _ in .init(attempted: 0, hasMore: false) },
            runItem: { itemID in
                await recorder.begin("new-item-\(itemID)")
                await recorder.end()
            }
        )
        await gate.releaseFirstCall()
        try? await Task.sleep(for: .milliseconds(60))

        let events = await recorder.events
        let snapshot = await scheduler.snapshot()
        await scheduler.remove(accountKey: "a")

        XCTAssertTrue(events.isEmpty, "no stale urgent item may run under the replacement")
        XCTAssertEqual(snapshot.queuedItems, 0, "stale urgent work must be discarded, not requeued")
    }

    // MARK: - A6: bounded preferred-backlog fairness and aging

    /// Under an INFINITE stream of preferred backlog work, a runnable non-preferred
    /// account must still be admitted within the burst quota — proving the preferred
    /// bias is bounded, not starving. With `delayBetweenSlices: .zero` the preferred
    /// account is continuously admissible, so pure preferred-first ordering would run
    /// it forever and never admit the non-preferred account.
    func testNonPreferredBacklogAdmittedWithinBurstQuotaUnderInfinitePreferred() async {
        let recorder = Recorder()
        let scheduler = ShareMetadataWorkScheduler(configuration: .init(
            maxItemsPerSlice: 1,
            maxSliceDuration: .seconds(1),
            delayBetweenSlices: .zero,
            interactiveIdleDelay: .milliseconds(1),
            blockedPollDelay: .milliseconds(1),
            preferredBacklogBurst: 2,
            nonPreferredAgePromotion: .seconds(1000)
        ))
        await scheduler.setPreferredAccountKeys(["p"])
        await scheduler.register(
            accountKey: "p",
            mayRun: { true },
            runSlice: { _, _ in
                await recorder.begin("p")
                await recorder.end()
                return .init(attempted: 1, hasMore: true)
            },
            runItem: { _ in }
        )
        await scheduler.register(
            accountKey: "n",
            mayRun: { true },
            runSlice: { _, _ in
                await recorder.begin("n")
                await recorder.end()
                return .init(attempted: 1, hasMore: false)
            },
            runItem: { _ in }
        )
        await scheduler.enqueueBacklog(accountKey: "p")
        await scheduler.enqueueBacklog(accountKey: "n")

        let admitted = await waitUntil {
            (await recorder.events).contains("n")
        }
        let events = await recorder.events
        await scheduler.remove(accountKey: "p")
        await scheduler.remove(accountKey: "n")

        XCTAssertTrue(admitted, "a runnable non-preferred account must not be starved")
        XCTAssertEqual(
            Array(events.prefix(3)), ["p", "p", "n"],
            "preferred bias runs the burst, then admits one non-preferred account"
        )
    }

    /// Independently of the burst counter, a long-waiting non-preferred account is
    /// promoted by age. Burst is set impossibly high so ONLY aging can surface it.
    func testAgedNonPreferredBacklogRunsUnderSteadyPreferred() async {
        let recorder = Recorder()
        let scheduler = ShareMetadataWorkScheduler(configuration: .init(
            maxItemsPerSlice: 1,
            maxSliceDuration: .seconds(1),
            delayBetweenSlices: .zero,
            interactiveIdleDelay: .milliseconds(1),
            blockedPollDelay: .milliseconds(1),
            preferredBacklogBurst: 100_000,
            nonPreferredAgePromotion: .milliseconds(30)
        ))
        await scheduler.setPreferredAccountKeys(["p"])
        await scheduler.register(
            accountKey: "p",
            mayRun: { true },
            runSlice: { _, _ in
                await recorder.begin("p")
                await recorder.end()
                return .init(attempted: 1, hasMore: true)
            },
            runItem: { _ in }
        )
        await scheduler.register(
            accountKey: "n",
            mayRun: { true },
            runSlice: { _, _ in
                await recorder.begin("n")
                await recorder.end()
                return .init(attempted: 1, hasMore: false)
            },
            runItem: { _ in }
        )
        await scheduler.enqueueBacklog(accountKey: "p")
        await scheduler.enqueueBacklog(accountKey: "n")

        let promoted = await waitUntil {
            (await recorder.events).contains("n")
        }
        let events = await recorder.events
        await scheduler.remove(accountKey: "p")
        await scheduler.remove(accountKey: "n")

        XCTAssertTrue(promoted, "an aged non-preferred account must eventually run")
        let firstNonPreferred = events.firstIndex(of: "n") ?? 0
        XCTAssertGreaterThanOrEqual(
            firstNonPreferred, 1,
            "aging promotes only after a wait, so preferred work runs first"
        )
    }

    /// A blocked (non-runnable) non-preferred account surfaced by the burst quota
    /// must NOT consume that quota: its failed admission leaves the counter intact,
    /// so preferred work keeps making progress and is never stalled by the block.
    func testBlockedNonPreferredCannotConsumePreferredBurstQuota() async {
        let recorder = Recorder()
        let scheduler = ShareMetadataWorkScheduler(configuration: .init(
            maxItemsPerSlice: 1,
            maxSliceDuration: .seconds(1),
            delayBetweenSlices: .zero,
            interactiveIdleDelay: .milliseconds(1),
            blockedPollDelay: .milliseconds(1),
            preferredBacklogBurst: 2,
            nonPreferredAgePromotion: .seconds(1000)
        ))
        await scheduler.setPreferredAccountKeys(["p"])
        await scheduler.register(
            accountKey: "p",
            mayRun: { true },
            runSlice: { _, _ in
                await recorder.begin("p")
                await recorder.end()
                return .init(attempted: 1, hasMore: true)
            },
            runItem: { _ in }
        )
        await scheduler.register(
            accountKey: "n",
            mayRun: { false },
            runSlice: { _, _ in
                await recorder.begin("n")
                await recorder.end()
                return .init(attempted: 1, hasMore: false)
            },
            runItem: { _ in }
        )
        await scheduler.enqueueBacklog(accountKey: "p")
        await scheduler.enqueueBacklog(accountKey: "n")

        let progressed = await waitUntil {
            (await recorder.events).filter { $0 == "p" }.count >= 5
        }
        let events = await recorder.events
        await scheduler.remove(accountKey: "p")
        await scheduler.remove(accountKey: "n")

        XCTAssertTrue(progressed, "a blocked non-preferred account must not stall preferred progress")
        XCTAssertEqual(events.filter { $0 == "n" }.count, 0, "the blocked account never runs")
    }
}
