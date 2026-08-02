import Foundation

/// Assigns every indexed source **one** canonical identity for the title it belongs
/// to, in a single authoritative pass over the whole index.
///
/// ## Why a pass, and not a per-item walk
///
/// The index's membership walk
/// (``IdentityIndexSnapshot/sources(forIdentities:kind:anchorTitle:anchorYear:)``)
/// filters candidate sources against **the asking item's** title/year. That is exactly
/// right for "which servers can I play this from", but it is *not* an equivalence
/// relation, so it cannot define a canonical name. Take three sources bridged by
/// shared ids:
///
/// ```
/// A = "Scream 6" 2023, ids { imdb:tt1 }
/// B = "Scream"  (no year), ids { imdb:tt1, tmdb:5 }
/// C = "Scream 7" 2025, ids { tmdb:5 }
/// ```
///
/// Asked from A the walk yields `{A, B}` (C contradicts A); asked from B, `{A, B, C}`
/// (B has no year, so nothing contradicts); asked from C, `{B, C}`. Three members,
/// three different "components" — "the minimum of the component" is three different
/// questions. Worse, the walk's frontier is *identities*: `tmdb:5` enters A's frontier
/// through B before C is ever examined, so a naive minimum would hand A and C the same
/// name and silently undo the split guard.
///
/// This pass instead does what ``MediaItemMerger`` does for whole items: union by
/// shared identity, then **refine** each component into sub-groups of mutually
/// non-contradicting members using the same
/// ``MediaItemIdentity/titlesPlausiblyContradict(titleA:yearA:kindA:titleB:yearB:kindB:)``
/// primitive. In the example that yields `{A, B}` and `{C}` (or `{A}` and `{B, C}`
/// depending on order — either way A and C are never named the same), and each refined
/// group gets the deterministic minimum of *its own members'* identities.
///
/// The result is a table, so a lookup is O(1) instead of a per-item graph walk with
/// two set allocations and a sort — which matters because card, search, related and
/// person-credit paths each classify hundreds of items per wave.
public enum TitleComponentLabeller {
    /// - Returns: `source.id` → the canonical ``MediaIdentity`` of its refined,
    ///   kind-scoped component.
    public static func label(
        byIdentity: [MediaIdentity: [IndexedSource]],
        bySource: [String: [MediaIdentity]]
    ) -> [String: MediaIdentity] {
        guard !byIdentity.isEmpty else { return [:] }

        // Deterministic source ordering: refinement is greedy and order-sensitive, and
        // dictionary iteration order is per-process random.
        var sourcesByID: [String: IndexedSource] = [:]
        for (_, sources) in byIdentity {
            for source in sources where sourcesByID[source.id] == nil {
                sourcesByID[source.id] = source
            }
        }
        let orderedSourceIDs = sourcesByID.keys.sorted()

        var parent: [String: String] = [:]
        for id in orderedSourceIDs { parent[id] = id }

        func find(_ id: String) -> String {
            var root = id
            while let next = parent[root], next != root { root = next }
            var cursor = id
            while let next = parent[cursor], next != root {
                parent[cursor] = root
                cursor = next
            }
            return root
        }

        func union(_ lhs: String, _ rhs: String) {
            let a = find(lhs)
            let b = find(rhs)
            guard a != b else { return }
            // Deterministic winner so components are identical across launches.
            if a < b { parent[b] = a } else { parent[a] = b }
        }

        // Union by shared identity, **kind-scoped**: TMDb/TVDb reuse one integer id
        // space across movies and series (movie 550 ≠ tv 550), so an unscoped union
        // could bridge two unrelated movies through a same-id series.
        for identity in byIdentity.keys.sorted(by: { stableKey($0) < stableKey($1) }) {
            let sources = byIdentity[identity] ?? []
            var firstByKind: [MediaItemKind: String] = [:]
            for source in sources {
                if let anchor = firstByKind[source.kind] {
                    union(anchor, source.id)
                } else {
                    firstByKind[source.kind] = source.id
                }
            }
        }

        var membersByRoot: [String: [String]] = [:]
        for id in orderedSourceIDs {
            membersByRoot[find(id), default: []].append(id)
        }

        var result: [String: MediaIdentity] = [:]
        for root in membersByRoot.keys.sorted() {
            let members = (membersByRoot[root] ?? []).compactMap { sourcesByID[$0] }
            for group in refine(members) {
                guard let canonical = canonicalIdentity(for: group, bySource: bySource) else {
                    continue
                }
                for member in group {
                    result[member.id] = canonical
                }
            }
        }
        return result
    }

    /// Greedy partition of one union component into sub-groups whose members do not
    /// positively contradict each other. Mirrors ``MediaItemMerger/refineComponent(_:)``
    /// exactly, but over the index's lean `(normalizedTitle, year, kind)` facts.
    static func refine(_ members: [IndexedSource]) -> [[IndexedSource]] {
        guard members.count > 1 else { return members.isEmpty ? [] : [members] }
        var groups: [[IndexedSource]] = []
        for member in members {
            if let index = groups.firstIndex(where: { group in
                !group.contains(where: { contradicts($0, member) })
            }) {
                groups[index].append(member)
            } else {
                groups.append([member])
            }
        }
        return groups
    }

    static func contradicts(_ lhs: IndexedSource, _ rhs: IndexedSource) -> Bool {
        MediaItemIdentity.titlesPlausiblyContradict(
            titleA: lhs.normalizedTitle ?? "",
            yearA: lhs.year,
            kindA: lhs.kind,
            titleB: rhs.normalizedTitle ?? "",
            yearB: rhs.year,
            kindB: rhs.kind
        )
    }

    /// The deterministic minimum identity across a refined group's members. A strong
    /// external id anywhere in the group suppresses weak title evidence, so a
    /// component is never named after a mutable title while a catalogue id exists.
    static func canonicalIdentity(
        for group: [IndexedSource],
        bySource: [String: [MediaIdentity]]
    ) -> MediaIdentity? {
        var identities: Set<MediaIdentity> = []
        for member in group {
            guard let known = bySource[member.id] else { continue }
            identities.formUnion(known)
        }
        guard !identities.isEmpty else { return nil }
        if identities.contains(where: { if case .external = $0 { return true } else { return false } }) {
            identities = identities.filter { if case .title = $0 { return false } else { return true } }
        }
        return identities.min(by: MediaIdentity.isCanonicallyOrderedBefore)
    }

    private static func stableKey(_ identity: MediaIdentity) -> String {
        switch identity {
        case let .external(source, value): return "0:\(source):\(value)"
        case let .title(title, year, kind): return "1:\(title):\(year.map(String.init) ?? "?"):\(kind.rawValue)"
        case let .sameItemID(id): return "2:\(id)"
        }
    }
}
