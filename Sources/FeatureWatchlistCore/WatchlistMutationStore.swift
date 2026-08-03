import CoreModels
import Foundation

public struct WatchlistMutationKey: Codable, Hashable, Sendable, Comparable {
    public let profileID: String
    public let aliasID: MediaAliasID
    public let destinationID: WatchlistDestinationID

    public init(
        profileID: String,
        aliasID: MediaAliasID,
        destinationID: WatchlistDestinationID
    ) {
        self.profileID = profileID
        self.aliasID = aliasID
        self.destinationID = destinationID
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.profileID != rhs.profileID { return lhs.profileID < rhs.profileID }
        if lhs.aliasID != rhs.aliasID { return lhs.aliasID < rhs.aliasID }
        return lhs.destinationID < rhs.destinationID
    }
}

public enum WatchlistMutationFailureClass: String, Codable, Hashable, Sendable {
    case transient
    case authentication
    case unsupportedIdentity
    case permanent
}

public enum WatchlistMutationPhase: String, Codable, Hashable, Sendable {
    case queued
    case retryScheduled
    case waitingForAuthentication
    case waitingForIdentity
    case permanentlyFailed
}

public struct WatchlistMutation: Codable, Hashable, Sendable {
    public let key: WatchlistMutationKey
    public var desiredState: WatchlistDesiredState
    public var target: WatchlistMutationTarget
    public var createdAt: Date
    public var updatedAt: Date
    public var attemptCount: Int
    public var nextAttemptAt: Date?
    public var phase: WatchlistMutationPhase
    public var lastFailureClass: WatchlistMutationFailureClass?

    public init(
        key: WatchlistMutationKey,
        desiredState: WatchlistDesiredState,
        target: WatchlistMutationTarget,
        createdAt: Date = Date()
    ) {
        self.key = key
        self.desiredState = desiredState
        self.target = target
        self.createdAt = createdAt
        updatedAt = createdAt
        attemptCount = 0
        nextAttemptAt = nil
        phase = .queued
        lastFailureClass = nil
    }

}

public struct WatchlistMutationEnqueueRequest: Sendable {
    public let profileID: String
    public let desiredState: WatchlistDesiredState
    public let target: WatchlistMutationTarget
    public let destinationID: WatchlistDestinationID

    public init(
        profileID: String,
        desiredState: WatchlistDesiredState,
        target: WatchlistMutationTarget,
        destinationID: WatchlistDestinationID
    ) {
        self.profileID = profileID
        self.desiredState = desiredState
        self.target = target
        self.destinationID = destinationID
    }
}

public struct WatchlistDestinationReconciliationState: Codable, Hashable, Sendable {
    public var explicitRemovalPending: Bool
    public var observedAbsenceAfterRemoval: Bool
    public var lastConfirmedAt: Date?
    /// What this destination was last confirmed to hold, and the identity it was
    /// confirmed under. Without this the queue has no memory that a destination
    /// already agrees, so every identity refresh re-sends the whole watchlist.
    /// Optional so records written before this existed still decode.
    public var lastConfirmedState: WatchlistDesiredState?
    public var lastConfirmedIdentity: String?

    public init(
        explicitRemovalPending: Bool = false,
        observedAbsenceAfterRemoval: Bool = false,
        lastConfirmedAt: Date? = nil,
        lastConfirmedState: WatchlistDesiredState? = nil,
        lastConfirmedIdentity: String? = nil
    ) {
        self.explicitRemovalPending = explicitRemovalPending
        self.observedAbsenceAfterRemoval = observedAbsenceAfterRemoval
        self.lastConfirmedAt = lastConfirmedAt
        self.lastConfirmedState = lastConfirmedState
        self.lastConfirmedIdentity = lastConfirmedIdentity
    }
}

public struct WatchlistMutationStoreState: Codable, Hashable, Sendable {
    public static let currentVersion = 1
    public var version: Int
    public var mutations: [WatchlistMutation]
    public var reconciliationStates:
        [WatchlistMutationKey: WatchlistDestinationReconciliationState]

