import Foundation

/// Local ordering of already-fetched items by the same ``SortDescriptor`` a
/// provider was asked to sort by.
///
/// Needed by the **combined** library browse. A grid stitched from many servers'
/// pages can only claim to be sorted if the pages are merged on the sort key —
/// round-robin interleaving produces "Alien, Amélie, Arrival, Alien 3, Anatomy…",
/// which reads as broken under a menu that says "Name A–Z".
///
/// Two honest limits, both encoded in ``supportsLocalOrdering(_:)``:
/// - `MediaItem` does not carry a date-added or community-rating field (they are
///   server-side sort inputs the list payloads don't return), so those sorts
///   cannot be merged locally; and
/// - `random` has no order to merge by at all.
///
/// For those the caller falls back to interleaving, which is no worse than what a
/// shuffled/opaque ordering already looks like.
///
/// The comparison is an *approximation* of the server's collation (it strips a
/// leading article and compares case/diacritic-insensitively with numeric
/// awareness, which is what Plex and Jellyfin sort names do in practice). That is
/// safe by construction: the merge only decides which source's head to take next,
/// so a disagreement can nudge two adjacent cards, never drop or duplicate one.
public enum MediaItemSortOrder {
    /// Whether items can be ordered locally for `field` — i.e. whether a combined
    /// browse can merge on it rather than interleave.
    public static func supportsLocalOrdering(_ field: SortField) -> Bool {
        switch field {
        case .name, .releaseDate, .runtime: return true
        case .dateAdded, .communityRating, .random: return false
        }
    }

    /// Whether `lhs` should be placed before `rhs` under `sort`.
    ///
    /// Ties break on the sort name so the order is total and therefore stable:
    /// without a tiebreak, two items with the same year would swap depending on
    /// which page they arrived in.
    public static func isOrderedBefore(
        _ lhs: MediaItem,
        _ rhs: MediaItem,
        sort: SortDescriptor
    ) -> Bool {
        let ascending = sort.direction == .ascending
        switch sort.field {
        case .name, .dateAdded, .communityRating, .random:
            return compareNames(lhs, rhs, ascending: ascending) ?? false
        case .releaseDate:
            if let result = compare(lhs.productionYear, rhs.productionYear, ascending: ascending) {
                return result
            }
            return compareNames(lhs, rhs, ascending: true) ?? false
        case .runtime:
            if let result = compare(lhs.runtime, rhs.runtime, ascending: ascending) {
                return result
            }
            return compareNames(lhs, rhs, ascending: true) ?? false
        }
    }

    /// The name a server would sort by: lower-cased, diacritic-folded, with a
    /// leading English article dropped ("The Matrix" files under M).
    static func sortName(_ item: MediaItem) -> String {
        let folded = item.title
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        for article in ["the ", "a ", "an "] where folded.hasPrefix(article) {
            return String(folded.dropFirst(article.count))
        }
        return folded
    }

    private static func compareNames(
        _ lhs: MediaItem,
        _ rhs: MediaItem,
        ascending: Bool
    ) -> Bool? {
        let result = sortName(lhs).compare(sortName(rhs), options: [.numeric])
        guard result != .orderedSame else { return nil }
        return ascending ? result == .orderedAscending : result == .orderedDescending
    }

    /// Orders two optionals, always sinking `nil` to the end regardless of
    /// direction — an item with no year is "unknown", not "oldest", and floating it
    /// to the top of a descending sort would bury the newest releases.
    /// Returns `nil` when the two are equal, so the caller can apply a tiebreak.
    private static func compare<Value: Comparable>(
        _ lhs: Value?,
        _ rhs: Value?,
        ascending: Bool
    ) -> Bool? {
        switch (lhs, rhs) {
        case let (left?, right?):
            guard left != right else { return nil }
            return ascending ? left < right : left > right
        case (nil, .some): return false
        case (.some, nil): return true
        case (nil, nil): return nil
        }
    }
}
