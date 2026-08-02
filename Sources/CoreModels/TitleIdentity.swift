import Foundation

// MARK: - Canonical ordering of identity evidence

public extension MediaIdentity {
    /// Priority rank of the *namespace* an identity is expressed in, lowest first.
    ///
    /// This is the ordering that lets a title pick **one** canonical key out of the
    /// several identities it may carry. It deliberately mirrors
    /// ``MediaItemIdentity/strongExternalNamespaces`` so the canonical key is always
    /// the strongest catalogue id available, and only ever falls back to weak
    /// title/year (or a provider-local id) when nothing stronger exists anywhere in
    /// the title's cross-server component.
    var canonicalRank: Int {
        switch self {
        case .external(let source, _):
            let base = source.split(separator: ":", maxSplits: 1).first.map(String.init) ?? source
            if let index = Self.strongNamespaceRank[base] { return index }
            if base == "plexguid" { return 50 }
            if base.hasPrefix("series-"),
               let index = Self.strongNamespaceRank[String(base.dropFirst("series-".count))] {
                return 100 + index
            }
            return 500
        case .title:
            return 900
        case .sameItemID:
            return 950
        }
    }

    /// A total, deterministic order over identities: namespace priority first, then
    /// the raw `(source, value)` pair. Two devices holding the same evidence always
    /// choose the same minimum.
    static func isCanonicallyOrderedBefore(_ lhs: MediaIdentity, _ rhs: MediaIdentity) -> Bool {
        if lhs.canonicalRank != rhs.canonicalRank { return lhs.canonicalRank < rhs.canonicalRank }
        return lhs.canonicalSortKey < rhs.canonicalSortKey
    }

    /// Stable, human-debuggable token. Deliberately matches the string shapes
    /// ``WatchMutation/canonicalMediaID(providerIDs:title:year:kind:fallback:)``
    /// already persists (`imdb:tt0133093`, `title:the matrix:1999`) so existing
    /// durable outbox rows keep coalescing against newly written ones.
    var canonicalToken: String {
        switch self {
        case .external(let source, let value):
            return "\(source):\(value)"
        case .title(let normalizedTitle, let year, _):
            return year.map { "title:\(normalizedTitle):\($0)" } ?? "title:\(normalizedTitle)"
        case .sameItemID(let value):
            return "same:\(value)"
        }
    }

    private var canonicalSortKey: String {
        switch self {
        case .external(let source, let value): return "0\u{0}\(source)\u{0}\(value)"
        case .title(let title, let year, let kind):
            return "1\u{0}\(kind.rawValue)\u{0}\(title)\u{0}\(year.map(String.init) ?? "")"
        case .sameItemID(let value): return "2\u{0}\(value)"
        }
    }

    private static let strongNamespaceRank: [String: Int] = {
        var result: [String: Int] = [:]
        for (offset, entry) in MediaItemIdentity.strongExternalNamespaces.enumerated() {
            result[entry.canonical] = offset
        }
        return result
    }()
}


// MARK: - Cross-list overlap

public extension MediaItemIdentity {
    /// Kind-scoped identity tokens for asking "do these two *lists* contain the same
    /// title?" — the question search asks when it decides whether a Seerr result is
    /// already in the viewer's library.
    ///
    /// Deliberately a **set of all** identities rather than one canonical key. The two
    /// lists come from different providers and rarely carry the same id: a Jellyfin
    /// row may expose IMDb + TVDB while the Seerr row exposes only TMDb, so any
    /// "pick one key and compare" scheme misses. Overlap is non-empty intersection.
    ///
    /// The kind prefix matters: a movie and a series routinely share a TMDb integer,
    /// and an unscoped compare silently hides a requestable show because an unrelated
    /// film happened to own the same number.
    static func overlapKeys(for item: MediaItem) -> Set<String> {
        Set(identities(for: item).map { "\(item.kind.rawValue)|\($0.canonicalToken)" })
    }

    /// Whether `lhs` and `rhs` are the same title by any shared strong identity.
    static func overlaps(_ lhs: MediaItem, _ rhs: MediaItem) -> Bool {
        !overlapKeys(for: lhs).isDisjoint(with: overlapKeys(for: rhs))
    }
}


