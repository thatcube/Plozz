import CoreModels
import Foundation

public struct MediaAliasSnapshot: Sendable, Equatable {
    public let recordsByID: [MediaAliasID: MediaAliasRecord]
    public let redirectsByID: [MediaAliasID: MediaAliasID]
    public let aliasesByStrongEvidence: [MediaAliasStrongEvidence: Set<MediaAliasID>]
    public let aliasesByValidatedBinding: [MediaAliasProviderBindingKey: Set<MediaAliasID>]
    public let aliasesByWeakEvidence: [MediaAliasWeakEvidence: Set<MediaAliasID>]
    public let activeRecordCount: Int

    public init(records: [MediaAliasRecord]) {
        let recordsByID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        self.recordsByID = recordsByID

        var redirects: [MediaAliasID: MediaAliasID] = [:]
        for record in records where record.redirectTarget != nil {
            if let target = Self.resolve(record.id, records: recordsByID) {
                redirects[record.id] = target
            }
        }
        redirectsByID = redirects

        var strong: [MediaAliasStrongEvidence: Set<MediaAliasID>] = [:]
        var binding: [MediaAliasProviderBindingKey: Set<MediaAliasID>] = [:]
        var weak: [MediaAliasWeakEvidence: Set<MediaAliasID>] = [:]
        for record in records {
            guard let resolvedID = Self.resolve(record.id, records: recordsByID) else {
                continue
            }
            let strongGroups = Dictionary(
                grouping: record.strongEvidence,
                by: \.namespace
            )
            for evidence in record.strongEvidence
            where Set(strongGroups[evidence.namespace, default: []].map(\.value)).count == 1 {
                strong[evidence, default: []].insert(resolvedID)
            }
            for key in record.locallyValidatedBindings {
                binding[key, default: []].insert(resolvedID)
            }
            for evidence in record.weakEvidence {
                weak[evidence, default: []].insert(resolvedID)
            }
        }
        aliasesByStrongEvidence = strong
        aliasesByValidatedBinding = binding
        aliasesByWeakEvidence = weak
        activeRecordCount = records.lazy.filter { $0.redirectTarget == nil }.count
    }

    public static let empty = MediaAliasSnapshot(records: [])

    public var recordCount: Int { recordsByID.count }

    public func resolvedAliasID(for id: MediaAliasID) -> MediaAliasID? {
        guard let record = recordsByID[id] else { return nil }
        if let redirect = redirectsByID[id] {
            return redirect
        }
        return record.redirectTarget == nil ? id : nil
    }

    public func record(for id: MediaAliasID) -> MediaAliasRecord? {
        guard let resolved = resolvedAliasID(for: id) else { return nil }
        return recordsByID[resolved]
    }

    public func aliases(for evidence: MediaAliasStrongEvidence) -> Set<MediaAliasID> {
        aliasesByStrongEvidence[evidence] ?? []
    }

    public func aliases(for binding: MediaAliasProviderBindingKey) -> Set<MediaAliasID> {
        aliasesByValidatedBinding[binding] ?? []
    }

    public func aliases(for evidence: MediaAliasWeakEvidence) -> Set<MediaAliasID> {
        aliasesByWeakEvidence[evidence] ?? []
    }

    private static func resolve(
        _ id: MediaAliasID,
        records: [MediaAliasID: MediaAliasRecord]
    ) -> MediaAliasID? {
        guard records[id] != nil else { return nil }
        var current = id
        var visited: Set<MediaAliasID> = []
        while let next = records[current]?.redirectTarget {
            guard visited.insert(current).inserted, records[next] != nil else { return nil }
            current = next
        }
        return current
    }
}
