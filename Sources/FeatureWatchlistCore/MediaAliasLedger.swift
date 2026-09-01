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

public struct MediaAliasResolutionRequest: Sendable {
    public let evidence: MediaAliasEvidence
    public let preferredAliasID: MediaAliasID?

    public init(
        evidence: MediaAliasEvidence,
        preferredAliasID: MediaAliasID? = nil
    ) {
        self.evidence = evidence
        self.preferredAliasID = preferredAliasID
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
        guard let resolved = try resolveOrCreate([
            MediaAliasResolutionRequest(
                evidence: evidence,
                preferredAliasID: preferredAliasID
            )
        ]).first else {
            throw DurableLocalStateError.malformedPayload
        }
        return resolved
    }

    /// Resolves one provider publication with one durable write and one snapshot
    /// rebuild. Newly created or enriched records are reconciled together, so
    /// entries in the same page can still collapse onto one canonical alias.
    public func resolveOrCreate(
        _ requests: [MediaAliasResolutionRequest]
    ) throws -> [MediaAliasID] {
        guard !requests.isEmpty else { return [] }
        let now = Date()
        let initialSnapshot = currentSnapshot
        var candidate = records
        var requestedIDs: [MediaAliasID] = []
        requestedIDs.reserveCapacity(requests.count)

        for request in requests {
            if let existing = MediaAliasResolver.lookup(
                evidence: request.evidence,
                preferredAliasID: request.preferredAliasID,
                in: initialSnapshot
            ) {
                guard let resolved = initialSnapshot.resolvedAliasID(for: existing),
                      let record = candidate[resolved] else {
                    throw DurableLocalStateError.malformedPayload
                }
                candidate[resolved] = MediaAliasResolver.enriched(
                    record,
                    with: request.evidence,
                    at: now
                )
                requestedIDs.append(resolved)
                continue
            }

            let id = makeID()
            guard candidate[id] == nil,
                  let created = MediaAliasRecord(
                    id: id,
                    kind: request.evidence.kind,
                    createdAt: now,
                    strongEvidence: request.evidence.strong,
                    weakEvidence: request.evidence.weak.map { [$0] } ?? [],
                    presentation: request.evidence.presentation,
                    bindingHints: request.evidence.bindingHints,
                    locallyValidatedBindings:
                        request.evidence.locallyValidatedBindings,
                    localSources: request.evidence.localSources
                  ) else {
                throw DurableLocalStateError.writeConflict
            }
            candidate[id] = created
            requestedIDs.append(id)
        }

        let final = MediaAliasDuplicateReconciler.reconcile(candidate)
        let finalSnapshot = MediaAliasSnapshot(records: Array(final.values))
        let resolvedIDs = try requestedIDs.map { requestedID in
            guard let resolved = finalSnapshot.resolvedAliasID(for: requestedID)
            else {
                throw DurableLocalStateError.malformedPayload
            }
            return resolved
        }
        if final != records {
            try persistAndPublish(final, reconcile: false)
        }
        return resolvedIDs
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

    /// Removes presentation art attached by the retired Home-watchlist seed.
    /// Identity/title/year remain; current Home/native sources supply fresh art.
    @discardableResult
    public func clearPresentationArtwork(
        aliasIDs: Set<MediaAliasID>
    ) throws -> Int {
        var candidate = records
        var changed = 0
        for aliasID in aliasIDs {
            let resolved = currentSnapshot.resolvedAliasID(for: aliasID)
                ?? aliasID
            guard var record = candidate[resolved],
                  record.presentation?.artworkURL != nil
                    || record.presentation?.backdropURL != nil
            else { continue }
            record.presentation?.artworkURL = nil
            record.presentation?.backdropURL = nil
            record.updatedAt = Date()
            record.canonicalize()
            candidate[resolved] = record
            changed += 1
        }
        guard changed > 0 else { return 0 }
        try persistAndPublish(candidate)
        return changed
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
