import CoreModels
import XCTest
@testable import FeatureWatchlistCore

final class WatchlistReconcilerTests: XCTestCase {
    func testConcurrentNativeReadsShareTheInFlightResult() async throws {
        let destination = SlowReadableWatchlistDestination()
        let store = try DurableWatchlistMutationStore(
            store: InMemoryWatchlistMutationStateStore()
        )
        let reconciler = WatchlistReconciler(
            registry: WatchlistDestinationRegistry([destination]),
            mutationStore: store
        )

        async let first = reconciler.fetchNativeEntries()
        async let second = reconciler.fetchNativeEntries()
        let reports = await [first, second]
        let fetchCount = await destination.fetchCount()

        XCTAssertEqual(reports[0].successes.count, 1)
        XCTAssertEqual(reports[1].successes.count, 1)
        XCTAssertEqual(fetchCount, 1)
    }

    func testNativeReadIsRejectedWhenAccountScopeChangesMidFetch() async throws {
        let destination = ScopeChangingWatchlistDestination()
        let store = try DurableWatchlistMutationStore(
            store: InMemoryWatchlistMutationStateStore()
        )
        let reconciler = WatchlistReconciler(
            registry: WatchlistDestinationRegistry([destination]),
            mutationStore: store
        )

        let report = await reconciler.fetchNativeEntries()

        XCTAssertTrue(report.successes.isEmpty)
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertEqual(report.failures.first?.classification, .authentication)
    }

    func testQueuedMutationIsDiscardedAfterAccountScopeChanges() async throws {
        let destination = MutableScopeWatchlistDestination()
        let store = try DurableWatchlistMutationStore(
            store: InMemoryWatchlistMutationStateStore()
        )
        let reconciler = WatchlistReconciler(
            registry: WatchlistDestinationRegistry([destination]),
            mutationStore: store
        )
        let target = makeTarget()
        try await reconciler.enqueue(
            profileID: "p",
            desiredState: .present,
            target: target,
            destinationID: destination.id
        )

        destination.switchAccount()
        _ = await reconciler.drain(profileID: "p")

        XCTAssertEqual(destination.appliedStates(), [])
        let mutations = await store.allMutations()
        XCTAssertTrue(mutations.isEmpty)
    }

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

    func testPersistentPresenceAfterSuccessfulRemovalBecomesNativeAddition() async throws {
        let fixture = try makeFixture()
        let target = makeTarget()
        let key = WatchlistMutationKey(
            profileID: "p",
            aliasID: target.aliasID,
            destinationID: fixture.destination.id
        )
        let succeededAt = Date(timeIntervalSince1970: 100)
        try await fixture.store.enqueue(
            profileID: "p",
            desiredState: .absent,
            target: target,
            destinationID: fixture.destination.id
        )
        try await fixture.store.markSucceeded(key, now: succeededAt)

        let stalePresence = try await fixture.store.observeNative(
            key: key,
            isPresent: true,
            localDesiredState: .absent,
            confirmationIdentity: target.identityFingerprint,
            nativeReadStartedAt: Date(timeIntervalSince1970: 110),
            now: Date(timeIntervalSince1970: 110)
        )
        let firstStablePresence = try await fixture.store.observeNative(
            key: key,
            isPresent: true,
            localDesiredState: .absent,
            confirmationIdentity: target.identityFingerprint,
            nativeReadStartedAt: Date(timeIntervalSince1970: 140),
            now: Date(timeIntervalSince1970: 140)
        )
        let reAdd = try await fixture.store.observeNative(
            key: key,
            isPresent: true,
            localDesiredState: .absent,
            confirmationIdentity: target.identityFingerprint,
            nativeReadStartedAt: Date(timeIntervalSince1970: 141),
            now: Date(timeIntervalSince1970: 141)
        )

        XCTAssertEqual(stalePresence, .ignorePresenceDuringExplicitRemoval)
        XCTAssertEqual(firstStablePresence, .ignorePresenceDuringExplicitRemoval)
        XCTAssertEqual(reAdd, .nativeAddition)
        let repeatedBeforeAcknowledgement = try await fixture.store.observeNative(
            key: key,
            isPresent: true,
            localDesiredState: .absent,
            confirmationIdentity: target.identityFingerprint,
            nativeReadStartedAt: Date(timeIntervalSince1970: 142),
            now: Date(timeIntervalSince1970: 142)
        )
        XCTAssertEqual(repeatedBeforeAcknowledgement, .nativeAddition)
        try await fixture.store.acknowledgeNativeAddition(
            key,
            confirmationIdentity: target.identityFingerprint,
            now: Date(timeIntervalSince1970: 143)
        )
        let settled = try await fixture.store.observeNative(
            key: key,
            isPresent: true,
            localDesiredState: .absent,
            confirmationIdentity: target.identityFingerprint,
            nativeReadStartedAt: Date(timeIntervalSince1970: 144),
            now: Date(timeIntervalSince1970: 144)
        )
        XCTAssertEqual(settled, .noChange)
    }

