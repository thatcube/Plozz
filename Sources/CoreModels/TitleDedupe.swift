import Foundation

/// List-level "these two rows are the same title" dedup, shared by every display
/// surface that shows a flat list of items from more than one source.
///
/// Related titles, person credits and the player's cast strip each grew their own
/// `kind|normalizedTitle|year` string key. All three had the same hole: they compared
/// **only** titles, so two copies of one film catalogued under different localized
/// titles stayed apart even when both carried the same IMDb id, and none of them
/// noticed a shared catalogue id at all.
///
/// This unifies the *strong* half — shared external identity, kind-scoped, with the
/// merger's split guard applied so a bridging id can't chain two unrelated films —
/// while letting each surface keep its own **weak** policy, because those genuinely
/// differ and are documented at each call site:
///
/// - Person credits refuse to merge two year-less films (removing a title the viewer
///   owns is worse than showing a duplicate poster).
/// - The cast strip does the opposite: a ten-poster glance row would rather fold a
///   year-less copy into a titled one than show the same film four times.
///
/// Passing `weakKey: { _ in nil }` gives strong-identity-only dedup.
public enum TitleDedupe {
    /// Groups indices of `items` that refer to the same title.
    ///
    /// Groups appear in first-appearance order and each group's members are in input
    /// order, so a surface that keeps the first member never reshuffles its row.
    public static func groups(
        _ items: [MediaItem],
        weakKey: (MediaItem) -> String? = { _ in nil }
    ) -> [[Int]] {
        guard items.count > 1 else { return items.isEmpty ? [] : [[0]] }

        var parent = Array(items.indices)
        func find(_ index: Int) -> Int {
            var root = index
            while parent[root] != root { root = parent[root] }
            var cursor = index
            while parent[cursor] != root {
                let next = parent[cursor]
                parent[cursor] = root
                cursor = next
            }
            return root
        }
        func union(_ lhs: Int, _ rhs: Int) {
            let a = find(lhs)
            let b = find(rhs)
            guard a != b else { return }
            // Lower index wins so the first appearance stays the group's anchor.
            if a < b { parent[b] = a } else { parent[a] = b }
        }

        var anchorByStrongKey: [String: Int] = [:]
        var anchorByWeakKey: [String: Int] = [:]
        for index in items.indices {
            let item = items[index]
            for key in MediaItemIdentity.overlapKeys(for: item) {
                if let anchor = anchorByStrongKey[key] {
                    union(anchor, index)
                } else {
                    anchorByStrongKey[key] = index
                }
            }
            guard let weak = weakKey(item) else { continue }
            if let anchor = anchorByWeakKey[weak] {
                union(anchor, index)
            } else {
                anchorByWeakKey[weak] = index
            }
        }

        var membersByRoot: [Int: [Int]] = [:]
        for index in items.indices {
            membersByRoot[find(index), default: []].append(index)
        }

        // Split-guard: a shared id can chain two genuinely different works through a
        // third row whose metadata straddles both. Same greedy refinement the merger
        // and `TitleComponentLabeller` use, so all three agree on what "different
        // work" means.
        var refined: [[Int]] = []
        for root in membersByRoot.keys.sorted() {
            let members = membersByRoot[root] ?? []
            guard members.count > 1 else {
                refined.append(members)
                continue
            }
            var subgroups: [[Int]] = []
            for index in members {
                if let slot = subgroups.firstIndex(where: { group in
                    !group.contains { contradicts(items[$0], items[index]) }
                }) {
                    subgroups[slot].append(index)
                } else {
                    subgroups.append([index])
                }
            }
            refined.append(contentsOf: subgroups)
        }
        return refined.sorted { ($0.first ?? 0) < ($1.first ?? 0) }
    }

    /// Convenience: first-wins dedup preserving input order.
    public static func deduplicated(
        _ items: [MediaItem],
        weakKey: (MediaItem) -> String? = { _ in nil }
    ) -> [MediaItem] {
        groups(items, weakKey: weakKey).compactMap { $0.first.map { items[$0] } }
    }

    private static func contradicts(_ lhs: MediaItem, _ rhs: MediaItem) -> Bool {
        MediaItemIdentity.titlesPlausiblyContradict(
            titleA: MediaItemIdentity.normalizedTitle(lhs.title),
            yearA: lhs.productionYear,
            kindA: lhs.kind,
            titleB: MediaItemIdentity.normalizedTitle(rhs.title),
            yearB: rhs.productionYear,
            kindB: rhs.kind
        )
    }
}
