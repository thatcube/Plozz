import CoreModels
import Foundation

public enum MediaAliasLedgerError: Error, Equatable, Sendable {
    case aliasNotFound(MediaAliasID)
    case profileDeleted(String)
}

public struct MediaAliasEnrichment: Sendable {
    public let aliasID: MediaAliasID
    public let evidence: MediaAliasEvidence

    public init(aliasID: MediaAliasID, evidence: MediaAliasEvidence) {
        self.aliasID = aliasID
        self.evidence = evidence
    }
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
                locallyValidatedBindings: evidence.locallyValidatedBindings,
                localSources: evidence.localSources
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
        _ = try enrich([
            MediaAliasEnrichment(aliasID: aliasID, evidence: evidence)
        ])
    }

    /// Applies an identity-evidence wave in memory and persists/publishes once.
    @discardableResult
    public func enrich(_ enrichments: [MediaAliasEnrichment]) throws -> Int {
        var candidate = records
        var changedCount = 0
        let now = Date()
        for enrichment in enrichments {
            guard let resolved = currentSnapshot.resolvedAliasID(
                for: enrichment.aliasID
            ), let record = candidate[resolved] else {
                throw MediaAliasLedgerError.aliasNotFound(enrichment.aliasID)
            }
            let enriched = MediaAliasResolver.enriched(
                record,
                with: enrichment.evidence,
                at: now
            )
            guard enriched != record else { continue }
            candidate[resolved] = enriched
            changedCount += 1
        }
        guard changedCount > 0 else { return 0 }
        try persistAndPublish(candidate)
        return changedCount
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
