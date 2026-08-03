import CoreModels
import XCTest
@testable import FeatureWatchlistCore

final class WatchlistReconcilerTests: XCTestCase {
    func testAddRemoveAddCoalescesToLatestDesiredState() async throws {
        let fixture = try makeFixture()
        let target = makeTarget()
        try await fixture.store.enqueue(
            profileID: "p",
            desiredState: .present,
            target: target,
            destinationID: fixture.destination.id
        )
        try await fixture.store.enqueue(
            profileID: "p",
            desiredState: .absent,
            target: target,
            destinationID: fixture.destination.id
        )
        try await fixture.store.enqueue(
            profileID: "p",
            desiredState: .present,
            target: target,
            destinationID: fixture.destination.id
        )

        let queued = await fixture.store.allMutations()
        XCTAssertEqual(queued.count, 1)
        XCTAssertEqual(queued.first?.desiredState, .present)
        _ = await fixture.reconciler.drain(profileID: "p")
        let applied = await fixture.destination.appliedStates()
        XCTAssertEqual(applied, [.present])
    }

    func testRetryClassificationAndCappedBackoff() {
        let policy = WatchlistRetryPolicy(
            initialDelay: 2,
            maximumDelay: 10,
            jitterFraction: 0
        )
        XCTAssertEqual(
            policy.decision(
                for: WatchlistDestinationError.authenticationRequired,
                attempt: 1
            ).classification,
            .authentication
        )
        XCTAssertEqual(
            policy.decision(
                for: WatchlistDestinationError.unsupportedIdentity,
                attempt: 1
            ).classification,
            .unsupportedIdentity
        )
        XCTAssertEqual(policy.delay(attempt: 20, jitterUnit: 0.5), 10)
        XCTAssertEqual(
            policy.decision(
                for: WatchlistDestinationError.rateLimited(retryAfter: 42),
                attempt: 0
            ).retryDelay,
            42
        )
    }

    func testNativeRemovalReassertsAndExplicitRemovalSuppressesUntilAbsence() async throws {
        let fixture = try makeFixture()
        let alias = makeTarget().aliasID
        let key = WatchlistMutationKey(
            profileID: "p",
            aliasID: alias,
            destinationID: fixture.destination.id
        )

        let nativeRemoval = try await fixture.store.observeNative(
            key: key,
            isPresent: false,
            localDesiredState: .present
        )
        XCTAssertEqual(nativeRemoval, .reassertPresent)

        try await fixture.store.enqueue(
            profileID: "p",
            desiredState: .absent,
            target: makeTarget(aliasID: alias),
            destinationID: fixture.destination.id
        )
        let ignored = try await fixture.store.observeNative(
            key: key,
            isPresent: true,
            localDesiredState: .absent
        )
        XCTAssertEqual(ignored, .ignorePresenceDuringExplicitRemoval)
        let absent = try await fixture.store.observeNative(
            key: key,
            isPresent: false,
            localDesiredState: .absent
        )
        XCTAssertEqual(absent, .confirmedAbsence)
        let added = try await fixture.store.observeNative(
            key: key,
            isPresent: true,
            localDesiredState: .absent
        )
        XCTAssertEqual(added, .nativeAddition)
    }

    func testUnsupportedIdentityWaitsAndLateEvidenceFansOut() async throws {
        let fixture = try makeFixture()
        let alias = MediaAliasID()
        let unresolved = WatchlistMutationTarget(
            aliasID: alias,
            kind: .movie,
            externalIDs: [
                WatchlistExternalID(
                    namespace: .imdb,
                    value: "unresolved"
                )!
            ]
        )!
        try await fixture.reconciler.enqueueFanOut(
            profileID: "p",
            desiredState: .present,
            target: unresolved
        )
        _ = await fixture.reconciler.drain(profileID: "p")
        let waiting = await fixture.store.allMutations()
        XCTAssertEqual(waiting.first?.phase, .waitingForIdentity)

        try await fixture.reconciler.identityEvidenceChanged(
            profileID: "p",
            desiredState: .present,
            target: makeTarget(aliasID: alias)
        )
        _ = await fixture.reconciler.drain(profileID: "p")
        let remaining = await fixture.store.allMutations()
        let applied = await fixture.destination.appliedStates()
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertEqual(applied, [.present])
    }