    func testConfirmedNativeRemovalDoesNotReassertTheAdd() async throws {
        let fixture = try makeFixture()
        let target = makeTarget()
        let key = WatchlistMutationKey(
            profileID: "p",
            aliasID: target.aliasID,
            destinationID: fixture.destination.id
        )
        try await fixture.store.enqueue(
            profileID: "p",
            desiredState: .present,
            target: target,
            destinationID: fixture.destination.id
        )
        try await fixture.store.markSucceeded(key)

        let removal = try await fixture.store.observeNative(
            key: key,
            isPresent: false,
            localDesiredState: .present,
            confirmationIdentity: target.identityFingerprint
        )

        XCTAssertEqual(removal, .confirmedNativeRemoval)
        let overlappingRefresh = try await fixture.store.observeNative(
            key: key,
            isPresent: false,
            localDesiredState: .present,
            confirmationIdentity: target.identityFingerprint
        )
        XCTAssertEqual(overlappingRefresh, .confirmedNativeRemoval)
        let queued = await fixture.store.ready(profileID: "p")
        XCTAssertTrue(queued.isEmpty)
        let confirmedAbsent = try await fixture.store.observeNative(
            key: key,
            isPresent: false,
            localDesiredState: .absent,
            confirmationIdentity: target.identityFingerprint
        )
        XCTAssertEqual(confirmedAbsent, .confirmedAbsence)
        let laterAddition = try await fixture.store.observeNative(
            key: key,
            isPresent: true,
            localDesiredState: .absent,
            confirmationIdentity: target.identityFingerprint
        )
        XCTAssertEqual(laterAddition, .nativeAddition)
    }

    func testReadStartedBeforeSuccessfulAddCannotBecomeNativeRemoval() async throws {
        let fixture = try makeFixture()
        let target = makeTarget()
        let key = WatchlistMutationKey(
            profileID: "p",
            aliasID: target.aliasID,
            destinationID: fixture.destination.id
        )
        let readStartedAt = Date(timeIntervalSince1970: 100)
        try await fixture.store.enqueue(
            profileID: "p",
            desiredState: .present,
            target: target,
            destinationID: fixture.destination.id
        )
        try await fixture.store.markSucceeded(
            key,
            now: Date(timeIntervalSince1970: 200)
        )

        let observation = try await fixture.store.observeNativeBatch([
            WatchlistNativeObservationRequest(
                key: key,
                isPresent: false,
                localDesiredState: .present,
                confirmationIdentity: target.identityFingerprint,
                nativeReadStartedAt: readStartedAt,
                isEligibleTarget: true
            )
        ]).first?.observation

        XCTAssertEqual(observation, .reassertPresent)
    }

    func testQueuedReAddPreventsConfirmedPresenceBecomingRemoval() async throws {
        let fixture = try makeFixture()
        let target = makeTarget()
        let key = WatchlistMutationKey(
            profileID: "p",
            aliasID: target.aliasID,
            destinationID: fixture.destination.id
        )
        try await fixture.store.enqueue(
            profileID: "p",
            desiredState: .present,
            target: target,
            destinationID: fixture.destination.id
        )
        try await fixture.store.markSucceeded(key)
        try await fixture.store.enqueue(
            profileID: "p",
            desiredState: .present,
            target: target,
            destinationID: fixture.destination.id
        )

        let observation = try await fixture.store.observeNative(
            key: key,
            isPresent: false,
            localDesiredState: .present,
            confirmationIdentity: target.identityFingerprint
        )

        XCTAssertEqual(observation, .reassertPresent)
    }

