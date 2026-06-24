import Foundation

/// Discovers *other servers* that host the same title as a given primary item and
/// returns the unified per-server ``MediaSourceRef`` list that drives the
/// cross-server **server picker** on the detail page.
///
/// This is the discovery half of the cross-server story (the merge half lives in
/// ``MediaItemMerger``). A title surfaced from a single server — e.g. a Home row
/// only one server populated — has no picker until we go looking for its twins on
/// the household's other servers. Because neither Plex nor Jellyfin exposes a
/// reliable "find by external id" query, discovery has to go through each server's
/// free-text search; the resulting hits are then matched back to the primary
/// **by provider IDs** (``MediaItemIdentity``) so a title stored under a *different
/// name* on another server (localised title, edition/year annotation, "The …"
/// reorder) still collapses into one card as long as it shares a strong external
/// id (IMDb/TMDb/TVDb).
///
/// The recall fix that makes "differing titles" work is ``searchQueries(for:)``:
/// in addition to the raw title we also search with the normalized title, so the
/// candidate is actually *returned* by the other server's search and can reach the
/// provider-ID merge. Precision is unchanged — the merge only folds in hits that
/// genuinely share the primary's identity, so widening the query never attaches an
/// unrelated title to the picker.
public enum CrossServerSourceResolver {
    /// The search queries to issue against each other server when hunting for
    /// copies of `item`, most specific first.
    ///
    /// 1. the raw, trimmed title (what most servers index verbatim);
    /// 2. the normalized title (``MediaItemIdentity/normalizedTitle(_:)`` —
    ///    accent-folded, punctuation-stripped, lower-cased) when it differs, to
    ///    catch servers that store the title with extra annotations / different
    ///    punctuation / accents.
    ///
    /// Empty when the item has no usable title.
    public static func searchQueries(for item: MediaItem) -> [String] {
        let raw = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return [] }

        var queries = [raw]
        let normalized = MediaItemIdentity.normalizedTitle(raw)
        if !normalized.isEmpty,
           normalized.caseInsensitiveCompare(raw) != .orderedSame {
            queries.append(normalized)
        }
        return queries
    }

    /// Searches every account in `otherAccountIDs` for the same title as `primary`
    /// and returns the unified cross-server source list (primary first), or an
    /// empty list when nothing else hosts it.
    ///
    /// - Parameters:
    ///   - primary: the loaded item the user is looking at; its `providerIDs`
    ///     drive the cross-server match and its `sourceAccountID` leads the picker.
    ///   - otherAccountIDs: the *other* signed-in accounts to probe (the caller
    ///     already excludes `primary.sourceAccountID`).
    ///   - search: issues one free-text search against a given account, returning
    ///     that server's (untagged) hits. The resolver tags them with the account.
    ///   - serverInfo: resolves an account id to its backend kind / friendly names
    ///     so each ``MediaSourceRef`` is labelled for the picker.
    ///
    /// Matching is **by provider IDs** via ``MediaItemMerger`` / ``MediaItemIdentity``,
    /// so a differently-titled copy on another server still resolves.
    public static func resolve(
        primary: MediaItem,
        otherAccountIDs: [String],
        search: @Sendable @escaping (_ accountID: String, _ query: String) async -> [MediaItem],
        serverInfo: (String) -> SourceServerInfo? = { _ in nil }
    ) async -> [MediaSourceRef] {
        let queries = searchQueries(for: primary)
        guard !queries.isEmpty, !otherAccountIDs.isEmpty else { return [] }

        let hits: [MediaItem] = await withTaskGroup(of: [MediaItem].self) { group in
            for accountID in otherAccountIDs {
                group.addTask {
                    var seenItemIDs = Set<String>()
                    var accountHits: [MediaItem] = []
                    // Each query widens recall; dedupe within the account so the
                    // raw and normalized passes don't double-count the same hit.
                    for query in queries {
                        for hit in await search(accountID, query) where seenItemIDs.insert(hit.id).inserted {
                            accountHits.append(hit.taggingSource(accountID))
                        }
                    }
                    return accountHits
                }
            }
            var all: [MediaItem] = []
            for await accountHits in group { all.append(contentsOf: accountHits) }
            return all
        }
        guard !hits.isEmpty else { return [] }

        let merged = MediaItemMerger.merge([primary] + hits, serverInfo: serverInfo)
        return merged.first(where: { $0.id == primary.id })?.sources ?? []
    }
}
