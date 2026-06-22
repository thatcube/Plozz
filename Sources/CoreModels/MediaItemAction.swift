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

    public var id: String { rawValue }

    /// The user-facing label shown in the native menu.
    public var title: String {
        switch self {
        case .markWatched: return "Mark as Watched"
        case .markUnwatched: return "Mark as Unwatched"
        case .markWatchedUpToHere: return "Mark Watched Up to Here"
        }
    }

    /// The SF Symbol shown beside the label.
    public var systemImage: String {
        switch self {
        case .markWatched: return "checkmark.circle"
        case .markUnwatched: return "arrow.uturn.backward.circle"
        case .markWatchedUpToHere: return "checkmark.circle.fill"
        }
    }

    /// Whether the platform should style the action as destructive (red). No
    /// current watched-state action loses data irreversibly; this exists so a
    /// future `delete` action can opt in without reworking the menu.
    public var isDestructive: Bool { false }
}
