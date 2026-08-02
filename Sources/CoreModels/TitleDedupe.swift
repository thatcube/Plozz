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
/// Anything that describes a title well enough to be deduped.
///
/// Exists so the engine below is the *only* implementation. `RelatedTitle` and
/// `MediaItem` are different types, and that alone — not any difference of policy —
/// is why the Related row grew a second union-find with its own token scheme and its
/// own split guard. Two implementations of one rule means two places to fix every
/// bug, and in practice only one of them ever got fixed.
public protocol TitleDedupeSubject {
    var dedupeKind: MediaItemKind { get }
    var dedupeTitle: String { get }
    var dedupeYear: Int? { get }
    var dedupeProviderIDs: [String: String] { get }
    /// Fallback when a row carries no identity at all, so it can never be folded
    /// into an unrelated one.
    var dedupeFallbackID: String { get }

    /// Fold a group describing ONE title into the single row that represents it.
    ///
    /// A protocol requirement rather than something each caller does for itself,
    /// because "keep the first and drop the rest" is the wrong default and was
    /// wrong in practice: a person's credits kept an entry from a source that
    /// attaches no catalogue ids and discarded the duplicate that had one, leaving
    /// a show the viewer owns on four servers unable to match its own library and
    /// wearing a request mark. Identity and order belong to the first member;
    /// EVIDENCE belongs to the whole group. Conforming types decide how to fold,
    /// but they cannot decline to.
    static func collapsingDedupeGroup(_ group: [Self]) -> Self
    /// Every strong identity this row carries, kind-scoped. Declared here rather
    /// than only in the extension below so a conformer's own version is the one
    /// generic code calls — an extension-only member dispatches statically, which
    /// silently ignored `MediaItem`'s richer key set.
    var dedupeStrongKeys: Set<String> { get }
}

public extension TitleDedupeSubject {
    /// Every strong external identity this row carries, kind-scoped.
    ///
    /// Kind scoping is load-bearing: TMDb and TVDb reuse one integer id space across
    /// movies and series, so an unscoped compare folds a film into an unrelated show.
    var dedupeStrongKeys: Set<String> {
        var keys = Set<String>()
        for entry in MediaItemIdentity.strongExternalNamespaces {
            if let value = dedupeProviderIDs.providerID(entry.namespace) {
                keys.insert("\(dedupeKind.rawValue)|\(entry.canonical):\(value.lowercased())")
            }
        }
        return keys
    }
}

extension MediaItem: TitleDedupeSubject {
    public var dedupeKind: MediaItemKind { kind }
    public var dedupeTitle: String { title }
    public var dedupeYear: Int? { productionYear }
    public var dedupeProviderIDs: [String: String] { providerIDs }
    public var dedupeFallbackID: String { "\(sourceAccountID ?? "-"):\(id)" }
    /// The app-wide identity set, which for a movie with a year also includes its
    /// title identity — two rows for one film that carry no catalogue id at all are
    /// still the same film. `RelatedTitle` has no equivalent and takes the default.
    public var dedupeStrongKeys: Set<String> { MediaItemIdentity.overlapKeys(for: self) }

    /// The app's canonical fold. `MediaItemMerger` already unions provider ids,
    /// sources and every server across a group; deferring to it means a display row
    /// and a Home row agree about what one title is.
    public static func collapsingDedupeGroup(_ group: [MediaItem]) -> MediaItem {
        var merged = MediaItemMerger.mergeGroup(group)
        // The merger settles identity; this settles presentation. Without it the
        // survivor keeps its own gaps — a credit with no poster stays a grey tile
        // beside a duplicate that had one.
        for donor in group {
            merged.fillingMissingPresentation(from: donor)
        }
        return merged
    }
}

/// The named weak policies. Dedup asks the same question everywhere — "are these two
/// rows the same title" — but what it costs to be WRONG differs by surface, and that
/// is the only thing that legitimately varies.
public enum TitleDedupePolicy {
    /// Strong shared identity only. For surfaces where a false merge changes what
    /// PLAYS, so a title guess is never worth it.
    case strongOnly
    /// Strong identity, or an exact title+year match. Refuses to merge two rows that
    /// both lack a year, because collapsing them could remove a title the viewer owns.
    case titleAndYear
    /// Strong identity, or the same title regardless of year. For rows showing one
    /// work held in several places, where the year is exactly what the sources
    /// disagree about.
    case titleIgnoringYear

    func weakKey<S: TitleDedupeSubject>(_ subject: S) -> String? {
        let title = MediaItemIdentity.normalizedTitle(subject.dedupeTitle)
        guard !title.isEmpty else { return nil }
        switch self {
        case .strongOnly:
            return nil
        case .titleAndYear:
            guard let year = subject.dedupeYear else { return nil }
            return "\(subject.dedupeKind.rawValue)|\(title)|\(year)"
        case .titleIgnoringYear:
            return "\(subject.dedupeKind.rawValue)|\(title)"
        }
    }
}

