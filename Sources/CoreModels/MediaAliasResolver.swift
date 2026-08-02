import Foundation

public enum MediaAliasResolver {
    public static func lookup(
        evidence: MediaAliasEvidence,
        preferredAliasID: MediaAliasID? = nil,
        in snapshot: MediaAliasSnapshot
    ) -> MediaAliasID? {
        guard evidence.kind == .movie || evidence.kind == .series,
              !hasInternalStrongConflict(evidence.strong) else {
            return nil
        }

        if let preferredAliasID,
           let resolved = snapshot.resolvedAliasID(for: preferredAliasID),
           snapshot.recordsByID[resolved]?.kind == evidence.kind {
            return resolved
        }

        let bindingCandidates = Set(
            evidence.locallyValidatedBindings.flatMap { snapshot.aliases(for: $0) }
        )
        if let match = uniqueCompatible(
            bindingCandidates,
            evidence: evidence,
            snapshot: snapshot
        ) {
            return match
        }

        let strongCandidates = Set(
            evidence.strong.flatMap { snapshot.aliases(for: $0) }
        )
        if let match = uniqueCompatible(
            strongCandidates,
            evidence: evidence,
            snapshot: snapshot
        ) {
            return match
        }

        guard let weak = evidence.weak else { return nil }
        // Weak (title+year) matching obeys exactly the same two rules as
        // `MediaItemIdentity.identities(for:)`, so the ledger and the merger share one
        // ruleset instead of drifting apart:
        //
        // 1. **A strong id suppresses the title key.** Falling back to title/year while
        //    the incoming item carries a catalogue id would let an IMDb-only record and
        //    a TMDb-only record merge purely because they share a name and year.
        // 2. **Title matching is movies-only.** A series title is identical across a
        //    whole show and unreliable across localizations; the merger never
        //    title-matches series and neither may the ledger.
        guard evidence.strong.isEmpty, evidence.kind == .movie else { return nil }
        let weakCandidates = snapshot.aliases(for: weak).filter { candidate in
            guard let record = snapshot.record(for: candidate) else { return false }
            return record.strongEvidence.isEmpty
        }
        guard !hasTransitiveSplitRisk(weakCandidates, snapshot: snapshot) else {
            return nil
        }
        return uniqueCompatible(
            weakCandidates,
            evidence: evidence,
            snapshot: snapshot
        )
    }