    func testMutationQueuePersistsCoalescedLatestState() async throws {
        let root = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent(
            "PlozzWatchlistMutationTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("queue.json")
        let destinationID = WatchlistDestinationID(rawValue: "native")!
        let first = try DurableWatchlistMutationStore(
            store: AtomicWatchlistMutationStateStore(fileURL: fileURL)
        )
        let target = makeTarget()
        try await first.enqueue(
            profileID: "p",
            desiredState: .present,
            target: target,
            destinationID: destinationID
        )
        try await first.enqueue(
            profileID: "p",
            desiredState: .absent,
            target: target,
            destinationID: destinationID
        )

        let relaunched = try DurableWatchlistMutationStore(
            store: AtomicWatchlistMutationStateStore(fileURL: fileURL)
        )
        let mutations = await relaunched.allMutations()
        XCTAssertEqual(mutations.count, 1)
        XCTAssertEqual(mutations.first?.desiredState, .absent)
    }

    func testBatchPersistenceAndObservationStateStayBoundedAtScale() async throws {
        for count in [1_000, 10_000] {
            let backing = CountingMutationStateStore()
            let store = try DurableWatchlistMutationStore(store: backing)
            let destinationID = WatchlistDestinationID(rawValue: "native")!
            let requests = (0..<count).map { _ in
                let target = makeTarget()
                return WatchlistMutationEnqueueRequest(
                    profileID: "p",
                    desiredState: .present,
                    target: target,
                    destinationID: destinationID
                )
            }
            try await store.enqueueBatch(requests)
            let mutationCount = await store.allMutations().count
            let reconciliationCount = await store.reconciliationStateCount(
                profileID: "p"
            )
            XCTAssertEqual(backing.saveCount, 1)
            XCTAssertEqual(mutationCount, count)
            XCTAssertEqual(reconciliationCount, 0)

            let irrelevantBacking = CountingMutationStateStore()
            let irrelevant = try DurableWatchlistMutationStore(
                store: irrelevantBacking
            )
            let observations = requests.map {
                WatchlistNativeObservationRequest(
                    key: WatchlistMutationKey(
                        profileID: "p",
                        aliasID: $0.target.aliasID,
                        destinationID: destinationID
                    ),
                    isPresent: false,
                    localDesiredState: .present,
                    isEligibleTarget: false
                )
            }
            _ = try await irrelevant.observeNativeBatch(observations)
            let irrelevantCount = await irrelevant.reconciliationStateCount(
                profileID: "p"
            )
            XCTAssertEqual(irrelevantBacking.saveCount, 0)
            XCTAssertEqual(irrelevantCount, 0)
        }
    }

    func testAbsenceBoundaryBatchPersistsOnceAndPrunesConfirmedState() async throws {
        let backing = CountingMutationStateStore()
        let store = try DurableWatchlistMutationStore(store: backing)
        let destinationID = WatchlistDestinationID(rawValue: "native")!
        let targets = (0..<100).map { _ in makeTarget() }
        try await store.enqueueBatch(targets.map {
            WatchlistMutationEnqueueRequest(
                profileID: "p",
                desiredState: .absent,
                target: $0,
                destinationID: destinationID
            )
        })
        let absent = targets.map {
            WatchlistNativeObservationRequest(
                key: WatchlistMutationKey(
                    profileID: "p",
                    aliasID: $0.aliasID,
                    destinationID: destinationID
                ),
                isPresent: false,
                localDesiredState: .absent,
                isEligibleTarget: true
            )
        }
        _ = try await store.observeNativeBatch(absent)
        let absentCount = await store.reconciliationStateCount(profileID: "p")
        XCTAssertEqual(backing.saveCount, 2)
        XCTAssertEqual(absentCount, 100)

        let present = absent.map {
            WatchlistNativeObservationRequest(
                key: $0.key,
                isPresent: true,
                localDesiredState: .absent,
                isEligibleTarget: true
            )
        }
        _ = try await store.observeNativeBatch(present)
        let presentCount = await store.reconciliationStateCount(profileID: "p")
        XCTAssertEqual(backing.saveCount, 3)
        XCTAssertEqual(presentCount, 0)
    }

    func testTransientRetrySchedulerWakesWithoutUnrelatedAction() async throws {
        let clock = LockedWatchlistClock(
            Date(timeIntervalSince1970: 1_000)
        )
        let destination = RetryingWatchlistDestination(
            failures: [.transient]
        )
        let store = try DurableWatchlistMutationStore(
            store: InMemoryWatchlistMutationStateStore()
        )
        let reconciler = WatchlistReconciler(
            registry: WatchlistDestinationRegistry([destination]),
            mutationStore: store,
            retryPolicy: WatchlistRetryPolicy(
                initialDelay: 2,
                maximumDelay: 2,
                jitterFraction: 0
            )
        )
        try await reconciler.enqueueFanOut(
            profileID: "p",
            desiredState: .present,
            target: makeTarget(),
            now: clock.now()
        )
        _ = await reconciler.drain(profileID: "p", now: clock.now())
        let scheduler = WatchlistRetryScheduler(
            profileID: "p",
            nextAttempt: { profileID in
                await reconciler.earliestNextAttempt(profileID: profileID)
            },
            drain: { profileID, now in
                await reconciler.drainForRetryScheduler(
                    profileID: profileID,
                    now: now
                )
            },
            now: { clock.now() },
            sleeper: { delay in clock.advance(by: delay) }
        )

        await scheduler.reschedule()
        await waitUntil {
            await destination.successCount() == 1
        }

        let transientSuccesses = await destination.successCount()
        XCTAssertEqual(transientSuccesses, 1)
        await scheduler.cancel()
    }

    func testAuthenticationWaitsUntilReconnectThenResumes() async throws {
        let clock = LockedWatchlistClock(
            Date(timeIntervalSince1970: 2_000)
        )
        let sleeps = LockedWatchlistCounter()
        let destination = RetryingWatchlistDestination(
            failures: [.authenticationRequired]
        )
        let store = try DurableWatchlistMutationStore(
            store: InMemoryWatchlistMutationStateStore()
        )
        let reconciler = WatchlistReconciler(
            registry: WatchlistDestinationRegistry([destination]),
            mutationStore: store
        )
        try await reconciler.enqueueFanOut(
            profileID: "p",
            desiredState: .present,
            target: makeTarget(),
            now: clock.now()
        )
        _ = await reconciler.drain(profileID: "p", now: clock.now())
        let scheduler = WatchlistRetryScheduler(
            profileID: "p",
            nextAttempt: { profileID in
                await reconciler.earliestNextAttempt(profileID: profileID)
            },
            drain: { profileID, now in
                await reconciler.drainForRetryScheduler(
                    profileID: profileID,
                    now: now
                )
            },
            now: { clock.now() },
            sleeper: { delay in
                sleeps.increment()
                clock.advance(by: delay)
            }
        )
        await scheduler.reschedule()
        await Task.yield()
        let successesBeforeReconnect = await destination.successCount()
        XCTAssertEqual(sleeps.value, 0)
        XCTAssertEqual(successesBeforeReconnect, 0)

        _ = try await reconciler.resumeAuthentication()
        await scheduler.reschedule()
        await waitUntil {
            await destination.successCount() == 1
        }

        let successesAfterReconnect = await destination.successCount()
        XCTAssertEqual(successesAfterReconnect, 1)
        await scheduler.cancel()
    }

    func testSchedulerCancellationPreventsOldProfileWake() async {
        let drains = LockedWatchlistCounter()
        let now = Date()
        let scheduler = WatchlistRetryScheduler(
            profileID: "old",
            nextAttempt: { _ in now.addingTimeInterval(60) },
            drain: { _, _ in
                drains.increment()
                return .completed
            }
        )
        await scheduler.reschedule()
        await scheduler.cancel()
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(drains.value, 0)
    }

    func testSchedulerBacksOffWhenProfileDrainIsBusy() async {
        let contention = LockedWatchlistContention()
        let delays = LockedWatchlistDelays()
        let scheduler = WatchlistRetryScheduler(
            profileID: "p",
            nextAttempt: { _ in
                contention.hasQueuedMutation ? .distantPast : nil
            },
            drain: { _, _ in contention.drain() },
            minimumContentionDelay: 0.25,
            sleeper: { delay in delays.append(delay) }
        )

        await scheduler.reschedule()
        await waitUntil { contention.drainCount == 2 }
        await scheduler.cancel()

        XCTAssertEqual(contention.drainCount, 2)
        XCTAssertEqual(delays.values.first, 0)
        XCTAssertEqual(delays.values.dropFirst().first, 0.25)
    }

    private func makeFixture() throws -> (
        destination: FakeWatchlistDestination,
        store: DurableWatchlistMutationStore,
        reconciler: WatchlistReconciler
    ) {
        let destination = FakeWatchlistDestination()
        let store = try DurableWatchlistMutationStore(
            store: InMemoryWatchlistMutationStateStore()
        )
        return (
            destination,
            store,
            WatchlistReconciler(
                registry: WatchlistDestinationRegistry([destination]),
                mutationStore: store,
                retryPolicy: WatchlistRetryPolicy(jitterFraction: 0)
            )
        )
    }

    private final class CountingMutationStateStore:
        WatchlistMutationStateStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var state = WatchlistMutationStoreState()
        private(set) var saveCount = 0
        func load() throws -> WatchlistMutationStoreState {
            lock.lock()
            defer { lock.unlock() }
            return state
        }
        func save(_ state: WatchlistMutationStoreState) throws {
            lock.lock()
            self.state = state
            saveCount += 1
            lock.unlock()
        }
    }