/// **The** grouping key for a title across the whole app.
///
/// Plozz has one identity layer with three roots, strongest first:
///
/// - ``Root/alias`` — the durable Plozz UUID (``MediaAliasID``). Used whenever the
///   title has real Plozz-owned state (today: a watchlist entry). This is the
///   identity that syncs through iCloud and survives title/year/artwork changes,
///   server churn and re-scrapes.
/// - ``Root/evidence`` — the canonical identity of the title's refined cross-server
///   component (see ``TitleComponentLabeller``), used while no durable record exists.
///   Resolution is **lazy**: browsing Related, Search, discovery or person credits
///   must never mint a durable record, or the ledger grows without bound.
/// - ``Root/local`` — an account-scoped provider-local fallback for items with no
///   usable evidence at all (a yearless movie with no external ids, a raw share
///   file). Never collides across servers, and never merges anything — which matches
///   what ``MediaItemMerger`` already does with such items.
///
/// ## Lifetime — read this before using it
///
/// An evidence root is a function of **live, per-device index state**. It legitimately
/// changes when the index warms, when an account is added or removed, or when a
/// component grows and a stronger id joins it. That is fine for what this type is for
/// and fatal for what it is not for:
///
/// - ✅ dedup / grouping / membership lookup **within one prepared-state wave**
/// - ❌ SwiftUI `id:` or focus identity — use ``MediaItem/stablePresentationID``.
///   A changing key tears down and rebuilds the row, which on tvOS throws focus back
///   to the start of the rail mid-scroll.
/// - ❌ durable keys. It is deliberately **not `Codable`** so persisting one is a
///   compile error. Durable per-title state keys on ``MediaAliasID``; the watch outbox
///   and download registry keep their own frozen key schemes (see their docs for why).
public struct TitleIdentity: Hashable, Sendable {
    public enum Root: Hashable, Sendable {
        case alias(MediaAliasID)
        case evidence(MediaIdentity)
        case local(String)
    }

    /// Always kind-scoped: a TMDb movie id and a TMDb series id sharing one integer
    /// are different titles.
    public let kind: MediaItemKind
    public let root: Root

    public init(kind: MediaItemKind, root: Root) {
        self.kind = kind
        self.root = root
    }

    /// The durable Plozz UUID, when this title has one.
    public var aliasID: MediaAliasID? {
        if case .alias(let id) = root { return id }
        return nil
    }

    /// Whether this identity is backed by a durable, syncable Plozz record.
    public var isDurable: Bool { aliasID != nil }

    /// The canonical evidence this identity resolved from, when evidence-rooted.
    public var evidence: MediaIdentity? {
        if case .evidence(let identity) = root { return identity }
        return nil
    }

    /// Debug/diagnostics description. Deliberately **not** a persistence format — see
    /// the lifetime note above.
    public var debugToken: String {
        switch root {
        case .alias(let id): return "plozz:\(id.description)"
        case .evidence(let identity): return identity.canonicalToken
        case .local(let value): return "local:\(value)"
        }
    }
}

extension TitleIdentity: CustomStringConvertible {
    public var description: String { "\(kind.rawValue)|\(debugToken)" }
}

// MARK: - Resolver

/// Resolves any ``MediaItem`` to its ``TitleIdentity``.
///
/// A pure `Sendable` value over two immutable snapshots — the live per-device evidence
/// (``IdentityIndexSnapshot``) and the durable Plozz ledger (``MediaAliasSnapshot``).
/// It performs **no disk, no network and no provider construction**, and its lookups
/// are O(1) table reads because the component work already happened once when the
/// index snapshot was built. It must still never be called from a SwiftUI `body`/`init`
/// — that is what prepared state is for.
///
/// Equality is by **revision**, not by content: comparing two large identity
/// dictionaries on every publication would cost more than the republication it is
/// meant to avoid. Callers bump `revision` whenever either snapshot is replaced, which
/// is what lets observers skip a wave that changed nothing.
public struct TitleIdentityResolver: Sendable, Equatable {
    public let index: IdentityIndexSnapshot
    public let aliases: MediaAliasSnapshot
    /// Monotonic per-app-run revision. Two resolvers are equal iff they were published
    /// from the same underlying snapshot pair.
    public let revision: UInt64