    func testNativeReAddCancelsPendingNativeRemovalObservation() async throws {
        let fixture = try makeFixture()
        let target = makeTarget()
        let key = WatchlistMutationKey(
            profileID: "p",
            aliasID: target.aliasID,
            destinationID: fixture.destination.id
        )
        try await fixture.store.enqueue(
            profileID: "p",
            desiredState: .present,
            target: target,
            destinationID: fixture.destination.id
        )
        try await fixture.store.markSucceeded(key)
        let removal = try await fixture.store.observeNative(
            key: key,
            isPresent: false,
            localDesiredState: .present,
            confirmationIdentity: target.identityFingerprint
        )
        XCTAssertEqual(removal, .confirmedNativeRemoval)

        let reAdd = try await fixture.store.observeNative(
            key: key,
            isPresent: true,
            localDesiredState: .absent,
            confirmationIdentity: target.identityFingerprint
        )

        XCTAssertEqual(reAdd, .nativeAddition)
        try await fixture.store.acknowledgeNativeAddition(
            key,
            confirmationIdentity: target.identityFingerprint
        )
        let settledPresence = try await fixture.store.observeNative(
            key: key,
            isPresent: true,
            localDesiredState: .absent,
            confirmationIdentity: target.identityFingerprint
        )
        XCTAssertEqual(settledPresence, .noChange)
    }

    func testCompletionOfReplacedMutationDoesNotAlterReplacement() async throws {
        let fixture = try makeFixture()
        let target = makeTarget()
        try await fixture.store.enqueue(
            profileID: "p",
            desiredState: .present,
            target: target,
            destinationID: fixture.destination.id
        )
        let ready = await fixture.store.ready(profileID: "p")
        let processed = try XCTUnwrap(ready.first)
        try await fixture.store.enqueue(
            profileID: "p",
            desiredState: .absent,
            target: target,
            destinationID: fixture.destination.id
        )

        try await fixture.store.markSucceeded(processed)
        try await fixture.store.markFailed(
            processed,
            classification: .transient,
            retryAt: Date().addingTimeInterval(30)
        )

        let mutations = await fixture.store.allMutations()
        let replacement = try XCTUnwrap(mutations.first)
        XCTAssertEqual(replacement.desiredState, .absent)
        XCTAssertEqual(replacement.attemptCount, 0)
        XCTAssertEqual(replacement.phase, .queued)
    }

    func testNativeReAddAtomicallyReplacesQueuedPeerRemovals() async throws {
        let backing = CountingMutationStateStore()
        let store = try DurableWatchlistMutationStore(store: backing)
        let target = makeTarget()
        let source = WatchlistDestinationID(rawValue: "source")!
        let peer = WatchlistDestinationID(rawValue: "peer")!
        try await store.enqueueBatch([source, peer].map {
            WatchlistMutationEnqueueRequest(
                profileID: "p",
                desiredState: .absent,
                target: target,
                destinationID: $0
            )
        })

        try await store.replacePendingRemovalsWithPresentFanOut(
            profileID: "p",
            aliasID: target.aliasID,
            requests: [
                WatchlistMutationEnqueueRequest(
                    profileID: "p",
                    desiredState: .present,
                    target: target,
                    destinationID: peer
                )
            ]
        )

        let mutations = await store.allMutations()
        XCTAssertEqual(backing.saveCount, 2)
        XCTAssertEqual(mutations.count, 1)
        XCTAssertEqual(mutations.first?.key.destinationID, peer)
        XCTAssertEqual(mutations.first?.desiredState, .present)
    }

