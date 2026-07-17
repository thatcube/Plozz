import Foundation

/// Pure, filesystem- and actor-free selection of which cache entries to evict to
/// bring a serialized map back within a byte budget.
///
/// It operates only on immutable per-entry size/expiry *facts*, so the eviction
/// decision is fully unit-testable without touching disk, `URLCache`, or the
/// `MetadataDiskCache` actor. Oldest-expiring entries are evicted first: they are
/// the closest to being dropped on the next load anyway, so removing them costs
/// the fewest still-useful cache hits.
///
/// This type performs **no encoding**. Callers measure the whole map at most once
/// to decide whether pruning is needed, then feed cheap per-entry size estimates
/// here for a single ordered selection. That keeps the number of expensive
/// whole-map encodes bounded regardless of entry count.
struct MetadataCacheBudgetPolicy: Sendable {
    struct SizedEntry: Sendable, Equatable {
        let key: String
        let expires: Date
        /// A cheap estimate of this entry's serialized contribution in bytes.
        let estimatedSize: Int
    }

    /// Fixed serialized overhead of an empty JSON map (`{}`). Included so a tiny
    /// budget still evicts down toward — but never below — a coherent empty file.
    private let mapOverhead = 2

    /// Returns the keys to evict, oldest-expiring first (ties broken by key for
    /// determinism), so the estimated surviving total fits `maxBytes`.
    ///
    /// Returns an empty array when the estimated total already fits or when there
    /// is nothing to evict. When `maxBytes` is so small that not even a single
    /// entry fits, every key is returned (the caller then persists an empty map).
    func evictionKeys(_ entries: [SizedEntry], maxBytes: Int) -> [String] {
        guard maxBytes >= 0, !entries.isEmpty else { return [] }
        let estimatedTotal = mapOverhead + entries.reduce(0) { $0 + max(0, $1.estimatedSize) }
        guard estimatedTotal > maxBytes else { return [] }

        let oldestFirst = entries.sorted {
            $0.expires != $1.expires ? $0.expires < $1.expires : $0.key < $1.key
        }
        var running = estimatedTotal
        var evict: [String] = []
        var index = 0
        while running > maxBytes && index < oldestFirst.count {
            evict.append(oldestFirst[index].key)
            running -= max(0, oldestFirst[index].estimatedSize)
            index += 1
        }
        return evict
    }
}
