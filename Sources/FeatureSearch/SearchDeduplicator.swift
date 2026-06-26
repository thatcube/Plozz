import Foundation
import CoreModels

/// Thin, search-facing shim over the shared cross-server merge core
/// (``MediaItemMerger`` / ``MediaItemIdentity`` in `CoreModels`).
///
/// The identity rules and union-find that used to live here were lifted into
/// `CoreModels` so that **Home, aggregated Library browse and Search all share
/// one** well-tested identity/merge component instead of duplicating the logic
/// (and its subtle safety carve-outs). This shim preserves the original
/// `deduplicate` API — and therefore its test suite — while delegating to the
/// shared core.
public enum SearchDeduplicator {
    /// Collapses duplicate items that refer to the same title across providers
    /// into a single merged item, preserving the input's relevance order.
    ///
    /// - Parameters:
    ///   - items: search hits, already interleaved in relevance order and tagged
    ///     with their owning account.
    ///   - serverInfo: optional account-id -> backend/server-name resolver so the
    ///     merged card's per-server sources are labelled for the server picker.
    ///     Defaults to "unknown", which still merges identically.
    public static func deduplicate(
        _ items: [MediaItem],
        identitySources: (MediaItem) -> [MediaSourceRef] = { _ in [] },
        serverInfo: (String) -> SourceServerInfo? = { _ in nil }
    ) -> [MediaItem] {
        MediaItemMerger.merge(items, serverInfo: serverInfo, identitySources: identitySources)
    }
}
