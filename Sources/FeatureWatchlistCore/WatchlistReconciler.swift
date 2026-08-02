import CoreModels
import Foundation

public struct WatchlistDestinationStatus: Equatable, Sendable {
    public let queuedCount: Int
    public let retryCount: Int
    public let authenticationRequiredCount: Int
    public let pendingIdentityCount: Int
    public let permanentFailureCount: Int

    public init(mutations: [WatchlistMutation]) {
        queuedCount = mutations.filter { $0.phase == .queued }.count
        retryCount = mutations.filter { $0.phase == .retryScheduled }.count
        authenticationRequiredCount = mutations.filter {
            $0.phase == .waitingForAuthentication
        }.count
        pendingIdentityCount = mutations.filter {
            $0.phase == .waitingForIdentity
        }.count
        permanentFailureCount = mutations.filter {
            $0.phase == .permanentlyFailed
        }.count
    }
}

/// Aggregate-only telemetry. No titles, account names, URLs, tokens, usernames,
/// destination identifiers, or provider-local item identifiers can enter it.
public struct WatchlistDiagnosticsValues: Equatable, Sendable {
    public let queueDepth: Int
    public let oldestMutationAge: TimeInterval?
    public let transientFailureCount: Int
    public let authenticationFailureCount: Int
    public let unsupportedIdentityCount: Int
    public let permanentFailureCount: Int
}

public struct WatchlistNativeRead: Sendable {
    public let destinationID: WatchlistDestinationID
    public let entries: [WatchlistDestinationEntry]

    public init(
        destinationID: WatchlistDestinationID,
        entries: [WatchlistDestinationEntry]
    ) {
        self.destinationID = destinationID
        self.entries = entries
    }
}

public struct WatchlistNativeReadFailure: Sendable {
    public let destinationID: WatchlistDestinationID
    public let classification: WatchlistMutationFailureClass
}

public struct WatchlistNativeReadReport: Sendable {
    public let successes: [WatchlistNativeRead]
    public let failures: [WatchlistNativeReadFailure]
}

public struct WatchlistNativeReconciliationCandidate: Sendable {
    public let aliasID: MediaAliasID
    public let isPresent: Bool
    public let localDesiredState: WatchlistDesiredState
    public let target: WatchlistMutationTarget?

    public init(
        aliasID: MediaAliasID,
        isPresent: Bool,
        localDesiredState: WatchlistDesiredState,
        target: WatchlistMutationTarget?
    ) {
        self.aliasID = aliasID
        self.isPresent = isPresent
        self.localDesiredState = localDesiredState
        self.target = target
    }

}

public struct WatchlistIdentityEvidenceChange: Sendable {
    public let desiredState: WatchlistDesiredState
    public let target: WatchlistMutationTarget

    public init(
        desiredState: WatchlistDesiredState,
        target: WatchlistMutationTarget
    ) {
        self.desiredState = desiredState
        self.target = target
    }
}