    private func makeTarget(
        aliasID: MediaAliasID = MediaAliasID()
    ) -> WatchlistMutationTarget {
        WatchlistMutationTarget(
            aliasID: aliasID,
            kind: .movie,
            externalIDs: [
                WatchlistExternalID(namespace: .imdb, value: "tt1")!
            ]
        )!
    }

    private func waitUntil(
        _ predicate: @escaping @Sendable () async -> Bool
    ) async {
        for _ in 0..<200 {
            if await predicate() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Timed out waiting for asynchronous scheduler")
    }

    /// A 429 is the destination describing itself, so it must hold back the
    /// whole queue for that destination. Regression for the Plex retry storm:
    /// 19 queued titles each burned their own 429, which escalated the limit.
    func testRateLimitDefersEveryPendingMutationForThatDestination() async throws {
        let store = try DurableWatchlistMutationStore(
            store: CountingMutationStateStore()
        )
        let limited = WatchlistDestinationID(rawValue: "plex.acct")!
        let other = WatchlistDestinationID(rawValue: "simkl")!
        for destination in [limited, limited, limited, other] {
            try await store.enqueue(
                profileID: "p",
                desiredState: .present,
                target: makeTarget(),
                destinationID: destination
            )
        }
        let now = Date()
        let deferred = try await store.deferDestination(
            limited,
            until: now.addingTimeInterval(600)
        )
        XCTAssertEqual(deferred, 3, "every queued Plex title should be held back")

        let ready = await store.ready(
            profileID: "p",
            now: now.addingTimeInterval(1),
            limit: 100
        )
        XCTAssertEqual(
            ready.map { $0.key.destinationID },
            [other],
            "only the un-limited destination stays runnable"
        )

        // The cooldown must never pull an attempt earlier than already planned.
        let shortened = try await store.deferDestination(
            limited,
            until: now.addingTimeInterval(5)
        )
        XCTAssertEqual(shortened, 0)
    }

    /// A disconnected tracker must be contacted once, not once per queued title.
    func testAuthenticationFailureParksTheWholeDestinationAndResumesCleanly() async throws {
        let store = try DurableWatchlistMutationStore(
            store: CountingMutationStateStore()
        )
        let tracker = WatchlistDestinationID(rawValue: "trakt")!
        let other = WatchlistDestinationID(rawValue: "simkl")!
        for destination in [tracker, tracker, tracker, other] {
            try await store.enqueue(
                profileID: "p",
                desiredState: .present,
                target: makeTarget(),
                destinationID: destination
            )
        }
        let parked = try await store.parkDestinationForAuthentication(tracker)
        XCTAssertEqual(parked, 3)

        let ready = await store.ready(profileID: "p", now: Date(), limit: 100)
        XCTAssertEqual(
            ready.map { $0.key.destinationID },
            [other],
            "a disconnected tracker should not be retried per title"
        )

        // Reconnecting must bring exactly those mutations back.
        let resumed = try await store.resumeAuthentication(destinationIDs: [tracker])
        XCTAssertEqual(resumed, 3)
        let afterResume = await store.ready(profileID: "p", now: Date(), limit: 100)
        XCTAssertEqual(afterResume.count, 4)
    }

    /// The master regression: a periodic sync sweep re-offers entries it already
    /// knows about. If that resets retry state, every cooldown and auth park is
    /// wiped each wave and a broken destination is hammered forever.
    func testResyncingUnchangedEntriesPreservesBackoffAndParking() async throws {
        let store = try DurableWatchlistMutationStore(
            store: CountingMutationStateStore()
        )
        let limited = WatchlistDestinationID(rawValue: "plex.acct")!
        let tracker = WatchlistDestinationID(rawValue: "trakt")!
        let target = makeTarget()
        for destination in [limited, tracker] {
            try await store.enqueue(
                profileID: "p",
                desiredState: .present,
                target: target,
                destinationID: destination
            )
        }
        let now = Date()
        try await store.deferDestination(limited, until: now.addingTimeInterval(600))
        try await store.parkDestinationForAuthentication(tracker)
        let parkedReady = await store.ready(
            profileID: "p", now: now.addingTimeInterval(1), limit: 10
        )
        XCTAssertTrue(parkedReady.isEmpty)

        // A sweep re-offers exactly the same intent — nothing may be revived.
        try await store.enqueueBatch(
            [limited, tracker].map {
                WatchlistMutationEnqueueRequest(
                    profileID: "p",
                    desiredState: .present,
                    target: target,
                    destinationID: $0
                )
            }
        )
        let afterResync = await store.ready(
            profileID: "p", now: now.addingTimeInterval(1), limit: 10
        )
        XCTAssertTrue(
            afterResync.isEmpty,
            "a no-op resync must not wipe cooldown or authentication parking"
        )

        // Changing your mind is different: that is a fresh intent and must run.
        try await store.enqueue(
            profileID: "p",
            desiredState: .absent,
            target: target,
            destinationID: tracker
        )
        let ready = await store.ready(profileID: "p", now: now.addingTimeInterval(1), limit: 10)
        XCTAssertEqual(ready.map { $0.key.destinationID }, [tracker])
    }

    func testRateLimitedStatusIsClassifiedAsRetryableNotPermanent() {
        let policy = WatchlistRetryPolicy()
        let decision = policy.decision(
            for: WatchlistDestinationError.rateLimited(retryAfter: 42),
            attempt: 0
        )
        XCTAssertEqual(decision.classification, .transient)
        XCTAssertEqual(decision.retryDelay, 42)

        // A 4xx that is not a rate limit must stop, not retry forever.
        let permanent = policy.decision(
            for: WatchlistDestinationError.permanent,
            attempt: 0
        )
        XCTAssertEqual(permanent.classification, .permanent)
        XCTAssertNil(permanent.retryDelay)
    }
}

private actor FakeWatchlistDestination: WatchlistDestination {
    nonisolated let id = WatchlistDestinationID(rawValue: "fake")!
    nonisolated let capabilities = WatchlistDestinationCapabilities(
        readable: true,
        writable: true,
        removable: true,
        bindingRequirement: .globalExternalIdentity,
        globalIdentityNamespaces: [.imdb]
    )
    private var applied: [WatchlistDesiredState] = []

    func fetchEntries() async throws -> [WatchlistDestinationEntry] { [] }

    func resolve(
        _ target: WatchlistMutationTarget
    ) async throws -> WatchlistDestinationBinding? {
        guard let value = target.externalIDs.first?.value else { return nil }
        guard value != "unresolved" else { return nil }
        return WatchlistDestinationBinding(
            destinationID: id,
            opaqueValue: value
        )
    }

    func apply(
        _ desiredState: WatchlistDesiredState,
        to binding: WatchlistDestinationBinding
    ) async throws {
        applied.append(desiredState)
    }

    func appliedStates() -> [WatchlistDesiredState] { applied }

}

private actor RetryingWatchlistDestination: WatchlistDestination {
        nonisolated let id = WatchlistDestinationID(rawValue: "retrying")!
        nonisolated let capabilities = WatchlistDestinationCapabilities(
            readable: false,
            writable: true,
            removable: true,
            bindingRequirement: .globalExternalIdentity,
            globalIdentityNamespaces: [.imdb]
        )
        private var failures: [WatchlistDestinationError]
        private var successes = 0

        init(failures: [WatchlistDestinationError]) {
            self.failures = failures
        }

        func fetchEntries() async throws -> [WatchlistDestinationEntry] { [] }
        func resolve(
            _ target: WatchlistMutationTarget
        ) async throws -> WatchlistDestinationBinding? {
            WatchlistDestinationBinding(
                destinationID: id,
                opaqueValue: "resolved"
            )
        }
        func apply(
            _ desiredState: WatchlistDesiredState,
            to binding: WatchlistDestinationBinding
        ) async throws {
            if !failures.isEmpty { throw failures.removeFirst() }
            successes += 1
        }
        func successCount() -> Int { successes }
    }

private final class LockedWatchlistClock: @unchecked Sendable {
        private let lock = NSLock()
        private var date: Date
        init(_ date: Date) { self.date = date }
        func now() -> Date {
            lock.lock()
            defer { lock.unlock() }
            return date
        }
        func advance(by delay: TimeInterval) {
            lock.lock()
            date = date.addingTimeInterval(delay)
            lock.unlock()
        }
    }

private final class LockedWatchlistCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
        func increment() {
            lock.lock()
            count += 1
            lock.unlock()
        }
    }

    private final class LockedWatchlistContention: @unchecked Sendable {
        private let lock = NSLock()
        private var drains = 0
        private var queued = true
        var drainCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return drains
        }
        var hasQueuedMutation: Bool {
            lock.lock()
            defer { lock.unlock() }
            return queued
        }
        func drain() -> WatchlistRetryDrainOutcome {
            lock.lock()
            defer { lock.unlock() }
            drains += 1
            if drains == 1 { return .busy }
            queued = false
            return .completed
        }
    }

    private final class LockedWatchlistDelays: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [TimeInterval] = []
        var values: [TimeInterval] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        func append(_ value: TimeInterval) {
            lock.lock()
            storage.append(value)
            lock.unlock()
        }
    }
