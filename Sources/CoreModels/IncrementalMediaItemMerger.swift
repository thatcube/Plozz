import Foundation

/// A stateful, append-only counterpart to ``MediaItemMerger/merge(_:serverInfo:identitySources:)``
/// for **long paged browses** — above all the combined "All Libraries" grid, where
/// a deep scroll accumulates thousands of items across every library on every
/// server.
///
/// ### Why this exists
/// The batch merger is correct and cheap for a page of tens-to-hundreds of items,
/// which is why the Home rows and a single library's cross-server browse use it
/// directly. But it is a *whole-collection* operation: every page re-runs identity
/// extraction, union-find and ``MediaItemMerger/mergeGroup(_:serverInfo:identitySources:)``
/// over everything seen so far, so the cost of a browse grows quadratically with
/// how far the viewer scrolls. A combined browse is exactly the "full
/// multi-thousand-item scroll" case that turns into visible stutter.
///
/// This merger keeps the same identity rules and the same output, but does the
/// work **once per item**:
/// - each incoming item is matched against the existing clusters through the same
///   three keys (kind-scoped identity, same-physical-server item id, identity-index
///   membership) using union-find over *clusters* rather than over items, so a
///   cluster absorbed into another needs no map rewriting;
/// - only clusters actually touched by a batch are re-merged, so an untouched
///   title never pays `mergeGroup` again;
/// - the split-guard (``MediaItemMerger/refineComponent(_:)``) still runs, but per
///   dirty cluster instead of per page.
///
/// Order is first-appearance order, identical to the batch merger: clusters are
/// emitted in creation order and a union always keeps the earlier cluster.
///
/// Not thread-safe by itself — callers own the isolation (the aggregated provider
/// holds it inside an actor).
public struct IncrementalMediaItemMerger {
    private let serverInfo: (String) -> SourceServerInfo?
    private let identitySources: (MediaItem) -> [MediaSourceRef]
    /// Reads the identity index's publish counter. The index warms asynchronously,
    /// so membership the merge relied on can GROW after items were folded. A
    /// one-shot merge re-reads it for every item every time; this one re-folds from
    /// its retained members when the counter moves. See ``reconcileIfIndexChanged``.
    private let identityRevision: () -> Int
    private var lastIdentityRevision: Int

    /// One retained input item plus the position it arrived at.
    ///
    /// The ordinal is load-bearing, not bookkeeping: `MediaItemMerger` derives a
    /// cluster's members by walking the input in order, so its members are in
    /// global arrival order — and both the split-guard's greedy grouping and
    /// `mergeGroup`'s "first is primary" depend on that order. Appending one
    /// cluster's members onto another's during a union would produce cluster order
    /// instead, so unions merge by ordinal to keep the two identical.
    private struct Member {
        let ordinal: Int
        let item: MediaItem
    }

    /// Union-find parent per cluster slot. A slot is a root when `parent[i] == i`;
    /// unions always keep the LOWER slot (created earlier), which is what makes the
    /// output order match the batch merger's first-appearance order.
    private var parent: [Int] = []
    /// Raw members per cluster in ordinal order, valid only at a root.
    private var members: [[Member]] = []
    /// Cached merged cards per root (a cluster can yield more than one card when the
    /// split-guard ejects a false merge). `nil` = dirty, recompute on next read.
    private var cards: [[MediaItem]?] = []
    /// Arrival counter handed to each incoming item.
    private var nextOrdinal = 0

    /// Kind-scoped identity → some slot in the owning cluster.
    private var identityOwner: [KindScopedIdentity: Int] = [:]
    /// `"<serverOrAccount>\u{1F}<kind>\u{1F}<itemID>"` → some slot in the owning cluster.
    private var serverItemOwner: [String: Int] = [:]
    /// `"<accountID>:<itemID>"` of a member → some slot in the owning cluster.
    private var ownerByRef: [String: Int] = [:]
    /// `"<accountID>:<itemID>"` named by some cluster's identity-index membership →
    /// the slots that named it. A later item whose own ref matches must join them.
    private var claimsByRef: [String: [Int]] = [:]

    /// The flattened merged output, rebuilt only when a batch actually changed
    /// something.
    private var flattened: [MediaItem] = []
    private var isFlattenedStale = false
    /// Whether any item has been read out yet. Once true, the collection's indices
    /// belong to the caller and may not be re-shaped — see
    /// ``reconcileIfIndexChanged``.
    private var hasExposedItems = false

    public init(
        serverInfo: @escaping (String) -> SourceServerInfo? = { _ in nil },
        identitySources: @escaping (MediaItem) -> [MediaSourceRef] = { _ in [] },
        identityRevision: @escaping () -> Int = { 0 }
    ) {
        self.serverInfo = serverInfo
        self.identitySources = identitySources
        self.identityRevision = identityRevision
        self.lastIdentityRevision = identityRevision()
    }

    /// Number of merged cards accumulated so far.
    public var count: Int {
        mutating get {
            flattenIfNeeded()
            return flattened.count
        }
    }

    /// Every merged card, in first-appearance order.
    public mutating func mergedItems() -> [MediaItem] {
        flattenIfNeeded()
        hasExposedItems = true
        return flattened
    }