public actor WatchlistReconciler {
    private enum DrainResult {
        case busy
        case processed(Int)
    }

    private struct DestinationTitleKey: Hashable {
        let destinationID: WatchlistDestinationID
        let aliasID: MediaAliasID
    }

    public static let maximumConcurrentReads = 4
    public static let maximumConcurrentWrites = 3

    private let registry: WatchlistDestinationRegistry
    private let mutationStore: DurableWatchlistMutationStore
    private let retryPolicy: WatchlistRetryPolicy
    private var activeProfileIDs: Set<String> = []
    private var inFlightKeys: Set<DestinationTitleKey> = []
    private var isReadingNativeEntries = false

    public init(
        registry: WatchlistDestinationRegistry,
        mutationStore: DurableWatchlistMutationStore,
        retryPolicy: WatchlistRetryPolicy = .init()
    ) {
        self.registry = registry
        self.mutationStore = mutationStore
        self.retryPolicy = retryPolicy
    }

    public func enqueueFanOut(
        profileID: String,
        desiredState: WatchlistDesiredState,
        target: WatchlistMutationTarget,
        now: Date = Date()
    ) async throws {
        var requests: [WatchlistMutationEnqueueRequest] = []
        for destinationID in registry.destinationIDs(for: target) {
            guard let destination = registry[destinationID] else { continue }
            let capabilities = destination.capabilities
            guard capabilities.accepts(target.kind),
                  capabilities.write.isWritable,
                  desiredState != .absent || capabilities.write.isRemovable
            else { continue }
            requests.append(.init(
                profileID: profileID,
                desiredState: desiredState,
                target: target,
                destinationID: destination.id
            ))
        }
        try await mutationStore.enqueueBatch(requests, now: now)
    }

    public func enqueue(
        profileID: String,
        desiredState: WatchlistDesiredState,
        target: WatchlistMutationTarget,
        destinationID: WatchlistDestinationID,
        now: Date = Date()
    ) async throws {
        guard let destination = registry[destinationID],
              destination.capabilities.accepts(target.kind),
              destination.capabilities.write.isWritable,
              desiredState != .absent
                || destination.capabilities.write.isRemovable else {
            return
        }
        try await mutationStore.enqueue(
            profileID: profileID,
            desiredState: desiredState,
            target: target,
            destinationID: destinationID,
            now: now
        )
    }

    public func enqueue(
        profileID: String,
        desiredState: WatchlistDesiredState,
        targets: [WatchlistMutationTarget],
        destinationID: WatchlistDestinationID,
        now: Date = Date()
    ) async throws {
        guard let destination = registry[destinationID] else { return }
        let requests = targets.compactMap {
            target -> WatchlistMutationEnqueueRequest? in
            guard destination.capabilities.accepts(target.kind),
                  destination.capabilities.write.isWritable,
                  desiredState != .absent
                    || destination.capabilities.write.isRemovable else {
                return nil
            }
            return WatchlistMutationEnqueueRequest(
                profileID: profileID,
                desiredState: desiredState,
                target: target,
                destinationID: destinationID
            )
        }
        try await mutationStore.enqueueBatch(requests, now: now)
    }

    /// Identity-index/alias-ledger notification hook. Refreshing evidence wakes
    /// unsupported-identity work and also fans out to newly eligible destinations.
    public func identityEvidenceChanged(
        profileID: String,
        desiredState: WatchlistDesiredState,
        target: WatchlistMutationTarget,
        now: Date = Date()
    ) async throws {
        try await identityEvidenceChanged(
            profileID: profileID,
            changes: [
                WatchlistIdentityEvidenceChange(
                    desiredState: desiredState,
                    target: target
                )
            ],
            now: now
        )
    }

    public func identityEvidenceChanged(
        profileID: String,
        changes: [WatchlistIdentityEvidenceChange],
        now: Date = Date()
    ) async throws {
        guard !changes.isEmpty else { return }
        try await mutationStore.refreshTargets(
            profileID: profileID,
            targets: changes.map(\.target)
        )
        var requests: [WatchlistMutationEnqueueRequest] = []
        for change in changes {
            for destinationID in registry.destinationIDs(for: change.target) {
                guard let destination = registry[destinationID],
                      change.desiredState != .absent
                        || destination.capabilities.write.isRemovable else {
                    continue
                }
                requests.append(.init(
                    profileID: profileID,
                    desiredState: change.desiredState,
                    target: change.target,
                    destinationID: destinationID
                ))
            }
        }
        try await mutationStore.enqueueBatch(requests, now: now)
    }

    /// Drains at most three writes. Calls are serialized per profile, and the
    /// durable composite key prevents duplicate destination/title work.
    @discardableResult
    public func drain(
        profileID: String,
        now: Date = Date()
    ) async -> Int {
        switch await drainResult(profileID: profileID, now: now) {
        case .busy: return 0
        case .processed(let count): return count
        }
    }

    public func drainForRetryScheduler(
        profileID: String,
        now: Date = Date()
    ) async -> WatchlistRetryDrainOutcome {
        switch await drainResult(profileID: profileID, now: now) {
        case .busy: return .busy
        case .processed: return .completed
        }
    }

    private func drainResult(
        profileID: String,
        now: Date
    ) async -> DrainResult {
        guard activeProfileIDs.insert(profileID).inserted else { return .busy }
        defer { activeProfileIDs.remove(profileID) }
        let availableWriteSlots = max(
            0,
            Self.maximumConcurrentWrites - inFlightKeys.count
        )
        guard availableWriteSlots > 0 else { return .processed(0) }
        let ready = await mutationStore.ready(
            profileID: profileID,
            now: now,
            limit: availableWriteSlots
        )
        var processed = 0
        for mutation in ready {
            let inFlightKey = DestinationTitleKey(
                destinationID: mutation.key.destinationID,
                aliasID: mutation.key.aliasID
            )
            guard inFlightKeys.insert(inFlightKey).inserted else { continue }
            await process(mutation, now: now)
            inFlightKeys.remove(inFlightKey)
            processed += 1
        }
        return .processed(processed)
    }

    public func fetchNativeEntries() async -> WatchlistNativeReadReport {
        guard !isReadingNativeEntries else {
            return WatchlistNativeReadReport(successes: [], failures: [])
        }
        isReadingNativeEntries = true
        defer { isReadingNativeEntries = false }
        let readable = registry.destinations.filter {
            $0.capabilities.read.isReadable
        }
        var successes: [WatchlistNativeRead] = []
        var failures: [WatchlistNativeReadFailure] = []
        for start in stride(
            from: 0,
            to: readable.count,
            by: Self.maximumConcurrentReads
        ) {
            let batch = Array(
                readable[start..<min(
                    start + Self.maximumConcurrentReads,
                    readable.count
                )]
            )
            await withTaskGroup(of: NativeReadResult.self) { group in
                for destination in batch {
                    group.addTask {
                        do {
                            return .success(
                                WatchlistNativeRead(
                                    destinationID: destination.id,
                                    entries: try await destination.fetchEntries()
                                )
                            )
                        } catch {
                            return .failure(
                                destination.id,
                                Self.classifyReadFailure(error)
                            )
                        }
                    }
                }
                for await result in group {
                    switch result {
                    case .success(let read): successes.append(read)
                    case .failure(let id, let classification):
                        failures.append(.init(
                            destinationID: id,
                            classification: classification
                        ))
                    }
                }
            }
        }
        return WatchlistNativeReadReport(
            successes: successes.sorted { $0.destinationID < $1.destinationID },
            failures: failures.sorted { $0.destinationID < $1.destinationID }
        )
    }

    /// Applies the explicit-removal suppression and observed-absence boundary.
    /// Caller resolves native entries to aliases and performs returned additive
    /// import/reassert action through ``WatchlistModel``.
    public func observeNativePresence(
        profileID: String,
        destinationID: WatchlistDestinationID,
        aliasID: MediaAliasID,
        isPresent: Bool,
        localDesiredState: WatchlistDesiredState,
        now: Date = Date()
    ) async throws -> WatchlistNativeObservation {
        try await mutationStore.observeNative(
            key: WatchlistMutationKey(
                profileID: profileID,
                aliasID: aliasID,
                destinationID: destinationID
            ),
            isPresent: isPresent,
            localDesiredState: localDesiredState,
            now: now
        )
    }

    /// Reconciles one destination read with one durable write. Candidates that
    /// cannot target this destination and have no queued/prior boundary state are
    /// ignored without creating bookkeeping.
    public func observeNativeBatch(
        profileID: String,
        destinationID: WatchlistDestinationID,
        candidates: [WatchlistNativeReconciliationCandidate],
        now: Date = Date()
    ) async throws -> [MediaAliasID: WatchlistNativeObservation] {
        guard let destination = registry[destinationID] else { return [:] }
        var requests: [WatchlistNativeObservationRequest] = []
        requests.reserveCapacity(candidates.count)
        for candidate in candidates {
            let key = WatchlistMutationKey(
                profileID: profileID,
                aliasID: candidate.aliasID,
                destinationID: destinationID
            )
            let wasTargeted = await mutationStore.isTargeted(key)
            var eligible = wasTargeted
            if !eligible,
               let target = candidate.target {
                eligible = registry.destinationIDs(for: target)
                    .contains(destinationID)
                    && (candidate.localDesiredState != .absent
                        || destination.capabilities.write.isRemovable)
            }
            requests.append(.init(
                key: key,
                isPresent: candidate.isPresent,
                localDesiredState: candidate.localDesiredState,
                isEligibleTarget: eligible
            ))
        }
        return Dictionary(
            uniqueKeysWithValues: try await mutationStore.observeNativeBatch(
                requests,
                now: now
            ).map { ($0.key.aliasID, $0.observation) }
        )
    }

    @discardableResult
    public func resumeAuthentication() async throws -> Int {
        try await mutationStore.resumeAuthentication(
            destinationIDs: Set(registry.destinations.map(\.id))
        )
    }

    public func earliestNextAttempt(profileID: String) async -> Date? {
        await mutationStore.earliestNextAttempt(profileID: profileID)
    }

    public func eligibleDestinationIDs(
        for target: WatchlistMutationTarget
    ) -> Set<WatchlistDestinationID> {
        registry.destinationIDs(for: target)
    }

    public func targetedKeys(
        profileID: String
    ) async -> Set<WatchlistMutationKey> {
        await mutationStore.targetedKeys(profileID: profileID)
    }

    public func status(profileID: String) async -> WatchlistDestinationStatus {
        WatchlistDestinationStatus(
            mutations: await mutationStore.allMutations().filter {
                $0.key.profileID == profileID
            }
        )
    }

    public func diagnostics(
        profileID: String,
        now: Date = Date()
    ) async -> WatchlistDiagnosticsValues {
        let mutations = await mutationStore.allMutations().filter {
            $0.key.profileID == profileID
        }
        return WatchlistDiagnosticsValues(
            queueDepth: mutations.count,
            oldestMutationAge: mutations.map {
                max(0, now.timeIntervalSince($0.createdAt))
            }.max(),
            transientFailureCount: mutations.filter {
                $0.lastFailureClass == .transient
            }.count,
            authenticationFailureCount: mutations.filter {
                $0.lastFailureClass == .authentication
            }.count,
            unsupportedIdentityCount: mutations.filter {
                $0.lastFailureClass == .unsupportedIdentity
            }.count,
            permanentFailureCount: mutations.filter {
                $0.lastFailureClass == .permanent
            }.count
        )
    }

    private func process(
        _ mutation: WatchlistMutation,
        now: Date
    ) async {
        guard let destination = registry[mutation.key.destinationID] else {
            try? await mutationStore.markFailed(
                mutation.key,
                classification: .permanent,
                retryAt: nil
            )
            return
        }
        do {
            guard destination.capabilities.accepts(mutation.target.kind) else {
                throw WatchlistDestinationError.permanent
            }
            guard mutation.desiredState != .absent
                    || destination.capabilities.write.isRemovable else {
                throw WatchlistDestinationError.permanent
            }
            guard let binding = try await destination.resolve(mutation.target) else {
                throw WatchlistDestinationError.unsupportedIdentity
            }
            try await destination.apply(mutation.desiredState, to: binding)
            try await mutationStore.markSucceeded(mutation.key, now: now)
        } catch {
            let decision = retryPolicy.decision(
                for: error,
                attempt: mutation.attemptCount
            )
            try? await mutationStore.markFailed(
                mutation.key,
                classification: decision.classification,
                retryAt: decision.retryDelay.map { now.addingTimeInterval($0) }
            )
        }
    }

    private static func classifyReadFailure(
        _ error: Error
    ) -> WatchlistMutationFailureClass {
        WatchlistRetryPolicy().decision(
            for: error,
            attempt: 0,
            jitterUnit: 0.5
        ).classification
    }

    private enum NativeReadResult: Sendable {
        case success(WatchlistNativeRead)
        case failure(WatchlistDestinationID, WatchlistMutationFailureClass)
    }
}
