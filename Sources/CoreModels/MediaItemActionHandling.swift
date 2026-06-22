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
    /// (e.g. watched / unwatched). Screens showing media observe it and reload
    /// so the change is reflected. `userInfo["itemID"]` carries the target id.
    static let mediaItemDidMutate = Notification.Name("PlozzMediaItemDidMutate")
}
