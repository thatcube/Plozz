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
}

/// The payload of a `.mediaItemDidMutate` notification: which items changed and
/// what about them changed. Screens use it to update the affected cards in place
/// — flipping a badge without rebuilding the rail — so the user's focus is never
/// yanked back to the top of the screen after a menu action.
///
/// A mutation can carry a watched-state change (`played`), a watchlist change
/// (`favorite`), or both; an absent (`nil`) field means "unchanged", so a screen
/// only touches the fields that actually changed.
public struct MediaItemMutation: Sendable, Equatable {
    public let itemIDs: Set<String>
    /// New watched/played state, or `nil` if this mutation doesn't change it.
    public let played: Bool?
    /// New watchlist/favourite state, or `nil` if this mutation doesn't change it.
    public let favorite: Bool?

    public init(itemIDs: Set<String>, played: Bool? = nil, favorite: Bool? = nil) {
        self.itemIDs = itemIDs
        self.played = played
        self.favorite = favorite
    }

    private enum Key {
        static let itemIDs = "itemIDs"
        static let played = "played"
        static let favorite = "favorite"
    }

    /// Posts a `.mediaItemDidMutate` notification carrying this mutation.
    public func post() {
        var userInfo: [String: Any] = [Key.itemIDs: Array(itemIDs)]
        if let played { userInfo[Key.played] = played }
        if let favorite { userInfo[Key.favorite] = favorite }
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
        guard played != nil || favorite != nil else { return nil }
        return MediaItemMutation(itemIDs: Set(ids), played: played, favorite: favorite)
    }
}