    func testFailedStaleMutationDiscardRestoresInMemoryQueue() async throws {
        let backing = CountingMutationStateStore()
        let store = try DurableWatchlistMutationStore(store: backing)
        let target = makeTarget()
        let destination = WatchlistDestinationID(rawValue: "destination")!
        try await store.enqueue(
            profileID: "p",
            desiredState: .present,
            target: target,
            destinationID: destination
        )
        let queued = await store.allMutations()
        let mutation = try XCTUnwrap(queued.first)
        backing.failNextSave()

        do {
            try await store.discard(mutation)
            XCTFail("Expected persistence failure")
        } catch {}
        let mutations = await store.allMutations()
        XCTAssertEqual(mutations, [mutation])
    }

    func testFailedNativeObservationRestoresReconciliationState() async throws {
        let backing = CountingMutationStateStore()
        let store = try DurableWatchlistMutationStore(store: backing)
        let target = makeTarget()
        let destination = WatchlistDestinationID(rawValue: "destination")!
        let key = WatchlistMutationKey(
            profileID: "p",
            aliasID: target.aliasID,
            destinationID: destination
        )
        try await store.enqueue(
            profileID: "p",
            desiredState: .absent,
            target: target,
            destinationID: destination
        )
        try await store.markSucceeded(
            key,
            now: Date(timeIntervalSince1970: 100)
        )
        backing.failNextSave()

        do {
            _ = try await store.observeNative(
                key: key,
                isPresent: true,
                localDesiredState: .absent,
                confirmationIdentity: target.identityFingerprint,
                nativeReadStartedAt: Date(timeIntervalSince1970: 140),
                now: Date(timeIntervalSince1970: 140)
            )
            XCTFail("Expected persistence failure")
        } catch {}

        let retriedCandidate = try await store.observeNative(
            key: key,
            isPresent: true,
            localDesiredState: .absent,
            confirmationIdentity: target.identityFingerprint,
            nativeReadStartedAt: Date(timeIntervalSince1970: 140),
            now: Date(timeIntervalSince1970: 140)
        )
        let retry = try await store.observeNative(
            key: key,
            isPresent: true,
            localDesiredState: .absent,
            confirmationIdentity: target.identityFingerprint,
            nativeReadStartedAt: Date(timeIntervalSince1970: 141),
            now: Date(timeIntervalSince1970: 141)
        )
        XCTAssertEqual(
            retriedCandidate,
            .ignorePresenceDuringExplicitRemoval
        )
        XCTAssertEqual(retry, .nativeAddition)
    }

    func testAbsenceUnderDifferentIdentityStillReasserts() async throws {
        let fixture = try makeFixture()
        let original = makeTarget()
        let key = WatchlistMutationKey(
            profileID: "p",
            aliasID: original.aliasID,
            destinationID: fixture.destination.id
        )
        try await fixture.store.enqueue(
            profileID: "p",
            desiredState: .present,
            target: original,
            destinationID: fixture.destination.id
        )
        try await fixture.store.markSucceeded(key)
        let changedIdentity = WatchlistMutationTarget(
            aliasID: original.aliasID,
            kind: .movie,
            externalIDs: [
                WatchlistExternalID(namespace: .imdb, value: "tt2")!
            ]
        )!

        let observation = try await fixture.store.observeNative(
            key: key,
            isPresent: false,
            localDesiredState: .present,
            confirmationIdentity: changedIdentity.identityFingerprint
        )

        XCTAssertEqual(observation, .reassertPresent)
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
        let additions = try await store.observeNativeBatch(present)
        XCTAssertTrue(additions.allSatisfy {
            $0.observation == .nativeAddition
        })
        for request in present {
            try await store.acknowledgeNativeAddition(
                request.key,
                confirmationIdentity: nil
            )
        }
        let presentCount = await store.reconciliationStateCount(profileID: "p")
        XCTAssertEqual(backing.saveCount, 102)
        XCTAssertEqual(presentCount, 100)
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
            // Distinct from the contention delay so the two floors are
            // distinguishable; a due-now backlog is paced by this one.
            minimumDrainInterval: 0.05,
            sleeper: { delay in delays.append(delay) }
        )

        await scheduler.reschedule()
        await waitUntil { contention.drainCount == 2 }
        await scheduler.cancel()

