import Foundation

/// One row of the sidecar inventory discovered by a scan's BFS listing, surfaced
/// by `ShareCatalogStore`'s pending-local-metadata queries. Standalone ProviderShare
/// domain type (formerly nested in the store) so the local-metadata repository and
/// enricher depend on the DTO rather than the persistence actor.
struct PendingLocalMetadataFile: Sendable, Equatable {
    var relPath: String
    var parentDir: String
    var kind: LocalSidecarKind
    var size: Int64
    var associatedVideoRelPath: String?
    var processedItemID: String?
    var fingerprint: String?
    /// A weak transport gave no change-detection facts — this file rereads
    /// once per successful full scan rather than on every scheduler slice.
    var scanGenerationBound: Bool
    var status: String
    var attempts: Int
}
