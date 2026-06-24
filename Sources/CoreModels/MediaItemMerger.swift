import Foundation

/// Per-account presentation facts the merge core can't derive from a `MediaItem`
/// alone (a `MediaItem` knows *which* account it came from, but not that
/// account's backend kind or friendly server/user name). The Home/Search
/// aggregators resolve this from their account list and hand it to
/// ``MediaItemMerger`` so each ``MediaSourceRef`` can drive a correctly-labelled
/// server picker.
public struct SourceServerInfo: Sendable, Hashable {
    public var providerKind: ProviderKind?
    public var serverName: String?
    public var accountName: String?

    public init(providerKind: ProviderKind? = nil, serverName: String? = nil, accountName: String? = nil) {
        self.providerKind = providerKind
        self.serverName = serverName
        self.accountName = accountName
    }
}

/// The unified watch-state for a title that lives on several servers, folded from
/// every source by ``MediaItemMerger/unifiedWatchState(from:)``.
public struct UnifiedWatchState: Sendable, Hashable {
    /// Resume position to surface (seconds), or `nil` when not resumable.
    public var resumePosition: TimeInterval?
    /// Fractional progress to surface in `0...1`, or `nil` when unknown.
    public var playedPercentage: Double?
    /// Whether the title should read as fully watched.
    public var isPlayed: Bool
    /// The newest play timestamp seen across servers, or `nil` when none reported.
    public var lastPlayedAt: Date?

    public init(resumePosition: TimeInterval?, playedPercentage: Double?, isPlayed: Bool, lastPlayedAt: Date?) {
        self.resumePosition = resumePosition
        self.playedPercentage = playedPercentage
        self.isPlayed = isPlayed
        self.lastPlayedAt = lastPlayedAt
    }
}

/// Pure, provider-agnostic cross-server merge — the single component Home,
/// aggregated Library browse and Search all share for collapsing the *same* title
/// living on several Plex/Jellyfin servers into one card.
///
/// It generalises the union-find that used to live in
/// `FeatureSearch.SearchDeduplicator`, preserving its safety rules
/// (``MediaItemIdentity``), and goes further than the old code by recording, for
/// every server, that server's **own** item id, versions and watch-state in
/// ``MediaItem/sources``. That is what makes the server picker, cross-server
/// playback fallback, watch-state fan-out and the most-recent-wins unified state
/// possible — the old `additionalSourceAccountIDs` only remembered *which*
/// accounts also held the title, not how to actually address it there.
///
/// Determinism: the **first** occurrence of a duplicate set stays primary (so the
/// aggregator's interleave/relevance order is respected), `providerIDs` are
/// unioned, and `sources`/`additionalSourceAccountIDs` list the primary first
/// then the de-duplicated alternates in first-seen order.
public enum MediaItemMerger {
    /// Collapses duplicate items referring to the same title across providers into
    /// a single merged item, preserving the input order.
    ///
    /// - Parameters:
    ///   - items: the items to de-duplicate (already in display order).
    ///   - serverInfo: resolves an account id to its backend kind / friendly
    ///     names, used only to label ``MediaSourceRef``s. Defaults to "unknown",
    ///     which still merges correctly — the picker just shows neutral labels.
    public static func merge(
        _ items: [MediaItem],
        serverInfo: (String) -> SourceServerInfo? = { _ in nil }
    ) -> [MediaItem] {
        guard items.count > 1 else { return items }

        var parent = Array(items.indices)

        func find(_ index: Int) -> Int {
            var root = index
            while parent[root] != root { root = parent[root] }
            var node = index
            while parent[node] != node {
                let next = parent[node]
                parent[node] = root
                node = next
            }
            return root
        }

        func union(_ a: Int, _ b: Int) {
            let rootA = find(a)
            let rootB = find(b)
            guard rootA != rootB else { return }
            // Keep the lower index as the root so the first occurrence stays primary.
            if rootA < rootB { parent[rootB] = rootA } else { parent[rootA] = rootB }
        }

        var seen: [MediaIdentity: Int] = [:]
        for index in items.indices {
            for identity in MediaItemIdentity.identities(for: items[index]) {
                if let existing = seen[identity] {
                    union(existing, index)
                } else {
                    seen[identity] = index
                }
            }
        }

        var membersByRoot: [Int: [Int]] = [:]
        for index in items.indices {
            membersByRoot[find(index), default: []].append(index)
        }

        var output: [MediaItem] = []
        var emitted = Set<Int>()
        for index in items.indices {
            let root = find(index)
            guard emitted.insert(root).inserted else { continue }
            let members = membersByRoot[root] ?? [index]
            output.append(mergeGroup(members.map { items[$0] }, serverInfo: serverInfo))
        }
        return output
    }