    public init(
        version: Int = currentVersion,
        mutations: [WatchlistMutation] = [],
        reconciliationStates:
            [WatchlistMutationKey: WatchlistDestinationReconciliationState] = [:]
    ) {
        self.version = version
        self.mutations = mutations.sorted { $0.key < $1.key }
        self.reconciliationStates = reconciliationStates
    }
}

public protocol WatchlistMutationStateStoring: Sendable {
    func load() throws -> WatchlistMutationStoreState
    func save(_ state: WatchlistMutationStoreState) throws
}

public final class InMemoryWatchlistMutationStateStore:
    WatchlistMutationStateStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var state: WatchlistMutationStoreState

    public init(state: WatchlistMutationStoreState = .init()) {
        self.state = state
    }

    public func load() throws -> WatchlistMutationStoreState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    public func save(_ state: WatchlistMutationStoreState) throws {
        lock.lock()
        defer { lock.unlock() }
        self.state = state
    }
}

public final class AtomicWatchlistMutationStateStore:
    WatchlistMutationStateStoring, @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() throws -> WatchlistMutationStoreState {
        lock.lock()
        defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .init()
        }
        do {
            let state = try JSONDecoder().decode(
                WatchlistMutationStoreState.self,
                from: Data(contentsOf: fileURL, options: [.mappedIfSafe])
            )
            guard state.version == WatchlistMutationStoreState.currentVersion,
                  Set(state.mutations.map(\.key)).count == state.mutations.count
            else { throw DurableLocalStateError.malformedPayload }
            return state
        } catch let error as DurableLocalStateError {
            throw error
        } catch {
            throw DurableLocalStateError.malformedPayload
        }
    }

    public func save(_ state: WatchlistMutationStoreState) throws {
        lock.lock()
        defer { lock.unlock() }
        guard state.version == WatchlistMutationStoreState.currentVersion,
              Set(state.mutations.map(\.key)).count == state.mutations.count,
              let data = CanonicalJSON.encode(state)
        else { throw DurableLocalStateError.malformedPayload }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: [.atomic])
    }
}

public enum WatchlistNativeObservation: Equatable, Sendable {
    case noChange
    case ignorePresenceDuringExplicitRemoval
    case confirmedAbsence
    case nativeAddition
    case reassertPresent
}

public struct WatchlistNativeObservationRequest: Sendable {
    public let key: WatchlistMutationKey
    public let isPresent: Bool
    public let localDesiredState: WatchlistDesiredState
    /// True only when capabilities plus current binding/identity evidence make
    /// this destination a real target. Existing queued/prior state also targets.
    public let isEligibleTarget: Bool

    public init(
        key: WatchlistMutationKey,
        isPresent: Bool,
        localDesiredState: WatchlistDesiredState,
        isEligibleTarget: Bool
    ) {
        self.key = key
        self.isPresent = isPresent
        self.localDesiredState = localDesiredState
        self.isEligibleTarget = isEligibleTarget
    }
}

public struct WatchlistNativeObservationResult: Sendable, Equatable {
    public let key: WatchlistMutationKey
    public let observation: WatchlistNativeObservation
}