public enum TitleDedupe {
    /// Groups indices of `items` that refer to the same title.
    ///
    /// Groups appear in first-appearance order and each group's members are in input
    /// order, so a surface that keeps the first member never reshuffles its row.
    public static func groups<S: TitleDedupeSubject>(
        _ items: [S],
        weakKey: (S) -> String? = { _ in nil }
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

        // Precomputed so refinement can ask about strong affinity cheaply.
        let strongKeysByIndex: [Set<String>] = items.map { item in
            let keys = item.dedupeStrongKeys
            // No identity at all: anchor on the row itself so an empty key set can
            // never fold two unrelated rows together.
            return keys.isEmpty ? ["self|\(item.dedupeFallbackID)"] : keys
        }
        var anchorByStrongKey: [String: Int] = [:]
        var anchorByWeakKey: [String: Int] = [:]
        for index in items.indices {
            let item = items[index]
            for key in strongKeysByIndex[index] {
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
        //
        // Placement prefers a subgroup this row shares a catalogue id with, and only
        // falls back to "doesn't contradict anyone here" when it shares none. Without
        // that preference a row could be pulled away from its own strong-id partner
        // by a group it merely fails to contradict: given "Frozen" 2010 as
        // {tmdb:111}, {tmdb:222, imdb:tt222} and {imdb:tt222}, the third belongs with
        // the second by shared IMDb id, but it shares no namespace with the first and
        // so cannot contradict it — and landed there, asserting tmdb:111 and
        // imdb:tt222 are one film.
        var refined: [[Int]] = []
        for root in membersByRoot.keys.sorted() {
            let members = membersByRoot[root] ?? []
            guard members.count > 1 else {
                refined.append(members)
                continue
            }
            var subgroups: [[Int]] = []
            for index in members {
                let compatible = subgroups.indices.filter { slot in
                    !subgroups[slot].contains { contradicts(items[$0], items[index]) }
                }
                let byStrongIdentity = compatible.first { slot in
                    subgroups[slot].contains {
                        !strongKeysByIndex[$0].isDisjoint(with: strongKeysByIndex[index])
                    }
                }
                if let slot = byStrongIdentity ?? compatible.first {
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
    public static func deduplicated<S: TitleDedupeSubject>(
        _ items: [S],
        weakKey: (S) -> String? = { _ in nil }
    ) -> [S] {
        groups(items, weakKey: weakKey).compactMap { $0.first.map { items[$0] } }
    }

    /// Group under a named policy — the form every surface should use.
    public static func groups<S: TitleDedupeSubject>(
        _ items: [S],
        policy: TitleDedupePolicy
    ) -> [[Int]] {
        groups(items) { policy.weakKey($0) }
    }

    /// First-wins dedup under a named policy.
    ///
    /// Prefer ``collapsed(_:policy:)`` — this returns a lone survivor and so
    /// discards whatever its duplicates knew.
    public static func deduplicated<S: TitleDedupeSubject>(
        _ items: [S],
        policy: TitleDedupePolicy
    ) -> [S] {
        deduplicated(items) { policy.weakKey($0) }
    }

    /// THE dedup entry point: one row per title, each folded from its whole group.
    ///
    /// Groups stay in first-appearance order, so a row never reshuffles.
    public static func collapsed<S: TitleDedupeSubject>(
        _ items: [S],
        policy: TitleDedupePolicy
    ) -> [S] {
        collapsed(items) { policy.weakKey($0) }
    }

    /// As above, with a caller-supplied weak policy.
    public static func collapsed<S: TitleDedupeSubject>(
        _ items: [S],
        weakKey: (S) -> String? = { _ in nil }
    ) -> [S] {
        groups(items, weakKey: weakKey).compactMap { group in
            let members = group.map { items[$0] }
            guard !members.isEmpty else { return nil }
            return S.collapsingDedupeGroup(members)
        }
    }

    private static func contradicts<S: TitleDedupeSubject>(_ lhs: S, _ rhs: S) -> Bool {
        // Same namespace, different value ⇒ different works. Two rows both claiming
        // a TMDb id that disagree are two films, however identical their title and
        // year — "Frozen" 2010 is a real pair. This came from the Related row's own
        // implementation, which had it while credits and the cast strip did not; it
        // is the same rule the alias resolver applies, and folding it in here is why
        // one engine is worth having.
        for entry in MediaItemIdentity.strongExternalNamespaces {
            guard let left = lhs.dedupeProviderIDs.providerID(entry.namespace),
                  let right = rhs.dedupeProviderIDs.providerID(entry.namespace)
            else { continue }
            if left.caseInsensitiveCompare(right) != .orderedSame { return true }
        }
        return MediaItemIdentity.titlesPlausiblyContradict(
            titleA: MediaItemIdentity.normalizedTitle(lhs.dedupeTitle),
            yearA: lhs.dedupeYear,
            kindA: lhs.dedupeKind,
            titleB: MediaItemIdentity.normalizedTitle(rhs.dedupeTitle),
            yearB: rhs.dedupeYear,
            kindB: rhs.dedupeKind
        )
    }
}
