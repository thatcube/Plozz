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

    /// Two records may be considered the same title when they share **strong**
    /// evidence, or — under exactly the merger's rules — when they share weak
    /// title/year evidence *and* neither carries any strong id, *and* they are movies.
    ///
    /// Without those two guards a shared title+year would merge an IMDb-only record
    /// with an unrelated TMDb-only record (different namespaces never "conflict", so
    /// `areCompatible` waves them through), and would title-match series, which the
    /// merger deliberately never does because a series title is identical across a
    /// whole show and unreliable across localizations.
    private static func sharesIdentityEvidence(
        _ lhs: MediaAliasRecord,
        _ rhs: MediaAliasRecord
    ) -> Bool {
        if !Set(lhs.strongEvidence).isDisjoint(with: rhs.strongEvidence) { return true }
        guard lhs.strongEvidence.isEmpty,
              rhs.strongEvidence.isEmpty,
              lhs.kind == .movie,
              rhs.kind == .movie else {
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