    /// The merged cards in `range`, clamped to what exists. Avoids materializing a
    /// copy of the whole collection for a caller that only needs one page.
    public mutating func slice(from start: Int, limit: Int) -> [MediaItem] {
        flattenIfNeeded()
        hasExposedItems = true
        let lower = min(max(0, start), flattened.count)
        let upper = min(lower + max(0, limit), flattened.count)
        return Array(flattened[lower..<upper])
    }

    /// Folds one freshly-fetched batch in.
    public mutating func append(_ items: [MediaItem]) {
        reconcileIfIndexChanged()
        guard !items.isEmpty else { return }
        var dirtyRoots: Set<Int> = []

        for item in items {
            let slot = insert(item)
            dirtyRoots.insert(find(slot))
        }

        // A union performed after a root was recorded can leave a stale (now
        // non-root) slot in the set; resolve once at the end.
        for root in dirtyRoots {
            cards[find(root)] = nil
        }
        isFlattenedStale = true
    }

    /// Re-folds everything already accumulated when the identity index has
    /// published since the last fold.
    ///
    /// Deliberately a full re-fold rather than an attempt to patch the affected
    /// clusters: newly-published membership can link ANY pair of existing clusters,
    /// so there is no bounded set to patch, and re-folding from the retained members
    /// reuses the same insertion path — no second, subtly-different merge rule to
    /// keep in sync. It costs one linear pass, and only when the index actually
    /// grew (a handful of times per session as accounts warm), not per page.
    ///
    /// Only runs while **nothing has been handed out yet** (see ``hasExposedItems``),
    /// and that is a deliberate limit rather than an oversight.
    ///
    /// Collapsing two cards shortens the collection, which shifts the index of
    /// everything after them — and the paged grid above addresses items *by index*
    /// and never re-reads a page it has already stored. Once a single slice has been
    /// served, a re-fold would silently move items beneath already-painted cells,
    /// showing one title twice and skipping another. Restricting it to the
    /// pre-exposure window is the only point at which the collection can still be
    /// re-shaped for free — which in practice is the launch window, exactly when the
    /// index is still warming and the fix is worth most.
    ///
    /// A grid that has already painted keeps whatever duplicates existed at that
    /// moment and picks up the index's later knowledge the next time it is opened.
    private mutating func reconcileIfIndexChanged() {
        let revision = identityRevision()
        guard revision != lastIdentityRevision else { return }
        lastIdentityRevision = revision
        // Past this point the caller owns indices we have already given it.
        guard !hasExposedItems else { return }
        let retained = members
            .flatMap { $0 }
            .sorted { $0.ordinal < $1.ordinal }
            .map(\.item)
        guard !retained.isEmpty else { return }

        parent.removeAll(keepingCapacity: true)
        members.removeAll(keepingCapacity: true)
        cards.removeAll(keepingCapacity: true)
        identityOwner.removeAll(keepingCapacity: true)
        serverItemOwner.removeAll(keepingCapacity: true)
        ownerByRef.removeAll(keepingCapacity: true)
        claimsByRef.removeAll(keepingCapacity: true)
        nextOrdinal = 0
        for item in retained { _ = insert(item) }
        isFlattenedStale = true
    }

    // MARK: - Insertion

    private mutating func insert(_ item: MediaItem) -> Int {
        let kind = item.kind
        let identities = MediaItemIdentity.identities(for: item).map {
            KindScopedIdentity(identity: $0, kind: kind)
        }
        let serverScope = item.sourceAccountID.flatMap { serverInfo($0)?.serverID } ?? item.sourceAccountID
        let serverKey = serverScope.map { "\($0)\u{1F}\(kind.rawValue)\u{1F}\(item.id)" }
        let ownRefKey = item.sourceAccountID.map { "\($0):\(item.id)" }
        let claimedRefs = identitySources(item).map { "\($0.accountID):\($0.itemID)" }

        var candidates: [Int] = []
        for identity in identities {
            if let slot = identityOwner[identity] { candidates.append(find(slot)) }
        }
        if let serverKey, let slot = serverItemOwner[serverKey] { candidates.append(find(slot)) }
        // Identity-index membership, both directions — this item naming an already
        // loaded row, and an already loaded row having named this item. Kind-guarded
        // exactly like the batch merger so a stale index ref can never bridge kinds.
        for ref in claimedRefs {
            if let slot = ownerByRef[ref] {
                let root = find(slot)
                if members[root].contains(where: { $0.item.kind == kind }) { candidates.append(root) }
            }
        }
        if let ownRefKey, let claimants = claimsByRef[ownRefKey] {
            for slot in claimants {
                let root = find(slot)
                if members[root].contains(where: { $0.item.kind == kind }) { candidates.append(root) }
            }
        }

        let member = Member(ordinal: nextOrdinal, item: item)
        nextOrdinal += 1

        let slot: Int
        if let target = candidates.min(),
           !hasExposedItems || canJoinWithoutReshaping(item, slot: find(target)) {
            // Fusing two EXISTING clusters removes a card, which shortens the
            // collection and slides every later index down. Before anything has
            // been handed out that is just the merge doing its job; afterwards the
            // caller owns those indices — the grid addresses cards by index and
            // never re-reads a page it has stored, so a fuse would show one title
            // twice and skip another on screen.
            //
            // So after exposure the output becomes strictly append-only: a new item
            // still JOINS the earliest cluster it matches (that only enriches the
            // card already at that index), but two clusters that were separate when
            // the caller last looked stay separate. They were already showing as two
            // cards; leaving them that way is the honest, stable outcome, and the
            // next time the grid is opened they merge from the start.
            if !hasExposedItems {
                for candidate in candidates where candidate != target {
                    union(target, candidate)
                }
            }
            slot = find(target)
            // Ordinals only ever increase, so the newest member always belongs last.
            members[slot].append(member)
        } else {
            slot = parent.count
            parent.append(slot)
            members.append([member])
            cards.append(nil)
        }

        // Register this item's keys against the (possibly newly created) cluster.
        for identity in identities where identityOwner[identity] == nil {
            identityOwner[identity] = slot
        }
        if let serverKey, serverItemOwner[serverKey] == nil {
            serverItemOwner[serverKey] = slot
        }
        if let ownRefKey, ownerByRef[ownRefKey] == nil {
            ownerByRef[ownRefKey] = slot
        }
        for ref in claimedRefs {
            claimsByRef[ref, default: []].append(slot)
        }
        return slot
    }

