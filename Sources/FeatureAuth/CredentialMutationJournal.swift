import Foundation
import CoreModels

public enum CredentialMutationKind: String, Codable, Equatable, Sendable {
    case accountRemoval
    case credentialReplacement
    case generatedKeyPromotion
    case trustReplacement
}

public enum CredentialMutationPhase: String, Codable, Equatable, Sendable {
    /// Pending immutable credential/trust/child items are being validated. The
    /// active pointer has not moved and this phase may be rolled back.
    case staged
    /// The journal and active pointer moved together in one durable state write.
    case prepared
    /// The new pointer is authoritative; old item cleanup may finish after crash.
    case committed
}

public struct CredentialMutationEntry: Codable, Equatable, Sendable {
    public let id: UUID
    public let kind: CredentialMutationKind
    public let accountID: String
    public let previousRevision: CredentialRevision?
    public let pendingRevision: CredentialRevision?
    public let pendingChildItemIDs: [CredentialChildItemID]
    /// A previous credential known to be undecodable by this build. Once the new
    /// pointer commits, recovery may delete its raw vault item without decoding it.
    public let rawCredentialRevisionToDiscard: CredentialRevision?
    public let createdAt: Date
    public var phase: CredentialMutationPhase
}

extension CredentialMutationEntry: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "CredentialMutationEntry(kind: \(kind.rawValue), phase: \(phase.rawValue), childItems: \(pendingChildItemIDs.count))"
    }

    public var debugDescription: String { description }
}

public enum CredentialMutationRecoveryAction: Equatable, Sendable {
    case rollbackPending(CredentialMutationEntry)
    case completeCommitted(CredentialMutationEntry)
}

public enum CredentialMutationJournalError: Error, Equatable, Sendable {
    case activeRevisionConflict
    case invalidIdentifier
    case invalidMutation
    case invalidTransition
    case malformedState
    case mutationAlreadyInProgress
    case mutationNotFound
    case tooManyMutations
}

private struct CredentialMutationIndexState: DurableLocalStateValue, Equatable {
    static let durableLocalStateSchemaID = "com.plozz.credential-mutation-index.v1"

    var activeRevisions: [String: CredentialRevision] = [:]
    var mutations: [CredentialMutationEntry] = []
}

/// Durable active-revision index and crash-recovery journal.
///
/// `markPrepared` changes the journal phase and active account pointer in one
/// `DurableLocalStateStore` replacement. A crash therefore sees either staged
/// pending items that are safe to roll back, or an authoritative pointer that
/// must finish committing and retire the previous revision.
public final class CredentialMutationJournal: @unchecked Sendable {
    private static let maximumMutationCount = 128
    private static let maximumChildItemCount = 16
    /// Plozz has one process-wide writer. Sharing this lock across instances
    /// prevents a stale in-memory snapshot from replacing another instance's
    /// just-committed index update during tests, recovery, or composition churn.
    private static let processLock = NSLock()

    private let store: DurableLocalStateStore
    private let key: DurableLocalStateKey

    public init(store: DurableLocalStateStore) throws {
        self.store = store
        self.key = try DurableLocalStateKey(
            collection: .credentialMutationIndex,
            scope: .household
        )
        let loaded = try store.load(CredentialMutationIndexState.self, for: key)
            ?? CredentialMutationIndexState()
        try Self.validate(loaded)
    }

    public func seedActiveRevision(
        _ revision: CredentialRevision,
        accountID: String
    ) throws {
        try withLockedState { state in
            try Self.validateIdentifier(accountID)
            if let existing = state.activeRevisions[accountID] {
                guard existing == revision else {
                    throw CredentialMutationJournalError.activeRevisionConflict
                }
                return
            }
            guard !state.mutations.contains(where: { $0.accountID == accountID }) else {
                throw CredentialMutationJournalError.mutationAlreadyInProgress
            }
            state.activeRevisions[accountID] = revision
            try persist(state)
        }
    }

