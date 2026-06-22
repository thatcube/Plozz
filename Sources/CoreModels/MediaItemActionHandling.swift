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
/// their new watched state. Screens use it to update the affected cards in place
/// — flipping a badge without rebuilding the rail — so the user's focus is never
/// yanked back to the top of the screen after a menu action.
public struct MediaItemMutation: Sendable, Equatable {
    public let itemIDs: Set<String>
    public let played: Bool

    public init(itemIDs: Set<String>, played: Bool) {
        self.itemIDs = itemIDs
        self.played = played
    }

    private enum Key {
        static let itemIDs = "itemIDs"
        static let played = "played"
    }

    /// Posts a `.mediaItemDidMutate` notification carrying this mutation.
    public func post() {
        NotificationCenter.default.post(
            name: .mediaItemDidMutate,
            object: nil,
            userInfo: [Key.itemIDs: Array(itemIDs), Key.played: played]
        )
    }

    /// Reconstructs the mutation from a received notification, or `nil` if the
    /// payload is absent/malformed.
    public static func from(_ notification: Notification) -> MediaItemMutation? {
        guard
            let ids = notification.userInfo?[Key.itemIDs] as? [String],
            let played = notification.userInfo?[Key.played] as? Bool
        else { return nil }
        return MediaItemMutation(itemIDs: Set(ids), played: played)
    }
}
