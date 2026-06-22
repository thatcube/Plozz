import Foundation

/// Optional capability a `MediaProvider` adopts to let the user toggle an item's
/// played / "watched" state on the server.
///
/// Detected at runtime via `provider as? WatchStateProviding`, mirroring how
/// music support is detected via `as? MusicProvider`. This keeps the base
/// `MediaProvider` contract unchanged — providers (and test doubles) that can't
/// mutate watched state simply don't conform, and the UI hides the action.
///
/// **Why this writes through the backend (and never fakes a local flag):** the
/// media server is the single source of truth for watched state. Writing to it
/// means any server-side sync the user has configured — e.g. the Jellyfin or
/// Plex **Trakt** plugin — picks the change up automatically, and every other
/// client sees it too.
public protocol WatchStateProviding: Sendable {
    /// Marks `itemID` played (`true`) or unplayed (`false`) on the server.
    ///
    /// For a container item (a season or series id) the backend cascades the
    /// change to its children, so a whole season can be marked watched with one
    /// call where the provider supports it.
    func setPlayed(_ played: Bool, itemID: String) async throws
}
