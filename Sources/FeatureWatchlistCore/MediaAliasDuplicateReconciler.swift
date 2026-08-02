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

    private static func sharesIdentityEvidence(
        _ lhs: MediaAliasRecord,
        _ rhs: MediaAliasRecord
    ) -> Bool {
        !Set(lhs.strongEvidence).isDisjoint(with: rhs.strongEvidence)
            || !Set(lhs.weakEvidence).isDisjoint(with: rhs.weakEvidence)
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
