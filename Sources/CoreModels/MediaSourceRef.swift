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
    /// The backend this source lives on — drives the server-picker icon/label.
    /// Optional because the merge core can run without an account→kind resolver
    /// (e.g. Search), in which case the picker falls back to a neutral label.
    public var providerKind: ProviderKind?
    /// Display name of the server (for the server picker), when known.
    public var serverName: String?
    /// Display name of the signed-in user on this server, to disambiguate two
    /// accounts on the same server. `nil` when unknown.
    public var accountName: String?
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
    /// Whether this server has the title favourited / watchlisted.
    public var isFavorite: Bool
    /// When the title was last played on this server, used as the most-recent-wins
    /// tiebreaker when folding watch-state across servers. `nil` when unknown.
    public var lastPlayedAt: Date?

    public init(
        accountID: String,
        itemID: String,
        providerKind: ProviderKind? = nil,
        serverName: String? = nil,
        accountName: String? = nil,
        versions: [MediaVersion] = [],
        resumePosition: TimeInterval? = nil,
        playedPercentage: Double? = nil,
        isPlayed: Bool = false,
        isFavorite: Bool = false,
        lastPlayedAt: Date? = nil
    ) {
        self.accountID = accountID
        self.itemID = itemID
        self.providerKind = providerKind
        self.serverName = serverName
        self.accountName = accountName
        self.versions = versions
        self.resumePosition = resumePosition
        self.playedPercentage = playedPercentage
        self.isPlayed = isPlayed
        self.isFavorite = isFavorite
        self.lastPlayedAt = lastPlayedAt
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

    /// Whether this source carries in-progress resume state (started, not yet
    /// finished). Used by the unified-state fold and "Continue Watching" logic.
    public var hasResume: Bool {
        (resumePosition ?? 0) > 0 && !isPlayed
    }
}
