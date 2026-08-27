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

        // The viewer's own copy, on their own account. Consulted after the
        // catalogue ids (which are what actually merge two servers' copies into
        // one title) and before title/year, because "the same item id on the
        // same account" is a stronger statement than "same name, same year" —
        // and unlike title/year it cannot collide across accounts.
        //
        // Placed OUTSIDE the `evidence.strong.isEmpty` gate below on purpose: a
        // subject that carries a strong id which matched nothing is still the
        // viewer's own copy, and refusing to recognise it there would mint a
        // second alias for a title the ledger already holds.
        let localCandidates = Set(
            evidence.localSources.flatMap { snapshot.aliases(for: $0) }
        )
        if let match = uniqueCompatible(
            localCandidates,
            evidence: evidence,
            snapshot: snapshot
        ) {
            return match
        }

        guard let weak = evidence.weak else { return nil }
        // Rule 1 of `MediaItemIdentity`: **a strong id suppresses the title key.**
        // Falling back to title/year while the incoming item carries a catalogue id
        // would let an IMDb-only record and an unrelated TMDb-only record resolve to
        // one alias purely because they share a name and year.
        //
        // Rule 2 (title matching is movies-only) deliberately does **not** apply here,
        // and that is not an oversight. The merger asks "may I play this title from
        // that server", where a false match plays the wrong thing. The ledger asks "is
        // this the row the viewer already added", and weak evidence exists in it only
        // for titles that had nothing stronger to record. Refusing to match a series
        // by title would not make the ledger safer — it would make a series with no
        // external ids unfindable after a reload and mint a fresh duplicate UUID on
        // every launch, which is the unbounded-growth failure this ledger must not have.
        guard evidence.strong.isEmpty else { return nil }
        let weakCandidates = snapshot.aliases(for: weak)
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

        let priorLocalSources = result.localSources
        result.localSources.formUnion(evidence.localSources)
        changed = changed || priorLocalSources != result.localSources

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
                // Artwork is the one field here that must be allowed to CHANGE.
                //
                // Title and year are facts about a work and settle once. An
                // artwork URL is a fact about a server, and it goes stale: a
                // token expires, a server moves, or — as happened — a whole
                // watchlist gets pinned to URLs that pointed at a server which
                // had never heard of those titles. Written once and never
                // revisited, a bad URL is permanent, and no amount of fixing the
                // code that produces URLs can dislodge one that is already
                // stored. Every title in a watchlist wore one show's poster for
                // exactly that reason, and three separate corrections upstream
                // changed nothing on screen.
                //
                // So a newer answer wins. Artwork is cosmetic and cheap to
                // re-store, which makes "take the latest" both the safe rule and
                // the self-healing one: the next read repairs whatever the last
                // one got wrong, on every device, with no migration.
                if let incomingArtwork = incoming.artworkURL {
                    let sanitized = SyncURLSanitizer.sanitize(string: incomingArtwork)
                    if presentation.artworkURL != sanitized {
                        presentation.artworkURL = sanitized
                        changed = true
                    }
                }
                if let incomingBackdrop = incoming.backdropURL {
                    let sanitized = SyncURLSanitizer.sanitize(string: incomingBackdrop)
                    if presentation.backdropURL != sanitized {
                        presentation.backdropURL = sanitized
                        changed = true
                    }
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
