import CoreModels
import Foundation

public enum MediaAliasLedgerError: Error, Equatable, Sendable {
    case aliasNotFound(MediaAliasID)
    case profileDeleted(String)
}

public actor MediaAliasLedger: MediaAliasResolving {
    public typealias Snapshot = MediaAliasSnapshot

    public let profileID: String
    private let store: any MediaAliasStoring
    private let makeID: @Sendable () -> MediaAliasID
    private var records: [MediaAliasID: MediaAliasRecord]
    private var currentSnapshot: MediaAliasSnapshot

    public init(
        profileID: String,
        store: any MediaAliasStoring,
        makeID: @escaping @Sendable () -> MediaAliasID = { MediaAliasID() }
    ) throws {
        guard !profileID.isEmpty,
              profileID == profileID.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw DurableLocalStateError.invalidKey
        }
        self.profileID = profileID
        self.store = store
        self.makeID = makeID

        let loaded = try store.load()
        guard loaded.version == MediaAliasLedgerState.currentVersion,
              Set(loaded.records.map(\.id)).count == loaded.records.count else {
            throw DurableLocalStateError.malformedPayload
        }
        let original = Dictionary(
            uniqueKeysWithValues: loaded.records.map { ($0.id, $0) }
        )
        let reconciled = MediaAliasDuplicateReconciler.reconcile(original)
        if reconciled != original {
            try store.save(Self.state(from: reconciled))
        }
        records = reconciled
        currentSnapshot = MediaAliasSnapshot(records: Array(reconciled.values))
    }

    public func snapshot() -> MediaAliasSnapshot {
        currentSnapshot
    }

    public func lookup(
        evidence: MediaAliasEvidence,
        preferredAliasID: MediaAliasID? = nil
    ) -> MediaAliasID? {
        MediaAliasResolver.lookup(
            evidence: evidence,
            preferredAliasID: preferredAliasID,
            in: currentSnapshot
        )
    }

    public func resolveOrCreate(
        evidence: MediaAliasEvidence,
        preferredAliasID: MediaAliasID? = nil
    ) throws -> MediaAliasID {
        let now = Date()
        if let existing = lookup(
            evidence: evidence,
            preferredAliasID: preferredAliasID
        ) {
            guard let record = currentSnapshot.record(for: existing) else {
                throw DurableLocalStateError.malformedPayload
            }
            let enriched = MediaAliasResolver.enriched(record, with: evidence, at: now)
            if enriched != record {
                var candidate = records
                candidate[enriched.id] = enriched
                try persistAndPublish(candidate)
            }
            return existing
        }

        let id = makeID()
        guard records[id] == nil,
              let created = MediaAliasRecord(
                id: id,
                kind: evidence.kind,
                createdAt: now,
                strongEvidence: evidence.strong,
                weakEvidence: evidence.weak.map { [$0] } ?? [],
                presentation: evidence.presentation,
                bindingHints: evidence.bindingHints,
                locallyValidatedBindings: evidence.locallyValidatedBindings
              ) else {
            throw DurableLocalStateError.writeConflict
        }
        var candidate = records
        candidate[id] = created
        try persistAndPublish(candidate)
        return id
    }

    public func enrich(
        aliasID: MediaAliasID,
        with evidence: MediaAliasEvidence
    ) throws {
        guard let resolved = currentSnapshot.resolvedAliasID(for: aliasID),
              let record = records[resolved] else {
            throw MediaAliasLedgerError.aliasNotFound(aliasID)
        }
        let enriched = MediaAliasResolver.enriched(record, with: evidence, at: Date())
        guard enriched != record else { return }
        var candidate = records
        candidate[resolved] = enriched
        try persistAndPublish(candidate)
    }

    public func mergeRemote(
        records incoming: [MediaAliasSyncDTO],
        deletedAliasIDs: Set<MediaAliasID> = []
    ) throws {
        var candidate = records
        for id in deletedAliasIDs {
            candidate[id] = nil
        }
        for dto in incoming {
            guard let applied = dto.applying(to: candidate[dto.id]) else {
                throw DurableLocalStateError.malformedPayload
            }
            candidate[dto.id] = applied
        }
        candidate = MediaAliasDuplicateReconciler.reconcile(candidate)
        guard candidate != records else { return }
        try persistAndPublish(candidate, reconcile: false)
    }

    public func captureSyncDTOs() -> [MediaAliasSyncDTO] {
        records.values
            .sorted { $0.id < $1.id }
            .map(MediaAliasSyncDTO.init(record:))
    }

    public func removeForProfileDeletion() throws {
        try store.destructiveRemove()
        records = [:]
        currentSnapshot = .empty
    }

    private func persistAndPublish(
        _ candidate: [MediaAliasID: MediaAliasRecord],
        reconcile: Bool = true
    ) throws {
        let final = reconcile
            ? MediaAliasDuplicateReconciler.reconcile(candidate)
            : candidate
        try store.save(Self.state(from: final))
        records = final
        currentSnapshot = MediaAliasSnapshot(records: Array(final.values))
    }

    private static func state(
        from records: [MediaAliasID: MediaAliasRecord]
    ) -> MediaAliasLedgerState {
        MediaAliasLedgerState(records: records.values.sorted { $0.id < $1.id })
    }
}