        XCTAssertEqual(contention.drainCount, 2)
        // Was 0 — a due-now wake with no delay, which is what let the scheduler
        // spin a core flat out while a backlog drained.
        XCTAssertEqual(delays.values.first, 0.05)
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
        private var shouldFailNextSave = false
        func load() throws -> WatchlistMutationStoreState {
            lock.lock()
            defer { lock.unlock() }
            return state
        }
        func save(_ state: WatchlistMutationStoreState) throws {
            lock.lock()
            if shouldFailNextSave {
                shouldFailNextSave = false
                lock.unlock()
                throw CocoaError(.fileWriteUnknown)
            }
            self.state = state
            saveCount += 1
            lock.unlock()
        }
        func failNextSave() {
            lock.lock()
            shouldFailNextSave = true
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

    /// The identity refresh walks the whole watchlist on every library update.
    /// Without confirmation memory it re-sent every title to every destination,
    /// which is what earned the Plex rate limit in the first place.
    func testConfirmedDestinationsAreNotRewrittenOnResync() async throws {
        let store = try DurableWatchlistMutationStore(
            store: CountingMutationStateStore()
        )
        let destination = WatchlistDestinationID(rawValue: "plex.acct")!
        let target = makeTarget()
        let key = WatchlistMutationKey(
            profileID: "p",
            aliasID: target.aliasID,
            destinationID: destination
        )
        try await store.enqueue(
            profileID: "p",
            desiredState: .present,
            target: target,
            destinationID: destination
        )
        let beforeSuccess = await store.isAlreadyConfirmed(
            key, desiredState: .present, target: target
        )
        XCTAssertFalse(beforeSuccess)
        try await store.markSucceeded(key)
        let afterSuccess = await store.isAlreadyConfirmed(
            key, desiredState: .present, target: target
        )
        XCTAssertTrue(afterSuccess, "a confirmed add must suppress an identical resync")
        // The opposite intent is never suppressed.
        let opposite = await store.isAlreadyConfirmed(
            key, desiredState: .absent, target: target
        )
        XCTAssertFalse(opposite)
    }

    /// Better ids mean a destination that previously could not resolve the title
    /// might now succeed, so a changed identity must re-open the write.
    func testChangedIdentityReopensAConfirmedDestination() async throws {
        let store = try DurableWatchlistMutationStore(
            store: CountingMutationStateStore()
        )
        let destination = WatchlistDestinationID(rawValue: "anilist")!
        let target = makeTarget()
        let key = WatchlistMutationKey(
            profileID: "p",
            aliasID: target.aliasID,
            destinationID: destination
        )
        try await store.enqueue(
            profileID: "p",
            desiredState: .present,
            target: target,
            destinationID: destination
        )
        try await store.markSucceeded(key)

        var richer = target
        richer.externalIDs.append(
            WatchlistExternalID(namespace: .aniList, value: "12345")!
        )
        XCTAssertNotEqual(
            target.identityFingerprint,
            richer.identityFingerprint
        )
        let reopened = await store.isAlreadyConfirmed(
            key, desiredState: .present, target: richer
        )
        XCTAssertFalse(
            reopened,
            "new ids must re-open a destination that could not resolve before"
        )
    }

    /// Confirmations must track the watchlist, not everything ever watchlisted.
    func testConfirmationsAreForgottenForUnwatchlistedTitles() async throws {
        let store = try DurableWatchlistMutationStore(
            store: CountingMutationStateStore()
        )
        let destination = WatchlistDestinationID(rawValue: "simkl")!
        let kept = makeTarget()
        let dropped = makeTarget()
        for target in [kept, dropped] {
            try await store.enqueue(
                profileID: "p",
                desiredState: .present,
                target: target,
                destinationID: destination
            )
            try await store.markSucceeded(
                WatchlistMutationKey(
                    profileID: "p",
                    aliasID: target.aliasID,
                    destinationID: destination
                )
            )
        }
        let removed = try await store.forgetConfirmations(
            profileID: "p",
            keepingAliasIDs: [kept.aliasID]
        )
        XCTAssertEqual(removed, 1)
        let keptConfirmed = await store.isAlreadyConfirmed(
            WatchlistMutationKey(
                profileID: "p", aliasID: kept.aliasID, destinationID: destination
            ),
            desiredState: .present,
            target: kept
        )
        XCTAssertTrue(keptConfirmed)
        let droppedConfirmed = await store.isAlreadyConfirmed(
            WatchlistMutationKey(
                profileID: "p", aliasID: dropped.aliasID, destinationID: destination
            ),
            desiredState: .present,
            target: dropped
        )
        XCTAssertFalse(droppedConfirmed)
    }

    /// A destination that cannot resolve a title must not be retried on every
    /// identity wave — only genuinely better ids can change the answer.
    func testUnresolvableTitleIsRetriedOnlyWhenItsIdentityImproves() async throws {
        let store = try DurableWatchlistMutationStore(
            store: CountingMutationStateStore()
        )
        let destination = WatchlistDestinationID(rawValue: "anilist")!
        let target = makeTarget()
        try await store.enqueue(
            profileID: "p",
            desiredState: .present,
            target: target,
            destinationID: destination
        )
        let key = WatchlistMutationKey(
            profileID: "p", aliasID: target.aliasID, destinationID: destination
        )
        try await store.markFailed(
            key, classification: .unsupportedIdentity, retryAt: nil
        )
        let parked = await store.ready(profileID: "p", now: Date(), limit: 10)
        XCTAssertTrue(parked.isEmpty)

        // An identical refresh must not revive it.
        try await store.refreshTargets(profileID: "p", targets: [target])
        let afterNoOp = await store.ready(profileID: "p", now: Date(), limit: 10)
        XCTAssertTrue(
            afterNoOp.isEmpty,
            "an unchanged identity must not re-open an unresolvable destination"
        )

        // Better ids must revive it.
        var richer = target
        richer.externalIDs.append(
            WatchlistExternalID(namespace: .aniList, value: "999")!
        )
        try await store.refreshTargets(profileID: "p", targets: [richer])
        let afterImprovement = await store.ready(profileID: "p", now: Date(), limit: 10)
        XCTAssertEqual(afterImprovement.count, 1)
    }

    /// Importing a native watchlist must not erase what we already confirmed a
    /// destination holds. Removal bookkeeping is transient; the confirmation is
    /// durable, and both live in the same record — clearing the record wholesale
    /// wiped the memory on every launch and re-sent the whole watchlist.
    func testNativeImportKeepsConfirmationsItDidNotWrite() async throws {
        let store = try DurableWatchlistMutationStore(
            store: CountingMutationStateStore()
        )
        let destination = WatchlistDestinationID(rawValue: "plex.acct")!
        let target = makeTarget()
        let key = WatchlistMutationKey(
            profileID: "p",
            aliasID: target.aliasID,
            destinationID: destination
        )
        try await store.enqueue(
            profileID: "p",
            desiredState: .present,
            target: target,
            destinationID: destination
        )
        try await store.markSucceeded(key)
        let confirmed = await store.isAlreadyConfirmed(
            key, desiredState: .present, target: target
        )
        XCTAssertTrue(confirmed)

        // A native import sweep observes the title already present remotely.
        _ = try await store.observeNativeBatch([
            WatchlistNativeObservationRequest(
                key: key,
                isPresent: true,
                localDesiredState: .present,
                isEligibleTarget: true
            )
        ])

        let survived = await store.isAlreadyConfirmed(
            key, desiredState: .present, target: target
        )
        XCTAssertTrue(
            survived,
            "a native import must not erase an existing confirmation"
        )
    }

    /// The scheduler must not spin. `earliestNextAttempt` reports `.distantPast`
    /// while anything is queued, which means "there is work now" — taking it as
    /// a delay produced a zero-delay wake/drain/reschedule cycle that pegged a
    /// core for as long as the backlog lasted and put the phone into the Serious
    /// thermal state.
    func testBacklogDrainIsPacedRatherThanSpun() async {
        let requested = SleepRecorder()
        let scheduler = WatchlistRetryScheduler(
            profileID: "p",
            nextAttempt: { _ in .distantPast },
            drain: { _, _ in .completed },
            now: { Date() },
            sleeper: { delay in
                await requested.record(delay)
                // Stop after a few waves; an unpaced scheduler would spin here.
                if await requested.count() > 4 { throw CancellationError() }
            }
        )
        await scheduler.reschedule()
        await waitUntil { await requested.count() > 4 }
        await scheduler.cancel()

        let delays = await requested.delays()
        XCTAssertFalse(delays.isEmpty)
        for delay in delays {
            XCTAssertGreaterThan(
                delay,
                0,
                "a due-now backlog must be paced, never rescheduled with no delay"
            )
        }
    }

    /// A future retry keeps its own delay; pacing is a floor, not an override.
    func testAGenuineFutureRetryKeepsItsOwnDelay() async {
        let requested = SleepRecorder()
        let start = Date()
        let scheduler = WatchlistRetryScheduler(
            profileID: "p",
            nextAttempt: { _ in start.addingTimeInterval(60) },
            drain: { _, _ in .completed },
            now: { start },
            sleeper: { delay in
                await requested.record(delay)
                throw CancellationError()
            }
        )
        await scheduler.reschedule()
        await waitUntil { await requested.count() >= 1 }
        await scheduler.cancel()
        let delays = await requested.delays()
        XCTAssertEqual(delays.first.map { Int($0.rounded()) }, 60)
    }

    /// Selecting the next few mutations must not cost more as the backlog grows
    /// in ways that scale with copying every pending record.
    func testReadySelectsTheOldestFewRegardlessOfBacklogSize() async throws {
        let store = try DurableWatchlistMutationStore(
            store: CountingMutationStateStore()
        )
        let destination = WatchlistDestinationID(rawValue: "simkl")!
        var targets: [WatchlistMutationTarget] = []
        for _ in 0..<200 { targets.append(makeTarget()) }
        try await store.enqueueBatch(
            targets.map {
                WatchlistMutationEnqueueRequest(
                    profileID: "p",
                    desiredState: .present,
                    target: $0,
                    destinationID: destination
                )
            }
        )
        let ready = await store.ready(profileID: "p", now: Date(), limit: 3)
        XCTAssertEqual(ready.count, 3)

        // Same ordering the old filter+sort produced: oldest first, key as the
        // tie-break.
        let all = await store.allMutations().filter {
            $0.phase == .queued || $0.phase == .retryScheduled
        }.sorted {
            $0.updatedAt != $1.updatedAt
                ? $0.updatedAt < $1.updatedAt
                : $0.key < $1.key
        }
        XCTAssertEqual(ready.map(\.key), Array(all.prefix(3)).map(\.key))
    }

    /// Queueing an add must not forget what the destination already holds.
    /// Clearing the record here made every resync re-send the whole watchlist,
    /// so it never settled and kept the radio busy indefinitely.
    func testQueueingAnAddKeepsAnExistingConfirmation() async throws {
        let store = try DurableWatchlistMutationStore(
            store: CountingMutationStateStore()
        )
        let destination = WatchlistDestinationID(rawValue: "simkl")!
        let target = makeTarget()
        let key = WatchlistMutationKey(
            profileID: "p",
            aliasID: target.aliasID,
            destinationID: destination
        )
        try await store.enqueue(
            profileID: "p",
            desiredState: .present,
            target: target,
            destinationID: destination
        )
        try await store.markSucceeded(key)

        // Something queues the same add again (a fan-out from a user press).
        try await store.enqueue(
            profileID: "p",
            desiredState: .present,
            target: target,
            destinationID: destination
        )
        let stillConfirmed = await store.isAlreadyConfirmed(
            key, desiredState: .present, target: target
        )
        XCTAssertTrue(
            stillConfirmed,
            "queueing an add must not erase the confirmation that suppresses resyncs"
        )
    }

    /// A 429 must survive the HTTP layer as a rate limit. Collapsing it into a
    /// generic failure made the queue answer a throttle with more requests —
    /// measured on device as 66 AniList retries against 11 successes.
    func testAThrottleKeepsItsMeaningThroughTheRetryPolicy() {
        let policy = WatchlistRetryPolicy()
        let honoured = policy.decision(
            for: AppError.rateLimited(retryAfter: 30),
            attempt: 0
        )
        XCTAssertEqual(honoured.classification, .transient)
        XCTAssertEqual(honoured.retryDelay, 30)

        // With no Retry-After the normal backoff applies, but it must still be
        // a delay rather than an immediate retry.
        let unspecified = policy.decision(
            for: AppError.rateLimited(retryAfter: nil),
            attempt: 0
        )
        XCTAssertEqual(unspecified.classification, .transient)
        XCTAssertNotNil(unspecified.retryDelay)
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

/// Records the delays the scheduler asks to sleep for.
private actor SleepRecorder {
    private var recorded: [TimeInterval] = []
    func record(_ delay: TimeInterval) { recorded.append(delay) }
    func count() -> Int { recorded.count }
    func delays() -> [TimeInterval] { recorded }
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

private actor SlowReadableWatchlistDestination: WatchlistDestination {
    nonisolated let id = WatchlistDestinationID(rawValue: "slow-readable")!
    nonisolated let capabilities = WatchlistDestinationCapabilities(
        readable: true,
        writable: false,
        removable: false,
        bindingRequirement: .globalExternalIdentity,
        globalIdentityNamespaces: [.imdb]
    )
    private var reads = 0

    func fetchEntries() async throws -> [WatchlistDestinationEntry] {
        reads += 1
        try await Task.sleep(for: .milliseconds(50))
        return []
    }

    func resolve(
        _ target: WatchlistMutationTarget
    ) async throws -> WatchlistDestinationBinding? {
        nil
    }

    func apply(
        _ desiredState: WatchlistDesiredState,
        to binding: WatchlistDestinationBinding
    ) async throws {}

    func fetchCount() -> Int { reads }
}

private final class ScopeChangingWatchlistDestination:
    WatchlistDestination, @unchecked Sendable {
    let id = WatchlistDestinationID(rawValue: "scope-changing")!
    let capabilities = WatchlistDestinationCapabilities(
        readable: true,
        writable: false,
        removable: false,
        bindingRequirement: .globalExternalIdentity,
        globalIdentityNamespaces: [.imdb]
    )
    private let lock = NSLock()
    private var scope = "account-a"

    var reconciliationScope: String {
        lock.lock()
        defer { lock.unlock() }
        return scope
    }

    func fetchEntries() async throws -> [WatchlistDestinationEntry] {
        lock.lock()
        scope = "account-b"
        lock.unlock()
        return []
    }

    func resolve(
        _ target: WatchlistMutationTarget
    ) async throws -> WatchlistDestinationBinding? {
        nil
    }

    func apply(
        _ desiredState: WatchlistDesiredState,
        to binding: WatchlistDestinationBinding
    ) async throws {}
}

private final class MutableScopeWatchlistDestination:
    WatchlistDestination, @unchecked Sendable {
    let id = WatchlistDestinationID(rawValue: "mutable-scope")!
    let capabilities = WatchlistDestinationCapabilities(
        readable: false,
        writable: true,
        removable: true,
        bindingRequirement: .globalExternalIdentity,
        globalIdentityNamespaces: [.imdb]
    )
    private let lock = NSLock()
    private var scope = "account-a"
    private var applied: [WatchlistDesiredState] = []

    var reconciliationScope: String {
        lock.lock()
        defer { lock.unlock() }
        return scope
    }

    func switchAccount() {
        lock.lock()
        scope = "account-b"
        lock.unlock()
    }

    func fetchEntries() async throws -> [WatchlistDestinationEntry] { [] }

    func resolve(
        _ target: WatchlistMutationTarget
    ) async throws -> WatchlistDestinationBinding? {
        WatchlistDestinationBinding(
            destinationID: id,
            opaqueValue: target.identityFingerprint
        )
    }

    func apply(
        _ desiredState: WatchlistDesiredState,
        to binding: WatchlistDestinationBinding
    ) async throws {
        lock.lock()
        applied.append(desiredState)
        lock.unlock()
    }

    func appliedStates() -> [WatchlistDesiredState] {
        lock.lock()
        defer { lock.unlock() }
        return applied
    }
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
