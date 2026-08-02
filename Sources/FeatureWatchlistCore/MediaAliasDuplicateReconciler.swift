import CoreModels
import Foundation

public enum MediaAliasDuplicateReconciler {
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

        for record in ordered {
            let compatibleCluster = clusters.firstIndex { cluster in
                let members = cluster.compactMap { records[$0] }
                return members.contains { sharesIdentityEvidence(record, $0) }
                    && members.allSatisfy { areCompatible(record, $0) }
            }
            if let compatibleCluster {
                clusters[compatibleCluster].append(record.id)
            } else {
                clusters.append([record.id])
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
    private static func sharesIdentityEvidence(
        _ lhs: MediaAliasRecord,
        _ rhs: MediaAliasRecord
    ) -> Bool {
        if !Set(lhs.strongEvidence).isDisjoint(with: rhs.strongEvidence) { return true }
        guard lhs.strongEvidence.isEmpty || rhs.strongEvidence.isEmpty else {
            return false
        }
        return !Set(lhs.weakEvidence).isDisjoint(with: rhs.weakEvidence)
    }

    private static func areCompatible(
        _ lhs: MediaAliasRecord,
        _ rhs: MediaAliasRecord
    ) -> Bool {
        lhs.kind == rhs.kind
            && !MediaAliasResolver.strongEvidenceConflicts(
                lhs.strongEvidence,
                rhs.strongEvidence
            )
    }

    private static func wins(_ lhs: MediaAliasRecord, _ rhs: MediaAliasRecord) -> Bool {
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt < rhs.createdAt
        }
        return lhs.id < rhs.id
    }
}
