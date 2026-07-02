import Foundation

/// The seam between a context menu (CoreUI cards) and the app-level logic that
/// resolves the owning provider, performs an action, and refreshes the UI.
///
/// CoreUI depends only on this abstraction (injected through the SwiftUI
/// environment); `AppShell` supplies the concrete implementation. Kept SwiftUI-
/// free here so the protocol lives in CoreModels alongside the value types it
/// works with.
@MainActor
public protocol MediaItemActionHandling: AnyObject {
    /// The actions to show for `item` in `context` (empty hides the menu).
    func actions(for item: MediaItem, context: MediaItemActionContext) -> [MediaItemAction]

    /// Performs `action` on `item`. Implementations mutate server state and then
    /// broadcast `Notification.Name.mediaItemDidMutate` so visible screens can
    /// refresh from the source of truth. Fire-and-forget: the menu has already
    /// dismissed by the time the network call completes.
    func perform(_ action: MediaItemAction, on item: MediaItem, context: MediaItemActionContext)
}

public extension Notification.Name {
    /// Posted after a context-menu action mutates an item's state on the server
    /// (e.g. watched / unwatched). Screens showing media observe it and update
    /// in place. Read the payload via `Notification.mediaItemMutation`.
    static let mediaItemDidMutate = Notification.Name("PlozzMediaItemDidMutate")

    /// Posted each time the cross-server identity index warms a little more (a new
    /// account finishes indexing, so the shared source-of-truth membership grows).
    /// Screens that merged their rows against an earlier, sparser snapshot observe
    /// it and re-fold the *fresh* cross-server sources into their already-loaded
    /// cards **in place** — no refetch, no focus reset — so a card that cold-loaded
    /// before its local twin was known picks that twin up and can route playback to
    /// it. Carries no payload; observers read the live snapshot on receipt.
    static let identityIndexDidUpdate = Notification.Name("PlozzIdentityIndexDidUpdate")
}

/// The payload of a `.mediaItemDidMutate` notification: which items changed and
/// what about them changed. Screens use it to update the affected cards in place
/// — flipping a badge without rebuilding the rail — so the user's focus is never
/// yanked back to the top of the screen after a menu action.
///
/// A mutation can carry a watched-state change (`played`), a watchlist change
/// (`favorite`), a resume-progress change (`resumePosition` / `playedPercentage`),
/// or any combination; an absent (`nil`) field means "unchanged", so a screen only
/// touches the fields that actually changed.
///
/// **Why progress is here:** a partial watch (e.g. 4 minutes of a movie) is saved
/// to the server when the player stops, but the surface you return to holds an
/// in-memory ``MediaItem`` that still reflects the *old* progress until a full
/// reload. Carrying the new resume position + fraction lets the detail page and
/// row tiles update their progress bar in place, instantly, the same way the
/// watched badge already flips — no refetch, focus preserved.
public struct MediaItemMutation: Sendable, Equatable {
    public let itemIDs: Set<String>
    /// New watched/played state, or `nil` if this mutation doesn't change it.
    public let played: Bool?
    /// New watchlist/favourite state, or `nil` if this mutation doesn't change it.
    public let favorite: Bool?
    /// New saved resume position (seconds), or `nil` if unchanged. A value of `0`
    /// clears the resume point (title finished / start over) — surfaces drop the
    /// progress bar and the detail "Resume" affordance.
    public let resumePosition: TimeInterval?
    /// New fractional watched progress in `0...1`, or `nil` if unchanged. Drives the
    /// poster-card progress bar directly (`PosterCardView` reads `playedPercentage`).
    public let playedPercentage: Double?

    public init(
        itemIDs: Set<String>,
        played: Bool? = nil,
        favorite: Bool? = nil,
        resumePosition: TimeInterval? = nil,
        playedPercentage: Double? = nil
    ) {
        self.itemIDs = itemIDs
        self.played = played
        self.favorite = favorite
        self.resumePosition = resumePosition
        self.playedPercentage = playedPercentage
    }

    private enum Key {
        static let itemIDs = "itemIDs"
        static let played = "played"
        static let favorite = "favorite"
        static let resumePosition = "resumePosition"
        static let playedPercentage = "playedPercentage"
    }

    /// Whether this mutation targets `item`. Matches the item's own id **or any of
    /// its cross-server source item ids**: a merged card's primary is only one of
    /// several servers' ids for the title, and the mutation may have been built
    /// against a *different* server (e.g. the user finished the copy on server B,
    /// or the identity index was still cold when the stop mutation was assembled so
    /// its fanned-out `targets` didn't yet include this card's primary id). Because
    /// the loaded card already knows its full `sources` set, matching against those
    /// makes the in-place update robust regardless of how complete the mutation's
    /// own id set was.
    public func targets(_ item: MediaItem) -> Bool {
        itemIDs.contains(item.id) || item.sources.contains { itemIDs.contains($0.itemID) }
    }

    /// Applies this mutation to `item` in place, returning the updated copy. Only
    /// the fields the mutation actually carries are touched, so a screen can fold a
    /// mutation over every visible card without disturbing unrelated state. Items
    /// the mutation doesn't target are returned unchanged. A `resumePosition` of `0`
    /// is normalised to `nil` (no resume point) so finished/restarted titles drop
    /// their progress bar.
    public func applied(to item: MediaItem) -> MediaItem {
        guard targets(item) else { return item }
        var copy = item
        if let played { copy.isPlayed = played }
        if let favorite { copy.isFavorite = favorite }
        if let resumePosition { copy.resumePosition = resumePosition > 0 ? resumePosition : nil }
        if let playedPercentage { copy.playedPercentage = playedPercentage }
        return copy
    }

    /// Posts a `.mediaItemDidMutate` notification carrying this mutation.
    public func post() {
        var userInfo: [String: Any] = [Key.itemIDs: Array(itemIDs)]
        if let played { userInfo[Key.played] = played }
        if let favorite { userInfo[Key.favorite] = favorite }
        if let resumePosition { userInfo[Key.resumePosition] = resumePosition }
        if let playedPercentage { userInfo[Key.playedPercentage] = playedPercentage }
        NotificationCenter.default.post(
            name: .mediaItemDidMutate,
            object: nil,
            userInfo: userInfo
        )
    }

    /// Reconstructs the mutation from a received notification, or `nil` if the
    /// payload carries no item ids / no recognised change at all.
    public static func from(_ notification: Notification) -> MediaItemMutation? {
        guard let ids = notification.userInfo?[Key.itemIDs] as? [String] else { return nil }
        let played = notification.userInfo?[Key.played] as? Bool
        let favorite = notification.userInfo?[Key.favorite] as? Bool
        let resumePosition = notification.userInfo?[Key.resumePosition] as? TimeInterval
        let playedPercentage = notification.userInfo?[Key.playedPercentage] as? Double
        guard played != nil || favorite != nil || resumePosition != nil || playedPercentage != nil else {
            return nil
        }
        return MediaItemMutation(
            itemIDs: Set(ids),
            played: played,
            favorite: favorite,
            resumePosition: resumePosition,
            playedPercentage: playedPercentage
        )
    }
}
