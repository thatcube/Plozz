import Foundation

/// Optional capability a `MediaProvider` adopts to let the user add an item to —
/// or remove it from — a personal **Watchlist**.
///
/// Detected at runtime via `provider as? WatchlistProviding`, exactly like
/// `WatchStateProviding`, so the base `MediaProvider` contract stays unchanged
/// and providers (or test doubles) that can't express a watchlist simply don't
/// conform — the UI then hides the action.
///
/// **One concept, per-provider backing.** Jellyfin has no native "watchlist" but
/// does have **Favorites**, which is the natural, server-synced home for a
/// save-for-later list (`POST/DELETE /Users/{uid}/FavoriteItems/{id}`); Plex has
/// a first-class account **Watchlist**. Both are presented to the user as one
/// "Watchlist", so a title saved on either server shows up the same way.
public protocol WatchlistProviding: Sendable {
    /// Adds (`true`) or removes (`false`) `item` from the watchlist on this
    /// provider's backend. Takes the whole `MediaItem` (not just an id) because
    /// some backends — notably Plex's account watchlist — key off external/global
    /// identifiers carried on the item rather than the local item id.
    func setWatchlisted(_ on: Bool, item: MediaItem) async throws

    /// The current watchlist for this provider, as playable/browsable items.
    /// Empty when nothing is saved. A provider whose watchlist can't be mapped
    /// back to locally-playable items may return an empty list while still
    /// supporting `setWatchlisted` (see the Plex implementation's notes).
    func watchlist() async throws -> [MediaItem]
}
