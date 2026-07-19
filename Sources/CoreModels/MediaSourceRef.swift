import Foundation

/// A reference to *one server's* copy of a title that has been recognised as the
/// same work across multiple servers (the cross-server merge in
/// ``MediaItemMerger``).
///
/// The legacy `MediaItem.additionalSourceAccountIDs` only remembered *which*
/// accounts also held a merged title — it threw away each server's own item id,
/// versions and watch-state. That was enough to fall back to another server, but
/// not enough to actually *play the right file there*, offer a "play from which
/// server?" picker, or unify watch-state, because every server addresses the
/// same title by a **different** local id (Jellyfin item id vs Plex ratingKey).
///
/// `MediaSourceRef` keeps all of that per server, so a merged card can:
///  * route playback to any server using **that server's** `itemID`;
///  * present a server picker (and, within a server, a version/edition picker);
///  * fold every server's watch-state into one unified, most-recent-wins state;
///  * fan a mark-watched / watchlist write out to every server that has the title.
public struct MediaSourceRef: Codable, Hashable, Identifiable, Sendable {
    /// The owning `Account.id`.
    public var accountID: String
    /// **This server's** local id for the title (Jellyfin item id / Plex
    /// ratingKey). The id playback and watch-state writes must use for this source.
    public var itemID: String
    /// This server's owning library id for the title (matches `MediaLibrary.id`),
    /// when the provider/aggregator could attribute it. Lets a merged card test
    /// each server's library against Home-visibility independently (so the card
    /// shows if *any* contributing library is visible). `nil` ⇒ this source is
    /// fail-open (not attributable to a hidden library).
    public var libraryID: String?
    /// The **media kind** of the underlying item this source addresses (movie /
    /// series / episode …). Stamped from the item/`IndexedSource` at construction so
    /// every consumer can enforce the cross-kind boundary: an episode's source set
    /// must never contain a movie ref (and vice versa). `nil` for a ref decoded from
    /// a cache written before this field existed — treated as **untyped**, trusted
    /// only when it is the item's own self-ref (see ``retainingKindCompatible``), so
    /// a stale cross-kind twin frozen in an old cache can't route playback/fan-out.
    public var kind: MediaItemKind?
    /// The backend this source lives on — drives the server-picker icon/label.
    /// Optional because the merge core can run without an account→kind resolver
    /// (e.g. Search), in which case the picker falls back to a neutral label.
    public var providerKind: ProviderKind?
    /// Display name of the server (for the server picker), when known.
    public var serverName: String?
    /// Display name of the signed-in user on this server, to disambiguate two
    /// accounts on the same server. `nil` when unknown.
    public var accountName: String?
    /// How reachable this source's server is from the device right now (same-LAN
    /// vs remote/Tailscale). The **top** ranking key in ``CrossSourceSelector`` so
    /// a merged title plays from its local copy when one exists. `nil` when the
    /// merge ran without a locality-aware resolver (treated as the middle tier).
    public var locality: SourceLocality?
    /// This server's selectable versions for the title. Empty until a detail
    /// fetch populates them (rows/cards never carry versions), so a server can be
    /// chosen before its file list is known (the server default plays).
    public var versions: [MediaVersion]

    // Per-source watch-state, folded into the merged item's unified state.

    /// Saved resume position in seconds on this server, if any.
    public var resumePosition: TimeInterval?
    /// Fractional watched progress in `0...1` on this server, if reported.
    public var playedPercentage: Double?
    /// Whether this server considers the title fully played.
    public var isPlayed: Bool
    /// Whether this server reports that the title was completed previously,
    /// independent of a current rewatch resume point.
    public var hasBeenPlayed: Bool
    /// Whether this server has the title favourited / watchlisted.
    public var isFavorite: Bool
    /// When the title was last played on this server, used as the most-recent-wins
    /// tiebreaker when folding watch-state across servers. `nil` when unknown.
    public var lastPlayedAt: Date?