    /// Whether `item` can join the cluster at `slot` without changing how many
    /// cards that cluster renders.
    ///
    /// Joining normally only enriches the card already at that index. But the
    /// split-guard (``MediaItemMerger/refineComponent(_:)``) partitions a cluster
    /// into mutually-plausible sub-groups, and an item that contradicts every
    /// existing sub-group opens a NEW one — which inserts a card *in the middle* of
    /// the collection and slides every later index down, exactly what the
    /// append-only rule exists to prevent. (The case is real: a sequel scraped with
    /// its predecessor's external id.) Such an item becomes its own tail cluster
    /// instead, so it is still reachable and nothing already on screen moves.
    private func canJoinWithoutReshaping(_ item: MediaItem, slot: Int) -> Bool {
        let groups = MediaItemMerger.refineComponent(members[slot].map(\.item))
        return groups.contains { group in
            !group.contains { MediaItemMerger.plausiblyContradicts($0, item) }
        }
    }

    // MARK: - Union-find over clusters

    private mutating func find(_ slot: Int) -> Int {
        var root = slot
        while parent[root] != root { root = parent[root] }
        var node = slot
        while parent[node] != node {
            let next = parent[node]
            parent[node] = root
            node = next
        }
        return root
    }

    private mutating func union(_ a: Int, _ b: Int) {
        let rootA = find(a)
        let rootB = find(b)
        guard rootA != rootB else { return }
        // Keep the earlier-created cluster so first-appearance order is preserved.
        let (keep, drop) = rootA < rootB ? (rootA, rootB) : (rootB, rootA)
        parent[drop] = keep
        // Interleave by ordinal rather than concatenating. Concatenation would put
        // every member of `keep` before every member of `drop`, which is CLUSTER
        // order, not arrival order — and the split-guard's greedy grouping plus
        // `mergeGroup`'s primary/source ordering both read that order, so the
        // result would differ from the batch merger purely because of how the input
        // happened to be paged. Both sides are already ordinal-sorted, so this is a
        // linear two-pointer merge.
        members[keep] = Self.mergedByOrdinal(members[keep], members[drop])
        members[drop] = []
        cards[keep] = nil
        cards[drop] = nil
    }

    /// Merges two ordinal-sorted member lists into one.
    private static func mergedByOrdinal(_ lhs: [Member], _ rhs: [Member]) -> [Member] {
        guard !lhs.isEmpty else { return rhs }
        guard !rhs.isEmpty else { return lhs }
        var result: [Member] = []
        result.reserveCapacity(lhs.count + rhs.count)
        var i = 0
        var j = 0
        while i < lhs.count, j < rhs.count {
            if lhs[i].ordinal <= rhs[j].ordinal {
                result.append(lhs[i])
                i += 1
            } else {
                result.append(rhs[j])
                j += 1
            }
        }
        result.append(contentsOf: lhs[i...])
        result.append(contentsOf: rhs[j...])
        return result
    }

    // MARK: - Output

    private mutating func flattenIfNeeded() {
        guard isFlattenedStale else { return }
        var output: [MediaItem] = []
        output.reserveCapacity(flattened.count + 32)
        for slot in parent.indices where parent[slot] == slot {
            if let cached = cards[slot] {
                output.append(contentsOf: cached)
                continue
            }
            var produced: [MediaItem] = []
            for group in MediaItemMerger.refineComponent(members[slot].map(\.item)) {
                produced.append(
                    MediaItemMerger.mergeGroup(
                        group,
                        serverInfo: serverInfo,
                        identitySources: identitySources
                    )
                )
            }
            cards[slot] = produced
            output.append(contentsOf: produced)
        }
        flattened = output
        isFlattenedStale = false
    }
}
