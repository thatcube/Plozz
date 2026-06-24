import Foundation

/// Optional capability a `MediaProvider` adopts to let the user trigger a
/// **server-side metadata refresh** for a single item — re-scanning the file and
/// re-fetching artwork/metadata from the server's configured providers.
///
/// Detected at runtime via `provider as? MetadataRefreshing`, mirroring the other
/// optional capabilities, so the base `MediaProvider` contract is untouched and
/// providers that can't refresh (or test doubles) simply don't conform — the UI
/// then hides the action.
///
/// This is a background task on the server: the call returns once the refresh has
/// been *queued/accepted*, not when it finishes, so callers treat it as
/// fire-and-forget and never block the UI on it.
public protocol MetadataRefreshing: Sendable {
    /// Asks the server to refresh metadata for `itemID` (a full
    /// metadata + image refresh, without replacing user edits where the backend
    /// distinguishes them). Throws only if the request itself can't be issued.
    func refreshMetadata(itemID: String) async throws
}
