import Foundation

/// A user-invokable action surfaced in an item's press-and-hold (context) menu.
///
/// Provider-agnostic and SwiftUI-free so the catalog that decides which actions
/// apply (`MediaItemActionCatalog`) is unit-testable on Linux/CI. The type is an
/// open enum: adding a future action is a single new `case` plus its `title` /
/// `systemImage`, with no change to the menu UI that renders it.
///
/// ## Future actions (researched, not yet implemented)
/// The menu is intentionally architected to grow. Likely next additions, all of
/// which fit this same shape (a label, an SF Symbol, and a handler that talks to
/// the owning provider), include:
///   * **Add to / Remove from Watchlist** — Plex has a first-class watchlist;
///     Jellyfin has none today, so this needs a provider capability much like
///     `WatchStateProviding` before it can be offered.
///   * **Mark as Favorite / Remove Favorite** — Jellyfin
///     `POST/DELETE /Users/{uid}/FavoriteItems/{id}`; Plex has no direct
///     equivalent.
///   * **Play from Beginning / Resume** and **Go to Series / Go to Season** —
///     navigation actions that need a router seam rather than a provider call.
///   * **Shuffle / Play Next / Add to Queue**, and admin-only **Refresh
///     Metadata** / **Delete** (destructive — see `isDestructive`).
public enum MediaItemAction: String, CaseIterable, Sendable, Identifiable {
    /// Mark this item (and, for a container, its children) watched.
    case markWatched
    /// Mark this item (and, for a container, its children) unwatched.
    case markUnwatched
    /// Mark every episode up to and including this one watched.
    case markWatchedUpToHere
    /// Navigate from this episode to its owning season's page. A pure navigation
    /// action (no provider mutation) handled by the view layer's router.
    case goToSeason
    /// Navigate from a movie card (Continue Watching, Recently Added, Search) to
    /// the movie's own detail page instead of playing it. A pure navigation
    /// action (no provider mutation) handled by the view layer's router.
    case goToMovie
    /// Add this item to the user's Watchlist (Jellyfin Favorites / Plex
    /// Watchlist). Offered only when the owning provider conforms to
    /// `WatchlistProviding`.
    case addToWatchlist
    /// Remove this item from the user's Watchlist. Offered only when the item is
    /// currently watchlisted and the provider conforms to `WatchlistProviding`.
    case removeFromWatchlist
    /// Ask the server to refresh this item's metadata/artwork. A background
    /// server task; offered only when the provider conforms to
    /// `MetadataRefreshing`.
    case refreshMetadata

    public var id: String { rawValue }

    /// The user-facing label shown in the native menu.
    public var title: String {
        switch self {
        case .markWatched: return "Mark as Watched"
        case .markUnwatched: return "Mark as Unwatched"
        case .markWatchedUpToHere: return "Mark Watched Up to Here"
        case .goToSeason: return "Go to Season"
        case .goToMovie: return "Go to Movie"
        case .addToWatchlist: return "Add to Watchlist"
        case .removeFromWatchlist: return "Remove from Watchlist"
        case .refreshMetadata: return "Refresh Metadata"
        }
    }

    /// The SF Symbol shown beside the label.
    public var systemImage: String {
        switch self {
        case .markWatched: return "checkmark.circle"
        case .markUnwatched: return "arrow.uturn.backward.circle"
        case .markWatchedUpToHere: return "checkmark.circle.fill"
        case .goToSeason: return "rectangle.stack"
        case .goToMovie: return "film"
        case .addToWatchlist: return "bookmark"
        case .removeFromWatchlist: return "bookmark.slash"
        case .refreshMetadata: return "arrow.clockwise"
        }
    }

    /// Whether this action navigates (handled by the view layer's router) rather
    /// than mutating state through the provider. Navigation actions are performed
    /// locally by the context menu, not the app-level action handler.
    public var isNavigation: Bool {
        switch self {
        case .goToSeason, .goToMovie: return true
        case .markWatched, .markUnwatched, .markWatchedUpToHere,
             .addToWatchlist, .removeFromWatchlist, .refreshMetadata: return false
        }
    }

    /// Whether the platform should style the action as destructive (red). No
    /// current watched-state action loses data irreversibly; this exists so a
    /// future `delete` action can opt in without reworking the menu.
    public var isDestructive: Bool { false }
}