    public static func enriched(
        _ record: MediaAliasRecord,
        with evidence: MediaAliasEvidence,
        at now: Date
    ) -> MediaAliasRecord {
        guard record.kind == evidence.kind, record.redirectTarget == nil else {
            return record
        }
        var result = record
        var changed = false

        var detectedConflicts: [MediaAliasConflict] = []
        for incoming in evidence.strong {
            let values = Set(result.strongEvidence.lazy
                .filter { $0.namespace == incoming.namespace }
                .map(\.value))
            if !values.isEmpty, !values.contains(incoming.value) {
                for existing in values.sorted() {
                    detectedConflicts.append(MediaAliasConflict(
                        kind: .strongEvidence,
                        namespace: incoming.namespace,
                        existingValue: existing,
                        rejectedValue: incoming.value,
                        recordedAt: now
                    ))
                }
            }
        }
        if !detectedConflicts.isEmpty {
            for conflict in detectedConflicts {
                let alreadyRecorded = result.conflicts.contains {
                    $0.kind == conflict.kind
                        && $0.namespace == conflict.namespace
                        && $0.existingValue == conflict.existingValue
                        && $0.rejectedValue == conflict.rejectedValue
                }
                if !alreadyRecorded {
                    result.conflicts.append(conflict)
                    changed = true
                }
            }
            if changed {
                result.updatedAt = max(result.updatedAt, now)
                result.canonicalize()
            }
            return result
        }

        for incoming in evidence.strong {
            if !result.strongEvidence.contains(incoming) {
                result.strongEvidence.append(incoming)
                changed = true
            }
        }

        if let weak = evidence.weak, !result.weakEvidence.contains(weak) {
            result.weakEvidence.append(weak)
            changed = true
        }

        var hints = Dictionary(
            uniqueKeysWithValues: result.bindingHints.map { ($0.binding, $0) }
        )
        for hint in evidence.bindingHints where hints[hint.binding] == nil {
            hints[hint.binding] = hint
            changed = true
        }
        result.bindingHints = hints.values.sorted()
        let priorValidation = result.locallyValidatedBindings
        result.locallyValidatedBindings.formUnion(evidence.locallyValidatedBindings)
        result.locallyValidatedBindings.formIntersection(Set(hints.keys))
        changed = changed || priorValidation != result.locallyValidatedBindings

        if let incoming = evidence.presentation {
            if result.presentation == nil {
                result.presentation = incoming.sanitizedForSync()
                changed = true
            } else {
                var presentation = result.presentation!
                if presentation.title.isEmpty, !incoming.title.isEmpty {
                    presentation.title = incoming.title
                    changed = true
                }
                if presentation.year == nil, incoming.year != nil {
                    presentation.year = incoming.year
                    changed = true
                }
                if presentation.artworkURL == nil, incoming.artworkURL != nil {
                    presentation.artworkURL = SyncURLSanitizer.sanitize(
                        string: incoming.artworkURL
                    )
                    changed = true
                }
                if presentation.backdropURL == nil, incoming.backdropURL != nil {
                    presentation.backdropURL = SyncURLSanitizer.sanitize(
                        string: incoming.backdropURL
                    )
                    changed = true
                }
                result.presentation = presentation
            }
        }

        if changed {
            result.updatedAt = max(result.updatedAt, now)
            result.canonicalize()
        }
        return result
    }

    public static func strongEvidenceConflicts(
        _ lhs: [MediaAliasStrongEvidence],
        _ rhs: [MediaAliasStrongEvidence]
    ) -> Bool {
        let lhsByNamespace = Dictionary(grouping: lhs, by: \.namespace)
        let rhsByNamespace = Dictionary(grouping: rhs, by: \.namespace)
        for namespace in Set(lhsByNamespace.keys).intersection(rhsByNamespace.keys) {
            let lhsValues = Set(lhsByNamespace[namespace, default: []].map(\.value))
            let rhsValues = Set(rhsByNamespace[namespace, default: []].map(\.value))
            if lhsValues.isDisjoint(with: rhsValues) {
                return true
            }
        }
        return false
    }

    private static func uniqueCompatible(
        _ candidates: Set<MediaAliasID>,
        evidence: MediaAliasEvidence,
        snapshot: MediaAliasSnapshot
    ) -> MediaAliasID? {
        let compatible = Set(candidates.compactMap { candidate -> MediaAliasID? in
            guard let resolved = snapshot.resolvedAliasID(for: candidate),
                  let record = snapshot.recordsByID[resolved],
                  record.kind == evidence.kind,
                  !hasInternalStrongConflict(record.strongEvidence),
                  !strongEvidenceConflicts(record.strongEvidence, evidence.strong) else {
                return nil
            }
            return resolved
        })
        return compatible.count == 1 ? compatible.first : nil
    }

    private static func hasInternalStrongConflict(
        _ evidence: [MediaAliasStrongEvidence]
    ) -> Bool {
        Dictionary(grouping: evidence, by: \.namespace)
            .values
            .contains { Set($0.map(\.value)).count > 1 }
    }

    private static func hasTransitiveSplitRisk(
        _ candidates: Set<MediaAliasID>,
        snapshot: MediaAliasSnapshot
    ) -> Bool {
        let records = candidates.compactMap { snapshot.record(for: $0) }
        for left in records.indices {
            for right in records.indices where right > left {
                if strongEvidenceConflicts(
                    records[left].strongEvidence,
                    records[right].strongEvidence
                ) {
                    return true
                }
            }
        }
        return false
    }
}