public actor DurableWatchlistMutationStore {
    private let store: any WatchlistMutationStateStoring
    private var state: WatchlistMutationStoreState

    public init(store: any WatchlistMutationStateStoring) throws {
        self.store = store
        state = try store.load()
        let originalStateCount = state.reconciliationStates.count
        let mutationKeys = Set(state.mutations.map(\.key))
        state.reconciliationStates = state.reconciliationStates.filter {
            $0.value.explicitRemovalPending
                || $0.value.observedAbsenceAfterRemoval
                || $0.value.lastConfirmedState != nil
                || mutationKeys.contains($0.key)
        }
        if state.reconciliationStates.count != originalStateCount {
            try store.save(state)
        }
    }

    public func enqueue(
        profileID: String,
        desiredState: WatchlistDesiredState,
        target: WatchlistMutationTarget,
        destinationID: WatchlistDestinationID,
        now: Date = Date()
    ) throws {
        try enqueueBatch(
            [
                WatchlistMutationEnqueueRequest(
                    profileID: profileID,
                    desiredState: desiredState,
                    target: target,
                    destinationID: destinationID
                )
            ],
            now: now
        )
    }

    public func enqueueBatch(
        _ requests: [WatchlistMutationEnqueueRequest],
        now: Date = Date()
    ) throws {
        guard !requests.isEmpty else { return }
        var mutationsByKey = Dictionary(
            uniqueKeysWithValues: state.mutations.map { ($0.key, $0) }
        )
        for request in requests {
            let key = WatchlistMutationKey(
                profileID: request.profileID,
                aliasID: request.target.aliasID,
                destinationID: request.destinationID
            )
            let existing = mutationsByKey[key]
            var mutation = existing
                ?? WatchlistMutation(
                    key: key,
                    desiredState: request.desiredState,
                    target: request.target,
                    createdAt: now
                )
            // Re-enqueueing is not the same as changing your mind. A periodic
            // sync sweep re-offers every entry it already knows about; blindly
            // resetting retry state there wiped every backoff, cooldown and
            // authentication park on each wave, so a disconnected or
            // rate-limited destination was hammered forever. Only a genuinely
            // new intent — a different desired state — earns a clean slate.
            let isNewIntent = existing.map { $0.desiredState != request.desiredState }
                ?? true
            let targetChanged = existing.map { $0.target != request.target } ?? true
            mutation.desiredState = request.desiredState
            mutation.target = request.target
            if isNewIntent {
                mutation.updatedAt = now
                mutation.attemptCount = 0
                mutation.nextAttemptAt = nil
                mutation.phase = .queued
                mutation.lastFailureClass = nil
            } else if targetChanged, mutation.phase == .waitingForIdentity {
                // Better ids arrived, so the reason it was parked may be gone.
                mutation.updatedAt = now
                mutation.nextAttemptAt = nil
                mutation.phase = .queued
                mutation.lastFailureClass = nil
            }
            mutationsByKey[key] = mutation

            if request.desiredState == .absent {
                var reconciliation = state.reconciliationStates[key] ?? .init()
                reconciliation.explicitRemovalPending = true
                reconciliation.observedAbsenceAfterRemoval = false
                state.reconciliationStates[key] = reconciliation
            } else {
                state.reconciliationStates[key] = nil
            }
        }
        state.mutations = mutationsByKey.values.sorted { $0.key < $1.key }
        try persist()
    }

    /// Counts confirmations rejected purely because the identity fingerprint
    /// moved. A steady stream means identity is churning between launches, which
    /// would silently re-send the whole watchlist every session.
    public private(set) var staleIdentitySuppressions = 0
    public private(set) var forgottenConfirmations = 0

    /// Whether a destination is already known to hold `desiredState` for this
    /// target under the same identity, making a write a no-op.
    public func isAlreadyConfirmed(
        _ key: WatchlistMutationKey,
        desiredState: WatchlistDesiredState,
        target: WatchlistMutationTarget
    ) -> Bool {
        guard let reconciliation = state.reconciliationStates[key],
              reconciliation.lastConfirmedState == desiredState
        else { return false }
        guard reconciliation.lastConfirmedIdentity == target.identityFingerprint
        else {
            staleIdentitySuppressions += 1
            return false
        }
        // A pending removal is unfinished business regardless of what was last
        // confirmed, so never suppress a write while one is outstanding.
        return !reconciliation.explicitRemovalPending
    }

    /// Drop confirmations for titles the watchlist no longer tracks.
    ///
    /// The map is keyed by (alias, destination), so without this it would grow
    /// with every title ever watchlisted rather than with the watchlist itself.
    @discardableResult
    public func forgetConfirmations(
        profileID: String,
        keepingAliasIDs kept: Set<MediaAliasID>
    ) throws -> Int {
        let mutationKeys = Set(state.mutations.map(\.key))
        let before = state.reconciliationStates.count
        state.reconciliationStates = state.reconciliationStates.filter { key, value in
            guard key.profileID == profileID else { return true }
            if mutationKeys.contains(key) { return true }
            if value.explicitRemovalPending || value.observedAbsenceAfterRemoval {
                return true
            }
            return kept.contains(key.aliasID)
        }
        let removed = before - state.reconciliationStates.count
        forgottenConfirmations += removed
        if removed > 0 { try persist() }
        return removed
    }

    public func ready(
        profileID: String,
        now: Date = Date(),
        limit: Int = 3
    ) -> [WatchlistMutation] {
        state.mutations.filter {
            $0.key.profileID == profileID
                && ($0.phase == .queued || $0.phase == .retryScheduled)
                && ($0.nextAttemptAt == nil || $0.nextAttemptAt! <= now)
        }.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt < $1.updatedAt }
            return $0.key < $1.key
        }.prefix(max(0, limit)).map { $0 }
    }

    public func markSucceeded(
        _ key: WatchlistMutationKey,
        now: Date = Date()
    ) throws {
        guard let mutation = state.mutations.first(where: { $0.key == key }) else {
            return
        }
        state.mutations.removeAll { $0.key == key }
        var reconciliation = state.reconciliationStates[key] ?? .init()
        reconciliation.lastConfirmedAt = now
        reconciliation.lastConfirmedState = mutation.desiredState
        reconciliation.lastConfirmedIdentity = mutation.target.identityFingerprint
        if mutation.desiredState == .present {
            // An add settles any pending-removal bookkeeping, but the
            // confirmation itself is kept so a later resync knows to stay quiet.
            reconciliation.explicitRemovalPending = false
            reconciliation.observedAbsenceAfterRemoval = false
        }
        state.reconciliationStates[key] = reconciliation
        try persist()
    }

    /// Push back **every** pending mutation for one destination.
    ///
    /// A destination-wide rejection (notably HTTP 429) is a property of the
    /// destination, not of the title that happened to be first in the queue.
    /// Backing off only that one title lets the rest of the queue march straight
    /// into the same limit, which is what turned a 19-title Plex sync into a
    /// self-sustaining retry storm. Only ever pushes an attempt later, never
    /// earlier, so it cannot shorten an existing backoff.
    @discardableResult
    public func deferDestination(
        _ destinationID: WatchlistDestinationID,
        until: Date
    ) throws -> Int {
        var deferred = 0
        for index in state.mutations.indices
        where state.mutations[index].key.destinationID == destinationID
            && state.mutations[index].phase != .permanentlyFailed {
            let current = state.mutations[index].nextAttemptAt
            guard current == nil || current! < until else { continue }
            state.mutations[index].nextAttemptAt = until
            deferred += 1
        }
        if deferred > 0 { try persist() }
        return deferred
    }

    public func markFailed(
        _ key: WatchlistMutationKey,
        classification: WatchlistMutationFailureClass,
        retryAt: Date?
    ) throws {
        guard var mutation = state.mutations.first(where: { $0.key == key }) else {
            return
        }
        mutation.attemptCount += 1
        mutation.nextAttemptAt = retryAt
        mutation.lastFailureClass = classification
        switch classification {
        case .transient: mutation.phase = .retryScheduled
        case .authentication: mutation.phase = .waitingForAuthentication
        case .unsupportedIdentity: mutation.phase = .waitingForIdentity
        case .permanent: mutation.phase = .permanentlyFailed
        }
        replace(mutation)
        try persist()
    }

    public func resumeAuthentication(destinationID: WatchlistDestinationID) throws {
        _ = try resumeAuthentication(destinationIDs: [destinationID])
    }

    /// Park every still-queued mutation for a destination that just reported it
    /// is not authenticated.
    ///
    /// Like a rate limit, missing authentication is a fact about the destination,
    /// not about one title — without this, a disconnected tracker is contacted
    /// once per queued title (observed: 73 pointless Trakt calls). `resume`
    /// un-parks them by phase, so this stays symmetric with reconnecting.
    @discardableResult
    public func parkDestinationForAuthentication(
        _ destinationID: WatchlistDestinationID
    ) throws -> Int {
        var parked = 0
        for index in state.mutations.indices
        where state.mutations[index].key.destinationID == destinationID
            && (state.mutations[index].phase == .queued
                || state.mutations[index].phase == .retryScheduled) {
            state.mutations[index].phase = .waitingForAuthentication
            state.mutations[index].nextAttemptAt = nil
            parked += 1
        }
        if parked > 0 { try persist() }
        return parked
    }

    @discardableResult
    public func resumeAuthentication(
        destinationIDs: Set<WatchlistDestinationID>
    ) throws -> Int {
        guard !destinationIDs.isEmpty else { return 0 }
        var resumed = 0
        for index in state.mutations.indices
        where destinationIDs.contains(state.mutations[index].key.destinationID)
            && state.mutations[index].phase == .waitingForAuthentication {
            state.mutations[index].phase = .queued
            state.mutations[index].nextAttemptAt = nil
            resumed += 1
        }
        if resumed > 0 { try persist() }
        return resumed
    }

    public func refreshTarget(
        profileID: String,
        target: WatchlistMutationTarget
    ) throws {
        try refreshTargets(profileID: profileID, targets: [target])
    }

    public func refreshTargets(
        profileID: String,
        targets: [WatchlistMutationTarget]
    ) throws {
        guard !targets.isEmpty else { return }
        let targetsByAlias = Dictionary(
            targets.map { ($0.aliasID, $0) },
            uniquingKeysWith: { _, newest in newest }
        )
        var changed = false
        for index in state.mutations.indices
        where state.mutations[index].key.profileID == profileID {
            guard let target = targetsByAlias[
                state.mutations[index].key.aliasID
            ] else { continue }
            let targetChanged = state.mutations[index].target != target
            if targetChanged {
                state.mutations[index].target = target
                changed = true
            }
            // Only better ids can change whether a destination can resolve this
            // title. Re-queueing on an identical refresh meant a destination
            // that will never resolve it was retried on every identity wave.
            if targetChanged, state.mutations[index].phase == .waitingForIdentity {
                state.mutations[index].phase = .queued
                state.mutations[index].nextAttemptAt = nil
                changed = true
            }
        }
        if changed { try persist() }
    }

    public func observeNative(
        key: WatchlistMutationKey,
        isPresent: Bool,
        localDesiredState: WatchlistDesiredState,
        now: Date = Date()
    ) throws -> WatchlistNativeObservation {
        try observeNativeBatch(
            [
                WatchlistNativeObservationRequest(
                    key: key,
                    isPresent: isPresent,
                    localDesiredState: localDesiredState,
                    isEligibleTarget: true
                )
            ],
            now: now
        ).first?.observation ?? .noChange
    }

    public func observeNativeBatch(
        _ requests: [WatchlistNativeObservationRequest],
        now: Date = Date()
    ) throws -> [WatchlistNativeObservationResult] {
        guard !requests.isEmpty else { return [] }
        var mutationsByKey = Dictionary(
            uniqueKeysWithValues: state.mutations.map { ($0.key, $0) }
        )
        var changed = false
        var results: [WatchlistNativeObservationResult] = []
        results.reserveCapacity(requests.count)

        for request in requests {
            let key = request.key
            let hadState = state.reconciliationStates[key] != nil
            let isTargeted = request.isEligibleTarget
                || hadState
                || mutationsByKey[key] != nil
            guard isTargeted else {
                results.append(.init(key: key, observation: .noChange))
                continue
            }

            var reconciliation = state.reconciliationStates[key] ?? .init()
            let observation: WatchlistNativeObservation
            if reconciliation.explicitRemovalPending {
                if request.isPresent {
                    observation = .ignorePresenceDuringExplicitRemoval
                } else {
                    reconciliation.explicitRemovalPending = false
                    reconciliation.observedAbsenceAfterRemoval = true
                    reconciliation.lastConfirmedAt = now
                    observation = .confirmedAbsence
                    if mutationsByKey[key]?.desiredState == .absent {
                        mutationsByKey[key] = nil
                    }
                    changed = true
                }
            } else if request.isPresent
                        && request.localDesiredState == .absent
                        && reconciliation.observedAbsenceAfterRemoval {
                reconciliation.observedAbsenceAfterRemoval = false
                observation = .nativeAddition
                changed = true
            } else if !request.isPresent
                        && request.localDesiredState == .present {
                observation = .reassertPresent
            } else {
                observation = .noChange
            }

            // Removal bookkeeping is transient; the confirmation of what a
            // destination holds is not. Clearing the whole record here erased
            // that memory on every native import, so the next resync re-sent
            // the entire watchlist. Keep the confirmation, drop only the
            // bookkeeping.
            if reconciliation.explicitRemovalPending
                || reconciliation.observedAbsenceAfterRemoval
                || reconciliation.lastConfirmedState != nil {
                if state.reconciliationStates[key] != reconciliation {
                    state.reconciliationStates[key] = reconciliation
                    changed = true
                }
            } else if state.reconciliationStates.removeValue(forKey: key) != nil {
                changed = true
            }
            results.append(.init(key: key, observation: observation))
        }

        // Observation bookkeeping is not a semantic tombstone. Drop obsolete
        // confirmed states once no queued mutation or absence boundary needs them.
        state.mutations = mutationsByKey.values.sorted { $0.key < $1.key }
        let liveKeys = Set(mutationsByKey.keys)
        let obsolete = state.reconciliationStates.filter {
            !$0.value.explicitRemovalPending
                && !$0.value.observedAbsenceAfterRemoval
                && $0.value.lastConfirmedState == nil
                && !liveKeys.contains($0.key)
        }.map(\.key)
        if !obsolete.isEmpty {
            for key in obsolete { state.reconciliationStates[key] = nil }
            changed = true
        }
        if changed { try persist() }
        return results
    }

    public func allMutations() -> [WatchlistMutation] {
        state.mutations
    }

    public func reconciliationState(
        for key: WatchlistMutationKey
    ) -> WatchlistDestinationReconciliationState {
        state.reconciliationStates[key] ?? .init()
    }

    public func isTargeted(_ key: WatchlistMutationKey) -> Bool {
        state.reconciliationStates[key] != nil
            || state.mutations.contains { $0.key == key }
    }

    public func targetedKeys(
        profileID: String
    ) -> Set<WatchlistMutationKey> {
        var keys = Set(state.mutations.lazy.filter {
            $0.key.profileID == profileID
        }.map(\.key))
        keys.formUnion(state.reconciliationStates.keys.lazy.filter {
            $0.profileID == profileID
        })
        return keys
    }

    public func earliestNextAttempt(profileID: String) -> Date? {
        if state.mutations.contains(where: {
            $0.key.profileID == profileID && $0.phase == .queued
        }) {
            return .distantPast
        }
        return state.mutations.lazy.filter {
            $0.key.profileID == profileID
                && $0.phase == .retryScheduled
                && $0.nextAttemptAt != nil
        }.compactMap(\.nextAttemptAt).min()
    }

    public func reconciliationStateCount(profileID: String? = nil) -> Int {
        guard let profileID else { return state.reconciliationStates.count }
        return state.reconciliationStates.keys.lazy.filter {
            $0.profileID == profileID
        }.count
    }

    public func removeProfile(_ profileID: String) throws {
        state.mutations.removeAll { $0.key.profileID == profileID }
        state.reconciliationStates = state.reconciliationStates.filter {
            $0.key.profileID != profileID
        }
        try persist()
    }

    private func replace(_ mutation: WatchlistMutation) {
        state.mutations.removeAll { $0.key == mutation.key }
        state.mutations.append(mutation)
        state.mutations.sort { $0.key < $1.key }
    }

    private func persist() throws {
        try store.save(state)
    }
}
