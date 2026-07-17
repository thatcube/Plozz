import CoreModels
import Foundation

struct ShareLocalMetadataFieldCandidate: Sendable, Equatable {
    var field: MetadataField
    var valueJSON: String
    var source: MetadataSource
    var sourceRevision: String?
}

struct ShareLocalMetadataSidecarValues: Sendable, Equatable {
    var relPath: String
    var kind: LocalSidecarKind
    var status: String
    var fingerprint: String?
    var values: [MetadataField: String]
}

/// Pure per-field winner selection for cached NFO values.
enum ShareLocalMetadataWinnerResolver {
    static func resolve(
        _ sidecars: [ShareLocalMetadataSidecarValues]
    ) -> [ShareLocalMetadataFieldCandidate] {
        let ranked = sidecars
            .filter { $0.status == "parsed" }
            .sorted {
                let leftRank = $0.kind == .movieGeneric ? 1 : 0
                let rightRank = $1.kind == .movieGeneric ? 1 : 0
                return leftRank == rightRank ? $0.relPath < $1.relPath : leftRank < rightRank
            }
        var winners: [MetadataField: ShareLocalMetadataFieldCandidate] = [:]
        for sidecar in ranked {
            let revision = sourceRevision(
                relPath: sidecar.relPath,
                fingerprint: sidecar.fingerprint
            )
            for (field, valueJSON) in sidecar.values where winners[field] == nil {
                winners[field] = .init(
                    field: field,
                    valueJSON: valueJSON,
                    source: .localNFO,
                    sourceRevision: revision
                )
            }
        }
        return Array(winners.values)
    }

    static func sourceRevision(relPath: String, fingerprint: String?) -> String {
        let path = Data(relPath.utf8).base64EncodedString()
        let revision = Data((fingerprint ?? "unknown").utf8).base64EncodedString()
        return "\(path).\(revision)"
    }
}

struct ShareLocalMetadataParsedSidecar: Sendable, Equatable {
    var sourceRevision: String
    var itemID: String?
}

struct ShareLocalMetadataStoredValue: Sendable, Equatable {
    var itemID: String
    var sourceRevision: String?
}

/// Identifies only projections that can be inconsistent after a crash or policy
/// version change, avoiding a full startup rematerialization.
enum ShareLocalMetadataRepairPlanner {
    static func itemIDsToRepair(
        parsedSidecars: [ShareLocalMetadataParsedSidecar],
        storedValues: [ShareLocalMetadataStoredValue],
        localVersions: [String: Int],
        currentVersion: Int
    ) -> Set<String> {
        let currentRevisions = Set(parsedSidecars.map(\.sourceRevision))
        var itemIDs = Set(storedValues.compactMap { value in
            guard let revision = value.sourceRevision,
                  currentRevisions.contains(revision) else {
                return value.itemID
            }
            return nil
        })
        for sidecar in parsedSidecars {
            guard let itemID = sidecar.itemID,
                  localVersions[itemID] != currentVersion else { continue }
            itemIDs.insert(itemID)
        }
        return itemIDs
    }
}
