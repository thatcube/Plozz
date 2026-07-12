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
    /// The **physical** server id (``MediaServer/id``) this account connects to.
    /// Stable across two user accounts on the *same* server, so the merge can
    /// collapse a title returned by both accounts (same server-global item id)
    /// without a bare `.sameItemID` that would also collide across *different*
    /// servers. `nil` when the merge runs without an account→server resolver.
    public var serverID: String?
    /// How reachable this account's server is from the device right now
    /// (same-LAN vs remote/Tailscale), used to prefer the local copy of a merged
    /// title for playback. `nil` when unknown/unclassified (treated as the middle
    /// tier by ``CrossSourceSelector``).
    public var locality: SourceLocality?

    public init(
        providerKind: ProviderKind? = nil,
        serverName: String? = nil,
        accountName: String? = nil,
        serverID: String? = nil,
        locality: SourceLocality? = nil
    ) {
        self.providerKind = providerKind
        self.serverName = serverName
        self.accountName = accountName
        self.serverID = serverID
        self.locality = locality
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
    ///   - identitySources: the **single source of truth** lookup — given a merged
    ///     item, returns every server known (from the eager identity index) to host
    ///     that title. Folded into each card's `sources` so a title surfaced by
    ///     only one server still carries its full cross-server set, making Home,
    ///     Browse, Search and the watch fan-out all read one consistent set
    ///     regardless of entry path. Defaults to a no-op so cold-start / existing
    ///     callers behave exactly as before.
    public static func merge(
        _ items: [MediaItem],
        serverInfo: (String) -> SourceServerInfo? = { _ in nil },
        identitySources: (MediaItem) -> [MediaSourceRef] = { _ in [] }
    ) -> [MediaItem] {
        guard !items.isEmpty else { return items }

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

        // Union by shared identity, but scoped to the media **kind**: TMDb/TVDb
        // reuse the same integer id space across movies and series (TMDb *movie*
        // 550 is a different work from TMDb *tv* 550), so two items that merely
        // share an id across kinds must NOT collapse into one card. We can't fix
        // this in `identities(for:)` — several call sites/tests rely on it
        // emitting bare, kind-less external ids — so the kind scoping lives here:
        // an identity is only a merge key *within* one kind.
        //
        // There is deliberately NO cross-kind wildcard. An item we couldn't
        // confidently type (`.unknown`/`.folder`/`.collection`) merges only with
        // other items of the *same* kind sharing the identity — never bridging,
        // say, a movie and a series that happen to reuse an external integer id,
        // which a wildcard would collapse into one wrong card.
        var seen: [KindScopedIdentity: Int] = [:]
        for index in items.indices {
            let kind = items[index].kind
            for identity in MediaItemIdentity.identities(for: items[index]) {
                let key = KindScopedIdentity(identity: identity, kind: kind)
                if let existing = seen[key] {
                    union(existing, index)
                } else {
                    seen[key] = index
                }
            }
        }

        // Same-server / two-account dedup: a single physical server seen through
        // two different user accounts returns the *same server-global item id* for
        // a title, which must collapse to one card (fixes the "ghost spacing"
        // empty gaps). This is scoped by the **physical server id** — a bare item
        // id can't be a cross-server identity because Plex `ratingKey`s are small
        // per-server integers that collide across unrelated servers. When no
        // server resolver is supplied (serverID unknown) we fall back to the
        // account id, which still collapses exact same-account duplicates and can
        // never bridge two servers.
        var seenServerItem: [String: Int] = [:]
        for index in items.indices {
            let item = items[index]
            let scope = item.sourceAccountID.flatMap { serverInfo($0)?.serverID } ?? item.sourceAccountID
            guard let scope else { continue }
            let key = "\(scope)\u{1F}\(item.id)"
            if let existing = seenServerItem[key] {
                union(existing, index)
            } else {
                seenServerItem[key] = index
            }
        }

        // Cross-server union by the eager index's **membership**, to recover rows
        // the identity keys above can't merge. A row whose list payload lacked a
        // strong external id (Plex omits `Guid` on some list responses) shares no
        // `.external` key with a twin that *does* carry one — and rule #1 suppresses
        // the twin's `.title` key — so the two stay separate cards even though the
        // index, enriched via per-item fetch during warm, knows both are one title.
        // `identitySources(row)` returns that recovered membership set (each entry a
        // server's own item id, incl. via the snapshot's reverse (account,item)→
        // identity lookup for the id-less row itself); if a row's membership names
        // another *loaded* row's own (account,item) they are the same work and must
        // collapse. Safe: it unions only on the index's confident per-item
        // enrichment, never a guessed title, so it can't false-merge distinct works.
        // A no-op `identitySources` (cold start / most tests) skips this entirely.
        var ownerByRef: [String: Int] = [:]
        for index in items.indices {
            guard let accountID = items[index].sourceAccountID else { continue }
            ownerByRef["\(accountID):\(items[index].id)"] = index
        }
        if !ownerByRef.isEmpty {
            for index in items.indices {
                for ref in identitySources(items[index]) {
                    guard let owner = ownerByRef["\(ref.accountID):\(ref.itemID)"], owner != index else { continue }
                    union(index, owner)
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
            // Split-guard: a shared *external id* is normally authoritative, but a
            // single bad id on one server (e.g. an unreleased sequel scraped with
            // its predecessor's TMDb/IMDb id) would otherwise collapse two distinct
            // films into one card. Refine the union component into sub-groups of
            // mutually-plausible items, ejecting any member that POSITIVELY
            // contradicts the others (titles disagree AND years don't corroborate).
            // Conservative by construction — sparse-metadata / id-less rows carry no
            // positive contradiction, so the index-membership merges we rely on are
            // never wrongly split; only a genuine mismatch separates.
            for group in refineComponent(members.map { items[$0] }) {
                output.append(mergeGroup(group, serverInfo: serverInfo, identitySources: identitySources))
            }
        }
        return output
    }

    /// Partitions one union component into sub-groups of mutually-plausible items,
    /// so a false merge (two different works bridged by a bad shared external id)
    /// is broken back apart. Greedy: each member joins the first existing group it
    /// contradicts no member of, else opens a new group. Order-preserving — the
    /// anchor (first) member's group stays first, so the primary card keeps its
    /// display position and any ejected impostor follows it. A single-member
    /// component is returned unchanged.
    static func refineComponent(_ members: [MediaItem]) -> [[MediaItem]] {
        guard members.count > 1 else { return [members] }
        var groups: [[MediaItem]] = []
        for member in members {
            if let idx = groups.firstIndex(where: { group in
                !group.contains(where: { plausiblyContradicts($0, member) })
            }) {
                groups[idx].append(member)
            } else {
                groups.append([member])
            }
        }
        return groups
    }

    /// Whether two items are almost certainly *different* works despite sharing a
    /// merge key — the positive-contradiction signal the split-guard ejects on.
    /// Delegates to the shared, index-reusable primitive so a bad shared external
    /// id is split identically here (full-item merges) and inside the identity
    /// index's membership walk (which stores only title/year per source).
    static func plausiblyContradicts(_ a: MediaItem, _ b: MediaItem) -> Bool {
        MediaItemIdentity.titlesPlausiblyContradict(
            titleA: a.title,
            yearA: a.productionYear,
            kindA: a.kind,
            titleB: b.title,
            yearB: b.productionYear,
            kindB: b.kind
        )
    }

    /// Normalized titles are compatible when identical or one is a word-boundary
    /// prefix of the other ("dune" vs "dune 2021"), so subtitle/year suffixes don't
    /// read as a clash while a differing trailing token ("scream 6" vs "scream 7")
    /// does.
    static func titlesCompatible(_ a: String, _ b: String) -> Bool {
        MediaItemIdentity.normalizedTitlesCompatible(a, b)
    }

    /// Merges one duplicate set (already in display order) into a single item:
    /// first is primary, `providerIDs` unioned, every distinct server captured as
    /// a ``MediaSourceRef``, and the top-level watch-state replaced with the
    /// most-recent-wins unified fold.
    public static func mergeGroup(
        _ duplicates: [MediaItem],
        serverInfo: (String) -> SourceServerInfo? = { _ in nil },
        identitySources: (MediaItem) -> [MediaSourceRef] = { _ in [] }
    ) -> MediaItem {
        guard var primary = duplicates.first else {
            preconditionFailure("mergeGroup requires at least one item")
        }

        // The eager index's known servers for this title (origin-agnostic SSOT),
        // resolved from the primary's identities. Folded in below so even a
        // single-source card carries its full cross-server set.
        let indexSources = identitySources(primary)
        guard duplicates.count > 1 || !indexSources.isEmpty else { return primary }

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
        // Append index-only servers LAST so the loaded rows' live watch-state
        // always wins the unified fold (index refs carry no watch-state); they
        // only add membership that no loaded row surfaced.
        for ref in indexSources { appendSource(ref) }
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
        primary.hasBeenPlayed = sources.contains(where: \.hasBeenPlayed)
            || duplicates.contains(where: \.hasBeenPlayed)
        primary.lastPlayedAt = unified.lastPlayedAt
        primary.isFavorite = sources.contains { $0.isFavorite } || primary.isFavorite

        return primary
    }

    /// Builds a ``MediaSourceRef`` describing the server a single (un-merged) item
    /// came from, used when an input item doesn't already carry its own
    /// `sources`. Returns `nil` when the item isn't tagged with an account.
    ///
    /// When the item has no intrinsic ``MediaItem/versions`` (the common
    /// single-file case), the ref is seeded with **one synthesised** version so
    /// that grouped same-account duplicates still produce a combinable version
    /// list — without this the picker would see two `versions: []` entries and
    /// silently show nothing.
    private static func selfSource(
        for item: MediaItem,
        serverInfo: (String) -> SourceServerInfo?
    ) -> MediaSourceRef? {
        guard let accountID = item.sourceAccountID else { return nil }
        // A Plex **Discover / watchlist stub** addresses the title only by its
        // GLOBAL catalog guid — its own `id` equals the `PlexGuid` tail
        // (`plex://show/<id>` → `<id>`). No Plex Media Server can play that global
        // id, so the stub must NOT contribute a playable source: doing so let a
        // dead Discover ref win best-source selection over the real library copy,
        // surfacing as "Can't play this right now" for a title the user owns. The
        // concrete, playable library copies are folded in via the identity index
        // instead (the same way Seerr items — which carry no `sourceAccountID` —
        // already rely on the index). Real library items are unaffected: their
        // integer ratingKey never equals the 24-hex global guid tail.
        if let plexGuid = item.providerIDs["PlexGuid"],
           let guidTail = plexGuid.split(separator: "/").last.map(String.init),
           item.id == guidTail {
            return nil
        }
        let info = serverInfo(accountID)
        let versions = item.versions.isEmpty ? [MediaVersion.synthesized(from: item)] : item.versions
        return MediaSourceRef(
            accountID: accountID,
            itemID: item.id,
            libraryID: item.libraryID,
            providerKind: info?.providerKind,
            serverName: info?.serverName,
            accountName: info?.accountName,
            locality: info?.locality,
            versions: versions,
            resumePosition: item.resumePosition,
            playedPercentage: item.playedPercentage,
            isPlayed: item.isPlayed,
            hasBeenPlayed: item.hasBeenPlayed,
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

        let timestamped = sources.enumerated().compactMap { offset, source -> (offset: Int, source: MediaSourceRef, date: Date)? in
            source.lastPlayedAt.map { (offset, source, $0) }
        }
        // Newest timestamp wins; on an exact tie (e.g. two servers both stamped
        // `now` by a mark-watched fan-out) the lower offset — the primary, listed
        // first — wins, so `resumePosition` can't flip between reloads.
        if let winner = timestamped.max(by: { lhs, rhs in
            lhs.date != rhs.date ? lhs.date < rhs.date : lhs.offset > rhs.offset
        })?.source {
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

    /// The resume position **playback** should seek to for a title that lives on
    /// several servers — the cross-server *furthest progress*, independent of
    /// which server backs the chosen stream.
    ///
    /// This is the convergence rule from the strategy (resume authority = servers,
    /// **furthest-progress wins**) and the fix for the best-source-routing bug: the
    /// merged card shows "4 min watched on Plex", best-source routing picks the
    /// Jellyfin copy whose own `resumePosition` is `0`, and playback must still
    /// resume at 4 min. It deliberately differs from ``unifiedWatchState`` (which
    /// is *most-recent-wins* for **display**): for the act of pressing Play we never
    /// want to rewind below the furthest point any server knows about.
    ///
    /// Returns `nil` (start from the beginning) when the unified state reads as
    /// fully **played** — i.e. the title is finished, so Play is a rewatch — using
    /// the same most-recent-wins authority the card displays, so an explicit
    /// newer "unwatch" still re-enables resume.
    public static func playbackResumePosition(from sources: [MediaSourceRef]) -> TimeInterval? {
        guard !sources.isEmpty else { return nil }
        if unifiedWatchState(from: sources).isPlayed { return nil }
        let furthest = sources
            .filter { !$0.isPlayed }
            .compactMap(\.resumePosition)
            .max()
        guard let furthest, furthest > 0 else { return nil }
        return furthest
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
                accountName: resolved.account.userName,
                serverID: resolved.account.server.id,
                locality: resolved.provider.connectionLocality
            )
        }
        return map
    }
}

/// A ``MediaIdentity`` scoped to a media **kind**, so an external id shared
/// across different kinds (TMDb/TVDb reuse integer ids between movies and series)
/// can't merge a movie into a series. See the union step in ``MediaItemMerger``.
/// The scope is the raw ``MediaItemKind`` (not a coarse bucket) so every kind —
/// including the untyped `.unknown`/`.folder`/`.collection` — only ever merges
/// with its own kind, never bridging two kinds that happen to reuse an id.
/// A merge key scoped to one ``MediaItemKind`` (see the union loop above): an
/// identity only unifies items of the *same* kind, so a movie and a series that
/// reuse an external integer id never collapse.
///
/// KNOWN LIMITATION (deliberately not addressed here — r6-episode-false-merge):
/// this scopes by kind but NOT by episode position. If two DIFFERENT episodes of
/// one series are ever merged together (e.g. an aggregated row containing raw
/// episode items), and their metadata carries *series-level* external ids
/// (anilist/tvdb on the episode instead of episode-level ids), they would share a
/// `.episode` KindScopedIdentity and collapse into one card. In practice this
/// doesn't fire: episodes are never indexed (see ``IdentityIndex.ingest``) and
/// both providers stamp episode-LEVEL external ids, so Ep1/Ep2 get distinct
/// identities. Adding season+episode number to the key for `.episode` would make
/// the guard airtight, but the conservative stance ("a missed merge is far better
/// than a wrong merge") plus the no-episode-indexing rule makes it unnecessary
/// today. Revisit only if a provider is found emitting series-level ids on
/// episode items.
struct KindScopedIdentity: Hashable {
    let identity: MediaIdentity
    let kind: MediaItemKind
}