    @discardableResult
    public func begin(
        kind: CredentialMutationKind,
        accountID: String,
        previousRevision: CredentialRevision?,
        pendingRevision: CredentialRevision?,
        pendingChildItemIDs: [CredentialChildItemID] = [],
        rawCredentialRevisionToDiscard: CredentialRevision? = nil,
        mutationID: UUID = UUID(),
        createdAt: Date = Date()
    ) throws -> CredentialMutationEntry {
        try withLockedState { state in
            try Self.validateIdentifier(accountID)
            try Self.validateMutationShape(
                kind: kind,
                previousRevision: previousRevision,
                pendingRevision: pendingRevision,
                pendingChildItemIDs: pendingChildItemIDs,
                rawCredentialRevisionToDiscard:
                    rawCredentialRevisionToDiscard
            )
            if let existing = state.mutations.first(where: { $0.id == mutationID }) {
                guard existing.kind == kind,
                      existing.accountID == accountID,
                      existing.previousRevision == previousRevision,
                      existing.pendingRevision == pendingRevision,
                      existing.pendingChildItemIDs == pendingChildItemIDs,
                      existing.rawCredentialRevisionToDiscard
                        == rawCredentialRevisionToDiscard else {
                    throw CredentialMutationJournalError.invalidMutation
                }
                return existing
            }
            guard state.activeRevisions[accountID] == previousRevision else {
                throw CredentialMutationJournalError.activeRevisionConflict
            }
            guard !state.mutations.contains(where: { $0.accountID == accountID }) else {
                throw CredentialMutationJournalError.mutationAlreadyInProgress
            }
            guard state.mutations.count < Self.maximumMutationCount else {
                throw CredentialMutationJournalError.tooManyMutations
            }

            let entry = CredentialMutationEntry(
                id: mutationID,
                kind: kind,
                accountID: accountID,
                previousRevision: previousRevision,
                pendingRevision: pendingRevision,
                pendingChildItemIDs: pendingChildItemIDs,
                rawCredentialRevisionToDiscard: rawCredentialRevisionToDiscard,
                createdAt: createdAt,
                phase: .staged
            )
            state.mutations.append(entry)
            Self.sortMutations(&state.mutations)
            try persist(state)
            return entry
        }
    }

    @discardableResult
    public func markPrepared(_ mutationID: UUID) throws -> CredentialMutationEntry {
        try withLockedState { state in
            guard let index = state.mutations.firstIndex(where: { $0.id == mutationID }) else {
                throw CredentialMutationJournalError.mutationNotFound
            }
            if state.mutations[index].phase != .staged {
                return state.mutations[index]
            }

            let entry = state.mutations[index]
            guard state.activeRevisions[entry.accountID] == entry.previousRevision else {
                throw CredentialMutationJournalError.activeRevisionConflict
            }
            if let pendingRevision = entry.pendingRevision {
                state.activeRevisions[entry.accountID] = pendingRevision
            } else {
                state.activeRevisions[entry.accountID] = nil
            }
            state.mutations[index].phase = .prepared
            try persist(state)
            return state.mutations[index]
        }
    }

    @discardableResult
    public func markCommitted(_ mutationID: UUID) throws -> CredentialMutationEntry {
        try withLockedState { state in
            guard let index = state.mutations.firstIndex(where: { $0.id == mutationID }) else {
                throw CredentialMutationJournalError.mutationNotFound
            }
            switch state.mutations[index].phase {
            case .staged:
                throw CredentialMutationJournalError.invalidTransition
            case .prepared:
                state.mutations[index].phase = .committed
                try persist(state)
            case .committed:
                break
            }
            return state.mutations[index]
        }
    }

    @discardableResult
    public func rollbackStaged(_ mutationID: UUID) throws -> CredentialMutationEntry {
        try withLockedState { state in
            guard let index = state.mutations.firstIndex(where: { $0.id == mutationID }) else {
                throw CredentialMutationJournalError.mutationNotFound
            }
            guard state.mutations[index].phase == .staged else {
                throw CredentialMutationJournalError.invalidTransition
            }
            let entry = state.mutations.remove(at: index)
            try persist(state)
            return entry
        }
    }

    public func finishCommitted(_ mutationID: UUID) throws {
        try withLockedState { state in
            guard let index = state.mutations.firstIndex(where: { $0.id == mutationID }) else {
                throw CredentialMutationJournalError.mutationNotFound
            }
            guard state.mutations[index].phase == .committed else {
                throw CredentialMutationJournalError.invalidTransition
            }
            state.mutations.remove(at: index)
            try persist(state)
        }
    }