    public init(
        index: IdentityIndexSnapshot = .empty,
        aliases: MediaAliasSnapshot = .empty,
        revision: UInt64 = 0
    ) {
        self.index = index
        self.aliases = aliases
        self.revision = revision
    }

    public static let empty = TitleIdentityResolver()

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.revision == rhs.revision }

    /// The identity for `item`, preferring a durable Plozz alias when one exists.
    ///
    /// The alias is resolved from the item's **component** evidence, not from the
    /// item's own payload alone: otherwise two copies of one title — a Plex Discover
    /// row carrying only a `PlexGuid` and a Jellyfin row carrying an IMDb id — would
    /// take an `.alias` root and an `.evidence` root respectively and fail to group,
    /// in exactly the surfaces this type exists to fix.
    public func identity(for item: MediaItem) -> TitleIdentity {
        // A resolvable durable hint is the answer on its own — it is what the index
        // walk would have led to anyway. Checked FIRST because `canonicalEvidence`
        // walks a transitive component graph, and paying for that only to discard it
        // is pure waste on a path that callers reach per item.
        if let preferred = item.watchlistAliasID,
           let resolved = aliases.resolvedAliasID(for: preferred) {
            return TitleIdentity(kind: item.kind, root: .alias(resolved))
        }
        let canonical = index.canonicalEvidence(for: item)
        if let aliasID = durableAliasID(for: item, canonical: canonical) {
            return TitleIdentity(kind: item.kind, root: .alias(aliasID))
        }
        if let canonical {
            return TitleIdentity(kind: item.kind, root: .evidence(canonical))
        }
        // Not in the index (a discovery/external title, or a cold index): fall back to
        // the item's own strongest identity, chosen under the same total order so two
        // copies carrying the same evidence still agree.
        if let own = MediaItemIdentity.identities(for: item)
            .min(by: MediaIdentity.isCanonicallyOrderedBefore) {
            return TitleIdentity(kind: item.kind, root: .evidence(own))
        }
        return TitleIdentity(kind: item.kind, root: .local(localFallback(for: item)))
    }

    /// The durable Plozz UUID for `item`, or `nil` when it has no durable record.
    /// Never creates one — creation is an explicit ledger operation that must carry a
    /// reason, so browsing can never grow the ledger.
    public func aliasID(for item: MediaItem) -> MediaAliasID? {
        identity(for: item).aliasID
    }

    /// Groups items that are the same title. The returned order preserves each group's
    /// first appearance, so a row never reshuffles because identity was recomputed.
    public func grouped(_ items: [MediaItem]) -> [(identity: TitleIdentity, items: [MediaItem])] {
        var order: [TitleIdentity] = []
        var groups: [TitleIdentity: [MediaItem]] = [:]
        for item in items {
            let key = identity(for: item)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(item)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }

    /// First-wins dedup by title identity — the shared replacement for the several
    /// ad-hoc `kind|title|year` string keys that grew up around the app.
    public func deduplicated(_ items: [MediaItem]) -> [MediaItem] {
        var seen: Set<TitleIdentity> = []
        return items.filter { seen.insert(identity(for: $0)).inserted }
    }

    // MARK: - Internals

    private func durableAliasID(
        for item: MediaItem,
        canonical: MediaIdentity?
    ) -> MediaAliasID? {
        // `identity(for:)` has already tried `item.watchlistAliasID`.
        guard !aliases.recordsByID.isEmpty,
              let evidence = MediaAliasEvidence(item: item, canonicalEvidence: canonical) else {
            return nil
        }
        return MediaAliasResolver.lookup(evidence: evidence, in: aliases)
    }

    private func localFallback(for item: MediaItem) -> String {
        guard let accountID = item.sourceAccountID, !accountID.isEmpty else {
            return item.id
        }
        return "\(accountID):\(item.id)"
    }
}
