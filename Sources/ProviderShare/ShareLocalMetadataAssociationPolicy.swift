import Foundation

enum ShareLocalSidecarLookup: Sendable, Equatable, Hashable {
    case exactVideo(relPath: String)
    case genericMovie(parentDir: String)
    case series(parentDir: String)
}

struct ShareLocalMetadataMember: Sendable, Equatable {
    var relPath: String
    var isMovie: Bool
    var genericRepresentativeRelPath: String?
}

struct ShareLocalMetadataAssociationFacts: Sendable, Equatable {
    var associatedVideoExists: Bool = false
    var movieRepresentativeRelPath: String?
    var genericRepresentativeRelPath: String?
    var seriesKey: String?
}

struct ShareLocalMetadataReassociationPlan: Sendable, Equatable {
    var status: String
    var clearProcessedFingerprint: Bool
}

/// Pure sidecar association rules. The catalog store supplies persisted facts and
/// executes the returned lookups; this type decides which sidecars may describe
/// an item and which logical item a discovered sidecar targets.
enum ShareLocalMetadataAssociationPolicy {
    static func lookups(
        members: [ShareLocalMetadataMember],
        seriesRoots: Set<String>
    ) -> [ShareLocalSidecarLookup] {
        var lookups: [ShareLocalSidecarLookup] = members.map {
            .exactVideo(relPath: $0.relPath)
        }
        let memberPaths = Set(members.map(\.relPath))
        for member in members where member.isMovie {
            guard let representative = member.genericRepresentativeRelPath,
                  memberPaths.contains(representative) else { continue }
            let parentDir = (member.relPath as NSString).deletingLastPathComponent
            lookups.append(.genericMovie(parentDir: parentDir))
        }
        lookups.append(contentsOf: seriesRoots.map(ShareLocalSidecarLookup.series))
        var seen = Set<ShareLocalSidecarLookup>()
        return lookups.filter { seen.insert($0).inserted }
    }

    static func itemID(
        for kind: LocalSidecarKind,
        associatedVideoRelPath: String?,
        facts: ShareLocalMetadataAssociationFacts
    ) -> String? {
        switch kind {
        case .episodeStem:
            guard facts.associatedVideoExists, let associatedVideoRelPath else { return nil }
            return ShareCatalogID.file(associatedVideoRelPath)
        case .movieStem:
            guard facts.associatedVideoExists,
                  let representative = facts.movieRepresentativeRelPath else { return nil }
            return ShareCatalogID.file(representative)
        case .movieGeneric:
            return facts.genericRepresentativeRelPath.map(ShareCatalogID.file)
        case .series:
            return facts.seriesKey.map(ShareCatalogID.series)
        }
    }

    static func reassociationPlan(
        priorItemID: String?,
        desiredItemID: String?,
        priorStatus: String,
        cacheIsEmpty: Bool
    ) -> ShareLocalMetadataReassociationPlan? {
        guard priorItemID != desiredItemID else { return nil }
        if desiredItemID == nil {
            return .init(status: "ambiguous", clearProcessedFingerprint: false)
        }
        if priorStatus == "ambiguous" {
            return .init(
                status: cacheIsEmpty ? "pending" : "parsed",
                clearProcessedFingerprint: cacheIsEmpty
            )
        }
        return .init(status: priorStatus, clearProcessedFingerprint: false)
    }
}