    public init(
        accountID: String,
        itemID: String,
        libraryID: String? = nil,
        kind: MediaItemKind? = nil,
        providerKind: ProviderKind? = nil,
        serverName: String? = nil,
        accountName: String? = nil,
        locality: SourceLocality? = nil,
        versions: [MediaVersion] = [],
        resumePosition: TimeInterval? = nil,
        playedPercentage: Double? = nil,
        isPlayed: Bool = false,
        hasBeenPlayed: Bool? = nil,
        isFavorite: Bool = false,
        lastPlayedAt: Date? = nil
    ) {
        self.accountID = accountID
        self.itemID = itemID
        self.libraryID = libraryID
        self.kind = kind
        self.providerKind = providerKind
        self.serverName = serverName
        self.accountName = accountName
        self.locality = locality
        self.versions = versions
        self.resumePosition = resumePosition
        self.playedPercentage = playedPercentage
        self.isPlayed = isPlayed
        self.hasBeenPlayed = hasBeenPlayed ?? isPlayed
        self.isFavorite = isFavorite
        self.lastPlayedAt = lastPlayedAt
    }

    private enum CodingKeys: String, CodingKey {
        case accountID, itemID, libraryID, kind, providerKind, serverName, accountName
        case locality, versions, resumePosition, playedPercentage, isPlayed
        case hasBeenPlayed, isFavorite, lastPlayedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accountID = try container.decode(String.self, forKey: .accountID)
        itemID = try container.decode(String.self, forKey: .itemID)
        libraryID = try container.decodeIfPresent(String.self, forKey: .libraryID)
        kind = try container.decodeIfPresent(MediaItemKind.self, forKey: .kind)
        providerKind = try container.decodeIfPresent(ProviderKind.self, forKey: .providerKind)
        serverName = try container.decodeIfPresent(String.self, forKey: .serverName)
        accountName = try container.decodeIfPresent(String.self, forKey: .accountName)
        locality = try container.decodeIfPresent(SourceLocality.self, forKey: .locality)
        versions = try container.decodeIfPresent([MediaVersion].self, forKey: .versions) ?? []
        resumePosition = try container.decodeIfPresent(TimeInterval.self, forKey: .resumePosition)
        playedPercentage = try container.decodeIfPresent(Double.self, forKey: .playedPercentage)
        isPlayed = try container.decodeIfPresent(Bool.self, forKey: .isPlayed) ?? false
        hasBeenPlayed = try container.decodeIfPresent(Bool.self, forKey: .hasBeenPlayed) ?? isPlayed
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        lastPlayedAt = try container.decodeIfPresent(Date.self, forKey: .lastPlayedAt)
    }

    /// Stable identity: a title appears at most once per (account, item) pair.
    public var id: String { "\(accountID):\(itemID)" }

    /// A short, human-readable label for the server-picker row, e.g.
    /// "Plex · Living Room" or just the server name. Falls back to the provider
    /// kind's display name, then a neutral "Server", when nothing else is known.
    public var displayName: String {
        if let serverName, !serverName.trimmingCharacters(in: .whitespaces).isEmpty {
            return serverName
        }
        if let accountName, !accountName.trimmingCharacters(in: .whitespaces).isEmpty {
            if let providerKind {
                return "\(providerKind.displayName) · \(accountName)"
            }
            return accountName
        }
        return providerKind?.displayName ?? "Server"
    }

    /// Whether this source ref may legitimately belong to a merged item of
    /// `itemKind` whose own (and any co-merged members') physical identities are in
    /// `selfIDs` ("account:item"). The cross-kind boundary that keeps an episode's
    /// source set free of an unrelated movie (and vice versa):
    ///  * a ref that IS one of `selfIDs` is always kept (never strip an item's own
    ///    source, even a legacy untyped one, so we can't leave a card sourceless);
    ///  * a **typed** peer is kept only when its `kind` matches `itemKind`;
    ///  * an **untyped** peer (legacy `nil` kind, not a self-ref) is rejected — that
    ///    is the stale cross-kind twin a pre-`kind` cache may have frozen in.
    public func isKindCompatible(with itemKind: MediaItemKind, selfIDs: Set<String>) -> Bool {
        if selfIDs.contains(id) { return true }
        if let kind { return kind == itemKind }
        return false
    }

    /// Filters `refs` to those kind-compatible with an item of `itemKind` whose own
    /// (and co-merged members') self-ids are `selfIDs`. See ``isKindCompatible``.
    public static func retainingKindCompatible(
        _ refs: [MediaSourceRef],
        itemKind: MediaItemKind,
        selfIDs: Set<String>
    ) -> [MediaSourceRef] {
        refs.filter { $0.isKindCompatible(with: itemKind, selfIDs: selfIDs) }
    }
}