    public func activeRevision(accountID: String) throws -> CredentialRevision? {
        try withLoadedState { state in
            try Self.validateIdentifier(accountID)
            return state.activeRevisions[accountID]
        }
    }

    public func mutations() throws -> [CredentialMutationEntry] {
        try withLoadedState { $0.mutations }
    }

    public func recoveryActions() throws -> [CredentialMutationRecoveryAction] {
        try withLoadedState { state in
            state.mutations.map { entry in
                switch entry.phase {
                case .staged:
                    return .rollbackPending(entry)
                case .prepared, .committed:
                    return .completeCommitted(entry)
                }
            }
        }
    }

    private func persist(_ candidate: CredentialMutationIndexState) throws {
        try Self.validate(candidate)
        try store.save(candidate, for: key)
    }

    private func withLockedState<T>(
        _ body: (inout CredentialMutationIndexState) throws -> T
    ) throws -> T {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }
        var candidate = try loadState()
        return try body(&candidate)
    }

    private func withLoadedState<T>(
        _ body: (CredentialMutationIndexState) throws -> T
    ) throws -> T {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }
        return try body(loadState())
    }

    private func loadState() throws -> CredentialMutationIndexState {
        let loaded = try store.load(CredentialMutationIndexState.self, for: key)
            ?? CredentialMutationIndexState()
        try Self.validate(loaded)
        return loaded
    }

    private static func validate(_ state: CredentialMutationIndexState) throws {
        guard state.mutations.count <= maximumMutationCount,
              Set(state.mutations.map(\.id)).count == state.mutations.count,
              Set(state.mutations.map(\.accountID)).count == state.mutations.count else {
            throw CredentialMutationJournalError.malformedState
        }
        for accountID in state.activeRevisions.keys {
            try validateIdentifier(accountID)
        }
        for entry in state.mutations {
            try validateIdentifier(entry.accountID)
            try validateMutationShape(
                kind: entry.kind,
                previousRevision: entry.previousRevision,
                pendingRevision: entry.pendingRevision,
                pendingChildItemIDs: entry.pendingChildItemIDs,
                rawCredentialRevisionToDiscard:
                    entry.rawCredentialRevisionToDiscard
            )
            let active = state.activeRevisions[entry.accountID]
            switch entry.phase {
            case .staged:
                guard active == entry.previousRevision else {
                    throw CredentialMutationJournalError.malformedState
                }
            case .prepared, .committed:
                guard active == entry.pendingRevision else {
                    throw CredentialMutationJournalError.malformedState
                }
            }
        }
    }

    private static func validateMutationShape(
        kind: CredentialMutationKind,
        previousRevision: CredentialRevision?,
        pendingRevision: CredentialRevision?,
        pendingChildItemIDs: [CredentialChildItemID],
        rawCredentialRevisionToDiscard: CredentialRevision? = nil
    ) throws {
        guard pendingChildItemIDs.count <= maximumChildItemCount,
              Set(pendingChildItemIDs).count == pendingChildItemIDs.count,
              rawCredentialRevisionToDiscard == nil
                || rawCredentialRevisionToDiscard == previousRevision else {
            throw CredentialMutationJournalError.invalidMutation
        }
        switch kind {
        case .accountRemoval:
            guard previousRevision != nil,
                  pendingRevision == nil,
                  pendingChildItemIDs.isEmpty else {
                throw CredentialMutationJournalError.invalidMutation
            }
        case .credentialReplacement, .trustReplacement:
            guard let pendingRevision,
                  pendingRevision != previousRevision else {
                throw CredentialMutationJournalError.invalidMutation
            }
        case .generatedKeyPromotion:
            guard let pendingRevision,
                  pendingRevision != previousRevision,
                  !pendingChildItemIDs.isEmpty else {
                throw CredentialMutationJournalError.invalidMutation
            }
        }
    }

    private static func validateIdentifier(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == value,
              !value.isEmpty,
              value.utf8.count <= 512,
              value.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }) else {
            throw CredentialMutationJournalError.invalidIdentifier
        }
    }

    private static func sortMutations(_ mutations: inout [CredentialMutationEntry]) {
        mutations.sort {
            if $0.createdAt != $1.createdAt {
                return $0.createdAt < $1.createdAt
            }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
}