    /// Merges one duplicate set (already in display order) into a single item:
    /// first is primary, `providerIDs` unioned, every distinct server captured as
    /// a ``MediaSourceRef``, and the top-level watch-state replaced with the
    /// most-recent-wins unified fold.
    public static func mergeGroup(
        _ duplicates: [MediaItem],
        serverInfo: (String) -> SourceServerInfo? = { _ in nil }
    ) -> MediaItem {
        guard var primary = duplicates.first else {
            preconditionFailure("mergeGroup requires at least one item")
        }
        guard duplicates.count > 1 else { return primary }

        // Union external ids so the merged card carries every catalogue id.
        var providerIDs = primary.providerIDs
        for duplicate in duplicates.dropFirst() {
            for (key, value) in duplicate.providerIDs where providerIDs[key] == nil {
                providerIDs[key] = value
            }
        }
        primary.providerIDs = providerIDs

        // Build one source ref per distinct (account, item), primary first. We
        // reuse any refs an already-merged input carried, then fold in each
        // member's own self-ref, so re-merging is idempotent and order-stable.
        var sources: [MediaSourceRef] = []
        var seenSourceIDs = Set<String>()
        func appendSource(_ ref: MediaSourceRef) {
            guard seenSourceIDs.insert(ref.id).inserted else { return }
            sources.append(ref)
        }
        for duplicate in duplicates {
            if duplicate.sources.isEmpty {
                if let ref = selfSource(for: duplicate, serverInfo: serverInfo) {
                    appendSource(ref)
                }
            } else {
                duplicate.sources.forEach(appendSource)
            }
        }
        primary.sources = sources

        // Legacy alternates list (other distinct accounts, first-seen order) kept
        // for callers that still read it.
        var alternates: [String] = []
        var seenAccounts = Set(primary.sourceAccountID.map { [$0] } ?? [])
        for accountID in sources.map(\.accountID) where !seenAccounts.contains(accountID) {
            seenAccounts.insert(accountID)
            alternates.append(accountID)
        }
        primary.additionalSourceAccountIDs = alternates

        // Unified, most-recent-wins watch-state surfaced at the top level so Home
        // reflects progress made on *any* server regardless of which one backs the
        // primary card. Favourite is OR-ed (watchlisted-anywhere).
        let unified = unifiedWatchState(from: sources)
        primary.resumePosition = unified.resumePosition
        primary.playedPercentage = unified.playedPercentage
        primary.isPlayed = unified.isPlayed
        primary.lastPlayedAt = unified.lastPlayedAt
        primary.isFavorite = sources.contains { $0.isFavorite } || primary.isFavorite

        return primary
    }

    /// Builds a ``MediaSourceRef`` describing the server a single (un-merged) item
    /// came from, used when an input item doesn't already carry its own
    /// `sources`. Returns `nil` when the item isn't tagged with an account.
    private static func selfSource(
        for item: MediaItem,
        serverInfo: (String) -> SourceServerInfo?
    ) -> MediaSourceRef? {
        guard let accountID = item.sourceAccountID else { return nil }
        let info = serverInfo(accountID)
        return MediaSourceRef(
            accountID: accountID,
            itemID: item.id,
            providerKind: info?.providerKind,
            serverName: info?.serverName,
            accountName: info?.accountName,
            versions: item.versions,
            resumePosition: item.resumePosition,
            playedPercentage: item.playedPercentage,
            isPlayed: item.isPlayed,
            isFavorite: item.isFavorite,
            lastPlayedAt: item.lastPlayedAt
        )
    }

    /// Folds every server's watch-state into one, **most-recent-wins**: the source
    /// with the newest `lastPlayedAt` is authoritative (so 4 minutes watched on
    /// server A surface even when server B backs the card, and un-watching on the
    /// newest server wins over an older "played"). When no server reports a
    /// timestamp it falls back to the best-known progress — watched-anywhere wins,
    /// otherwise the furthest resume position.
    public static func unifiedWatchState(from sources: [MediaSourceRef]) -> UnifiedWatchState {
        guard !sources.isEmpty else {
            return UnifiedWatchState(resumePosition: nil, playedPercentage: nil, isPlayed: false, lastPlayedAt: nil)
        }

        let timestamped = sources.compactMap { source -> (MediaSourceRef, Date)? in
            source.lastPlayedAt.map { (source, $0) }
        }
        if let winner = timestamped.max(by: { $0.1 < $1.1 })?.0 {
            return UnifiedWatchState(
                resumePosition: winner.isPlayed ? nil : winner.resumePosition,
                playedPercentage: winner.playedPercentage,
                isPlayed: winner.isPlayed,
                lastPlayedAt: winner.lastPlayedAt
            )
        }

        // No timestamps anywhere — best-known progress.
        let isPlayed = sources.contains { $0.isPlayed }
        if isPlayed {
            return UnifiedWatchState(resumePosition: nil, playedPercentage: 1.0, isPlayed: true, lastPlayedAt: nil)
        }
        let mostProgressed = sources.max(by: { ($0.resumePosition ?? 0) < ($1.resumePosition ?? 0) })
        return UnifiedWatchState(
            resumePosition: mostProgressed?.resumePosition,
            playedPercentage: mostProgressed?.playedPercentage,
            isPlayed: false,
            lastPlayedAt: nil
        )
    }
}

public extension Array where Element == ResolvedAccount {
    /// Builds an account-id → ``SourceServerInfo`` lookup so the cross-server
    /// merge can label each ``MediaSourceRef`` with its backend kind and friendly
    /// server/user name for the server picker.
    func sourceServerInfo() -> [String: SourceServerInfo] {
        var map: [String: SourceServerInfo] = [:]
        for resolved in self {
            map[resolved.account.id] = SourceServerInfo(
                providerKind: resolved.account.server.provider,
                serverName: resolved.account.server.name,
                accountName: resolved.account.userName
            )
        }
        return map
    }
}
