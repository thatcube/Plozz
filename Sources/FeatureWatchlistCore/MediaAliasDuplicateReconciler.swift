import CoreModels
import Foundation

public enum MediaAliasDuplicateReconciler {
    /// Collapses duplicate alias records, pointing losers at a winner.
    ///
    /// Runs on **every** ledger write, so its cost is paid by the viewer. It used
    /// to compare each record against every cluster built so far, rebuilding each
    /// cluster's members from the dictionary for every comparison. Measured on the
    /// Apple TV with 1,106 records: 5.5-8.2 seconds per write. The ledger is an
    /// actor, so a watchlist press queued behind whatever write was already in
    /// flight — which is why the button lagged for the first few presses after
    /// opening a show and was instant afterwards, once enrichment had drained.
    ///
    /// The clustering is now indexed by evidence. Same clusters, same winners:
    /// the index only narrows the candidates to those that could possibly share
    /// identity evidence, which is a precondition of the test the scan applied.
    public static func reconcile(
        _ input: [MediaAliasID: MediaAliasRecord]
    ) -> [MediaAliasID: MediaAliasRecord] {
        var records = input.mapValues { record -> MediaAliasRecord in
            var canonical = record.canonicalized()
            canonical.redirectTarget = nil
            return canonical
        }
        let ordered = records.values.sorted(by: wins)
        var clusters: [[MediaAliasID]] = []
        // Members kept alongside the ids so the inner test doesn't rebuild the
        // array — the original re-read every member out of the dictionary for
        // every cluster it examined, for every record.
        var members: [[MediaAliasRecord]] = []

        // Evidence -> clusters holding a member with that evidence.
        //
        // A cluster can only be chosen if one of its members shares identity
        // evidence with the record, and `sharesIdentityEvidence` says that means
        // a shared strong id, or a shared weak id when at least one side has no
        // strong ids at all. Those are exactly the three lookups below, so any
        // cluster missing from the union could not have matched — the scan was
        // asking the question of every cluster to get the same answer.
        var clustersByStrong: [MediaAliasStrongEvidence: Set<Int>] = [:]
        var clustersByWeak: [MediaAliasWeakEvidence: Set<Int>] = [:]
        /// Weak evidence of members carrying NO strong ids, which are the only
        /// ones a strongly-identified record may bridge to on weak evidence.
        var clustersByWeakWithoutStrong: [MediaAliasWeakEvidence: Set<Int>] = [:]

        for record in ordered {
            var candidates: Set<Int> = []
            if record.strongEvidence.isEmpty {
                for weak in record.weakEvidence {
                    if let found = clustersByWeak[weak] { candidates.formUnion(found) }
                }
            } else {
                for strong in record.strongEvidence {
                    if let found = clustersByStrong[strong] { candidates.formUnion(found) }
                }
                for weak in record.weakEvidence {
                    if let found = clustersByWeakWithoutStrong[weak] {
                        candidates.formUnion(found)
                    }
                }
            }

            // Ascending, because the original took the FIRST compatible cluster
            // and cluster order is meaningful — it follows `wins`.
            var joined: Int?
            for index in candidates.sorted() {
                let existing = members[index]
                if existing.contains(where: { sharesIdentityEvidence(record, $0) }),
                   existing.allSatisfy({ areCompatible(record, $0) }) {
                    joined = index
                    break
                }
            }

            let target: Int
            if let joined {
                clusters[joined].append(record.id)
                members[joined].append(record)
                target = joined
            } else {
                clusters.append([record.id])
                members.append([record])
                target = clusters.count - 1
            }

            for strong in record.strongEvidence {
                clustersByStrong[strong, default: []].insert(target)
            }
            for weak in record.weakEvidence {
                clustersByWeak[weak, default: []].insert(target)
                if record.strongEvidence.isEmpty {
                    clustersByWeakWithoutStrong[weak, default: []].insert(target)
                }
            }
        }

        for cluster in clusters where cluster.count > 1 {
            guard let winnerID = cluster.compactMap({ records[$0] })
                .sorted(by: wins)
                .first?
                .id else {
                continue
            }
            for loserID in cluster where loserID != winnerID {
                records[loserID]?.redirectTarget = winnerID
                records[loserID]?.canonicalize()
            }
        }
        return records
    }

    /// Two records are the same title when they share **strong** evidence, or when
    /// they share weak title/year evidence and at most one of them carries strong ids.
    ///
    /// The last clause is the guard. Two records that *both* carry strong ids in
    /// different namespaces — one IMDb-only, one TMDb-only — never "conflict" as far
    /// as `areCompatible` can tell, because a conflict needs the same namespace with
    /// different values. Sharing a title and year was therefore enough to merge two
    /// records that each had a perfectly good, and different, catalogue identity.
    ///
    /// A weak-only record bridging into one that has strong ids is still allowed and
    /// is the common case: the ledger writes weak evidence for titles that had nothing
    /// stronger at the time, and enrichment later gives one copy real ids.
    static func sharesIdentityEvidence(
        _ lhs: MediaAliasRecord,
        _ rhs: MediaAliasRecord
    ) -> Bool {
        if !Set(lhs.strongEvidence).isDisjoint(with: rhs.strongEvidence) { return true }
        guard lhs.strongEvidence.isEmpty || rhs.strongEvidence.isEmpty else {
            return false
        }
        return !Set(lhs.weakEvidence).isDisjoint(with: rhs.weakEvidence)
    }

    static func areCompatible(
        _ lhs: MediaAliasRecord,
        _ rhs: MediaAliasRecord
    ) -> Bool {
        lhs.kind == rhs.kind
            && !MediaAliasResolver.strongEvidenceConflicts(
                lhs.strongEvidence,
                rhs.strongEvidence
            )
    }

    static func wins(_ lhs: MediaAliasRecord, _ rhs: MediaAliasRecord) -> Bool {
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt < rhs.createdAt
        }
        return lhs.id < rhs.id
    }
}
