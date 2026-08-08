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

    /// Union-find parent per cluster slot. A slot is a root when `parent[i] == i`;
    /// unions always keep the LOWER slot (created earlier), which is what makes the
    /// output order match the batch merger's first-appearance order.
    private var parent: [Int] = []
    /// Raw members per cluster, valid only at a root.
    private var members: [[MediaItem]] = []
    /// Cached merged cards per root (a cluster can yield more than one card when the
    /// split-guard ejects a false merge). `nil` = dirty, recompute on next read.
    private var cards: [[MediaItem]?] = []

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

    public init(
        serverInfo: @escaping (String) -> SourceServerInfo? = { _ in nil },
        identitySources: @escaping (MediaItem) -> [MediaSourceRef] = { _ in [] }
    ) {
        self.serverInfo = serverInfo
        self.identitySources = identitySources
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
        return flattened
    }

    /// The merged cards in `range`, clamped to what exists. Avoids materializing a
    /// copy of the whole collection for a caller that only needs one page.
    public mutating func slice(from start: Int, limit: Int) -> [MediaItem] {
        flattenIfNeeded()
        let lower = min(max(0, start), flattened.count)
        let upper = min(lower + max(0, limit), flattened.count)
        return Array(flattened[lower..<upper])
    }

    /// Folds one freshly-fetched batch in.
    public mutating func append(_ items: [MediaItem]) {
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
                if members[root].contains(where: { $0.kind == kind }) { candidates.append(root) }
            }
        }
        if let ownRefKey, let claimants = claimsByRef[ownRefKey] {
            for slot in claimants {
                let root = find(slot)
                if members[root].contains(where: { $0.kind == kind }) { candidates.append(root) }
            }
        }

        let slot: Int
        if let target = candidates.min() {
            for candidate in candidates where candidate != target {
                union(target, candidate)
            }
            slot = find(target)
            members[slot].append(item)
        } else {
            slot = parent.count
            parent.append(slot)
            members.append([item])
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
        members[keep].append(contentsOf: members[drop])
        members[drop] = []
        cards[keep] = nil
        cards[drop] = nil
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
            for group in MediaItemMerger.refineComponent(members[slot]) {
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
