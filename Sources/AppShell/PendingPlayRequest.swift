import Observation

/// A Top Shelf deep link (`plozz://item/<id>`) waiting for the signed-in UI to
/// open it.
///
/// This exists as its own object purely so it can be passed **by reference**.
/// The obvious shape — a `String?` on `AppState`, threaded down as a
/// `Binding` — makes every view that stores the binding a subscriber of the
/// source, so each publish invalidates it whether or not the value moved.
/// Measured on the Apple TV: `HomeTab.body` re-evaluated 1,619 times in 50
/// seconds while the id stayed `nil` the entire time, rebuilding its
/// `NavigationStack` and every pushed destination on each pass, until the
/// watchdog terminated the app.
///
/// A stored `let` reference to this object is stable across `body` passes, so
/// intermediate views (`MainTabView`, `HomeTab`) can carry it without becoming
/// subscribers. Only the small leaf that reads ``itemID`` — the deep-link
/// router — is invalidated, and its body is empty.
@MainActor
@Observable
public final class PendingPlayRequest {
    /// The item id to open, or `nil` when there is nothing pending. Set when the
    /// app is launched/foregrounded from a Top Shelf card, cleared once the Home
    /// tab has routed to it.
    public var itemID: String?
    /// Which server the link said the title lives on, when it said.
    ///
    /// A bare id is unique only within one server — Plex ratingKeys are small
    /// per-server integers — so on a device signed in to several, resolving by id
    /// alone can open the wrong title. The link carries the account; this is where
    /// it survives until the router can use it.
    public var accountID: String?

    public init() {}
}
