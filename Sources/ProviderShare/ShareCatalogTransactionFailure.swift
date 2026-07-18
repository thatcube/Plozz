import Foundation

/// Test-only injection point for the atomic enrichment-save path. Forcing a failure
/// after the derived catalog mutations proves the enrichment write rolls back as a
/// unit. Never set in production. Standalone ProviderShare domain type (formerly
/// nested in `ShareCatalogStore`).
enum EnrichmentSaveFailurePoint: Sendable, Equatable {
    case afterDerivedCatalogMutations
}

/// Test-only injection points for the atomic clean-scan finalize. Forcing a
/// failure at each phase proves the whole transaction rolls back as a unit, so
/// a reopen observes either the complete old state or the complete corrected
/// state — never a partial prune, a stale local winner, a missing fallback, or
/// resurrectable orphan metadata. Never set in production. Standalone ProviderShare
/// domain type (formerly nested in `ShareCatalogStore`).
enum CleanScanFailurePoint: Sendable, Equatable {
    case afterAssetDelete
    case afterMovieRegroup
    case afterOrphanMetadataCleanup
    case afterSidecarCleanup
    case afterAliasCleanup
    case afterAssociationRecompute
    case afterWinnerRematerialize
    case afterFilenameProjection
}
