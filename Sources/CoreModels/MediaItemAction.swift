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
    /// Navigate from this episode up to its show. A pure navigation action (no
    /// provider mutation) handled by the view layer's router.
    ///
    /// Labelled "Go to Show" because that's where it actually lands: the SERIES
    /// detail page with this episode's season pre-selected (see
    /// ``MediaItem/seasonNavigationTarget``). Only when the series id is unknown
    /// does it fall back to a bare season page. The case keeps its original name
    /// so persisted raw values stay valid.
    case goToSeason
    /// Navigate from a movie card (Continue Watching, Recently Added, Search) to
    /// the movie's own detail page instead of playing it. A pure navigation
    /// action (no provider mutation) handled by the view layer's router.
    case goToMovie
    /// Navigate to this episode's own detail page — its synopsis, air date, and
    /// the technical facts of the file that would play.
    ///
    /// The series page shows one episode at a time (whatever Play would run), and
    /// episode cards stay deliberately sparse, so this is the only place to
    /// inspect a *different* episode's file before playing it. A pure navigation
    /// action handled by the view layer's router.
    case goToEpisode
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
    /// Start an offline download of this item. Offered only when the surface
    /// supplies download capability (iOS/iPadOS today) and nothing is downloaded
    /// or in flight for the item's SELECTED version.
    case startDownload
    /// Pause an in-flight download (queued or transferring).
    case pauseDownload
    /// Resume a paused or failed download.
    case resumeDownload
    /// Delete the on-device copy. Destructive: the bytes are gone and must be
    /// re-fetched over the network.
    case removeDownload

    public var id: String { rawValue }

    /// The user-facing label shown in the native menu.
    public var title: String {
        switch self {
        case .markWatched: return "Mark as Watched"
        case .markUnwatched: return "Mark as Unwatched"
        case .markWatchedUpToHere: return "Mark Watched Up to Here"
        case .goToSeason: return "Go to Show"
        case .goToMovie: return "Go to Movie"
        case .goToEpisode: return "Episode Info"
        case .addToWatchlist: return "Add to Watchlist"
        case .removeFromWatchlist: return "Remove from Watchlist"
        case .refreshMetadata: return "Refresh Metadata"
        case .startDownload: return "Download"
        case .pauseDownload: return "Pause Download"
        case .resumeDownload: return "Resume Download"
        case .removeDownload: return "Remove Download"
        }
    }

    /// The SF Symbol shown beside the label.
    public var systemImage: String {
        switch self {
        case .markWatched: return "checkmark.circle"
        case .markUnwatched: return "arrow.uturn.backward.circle"
        case .markWatchedUpToHere: return "checkmark.circle.fill"
        case .goToSeason: return "tv"
        case .goToMovie: return "film"
        case .goToEpisode: return "info.circle"
        case .addToWatchlist: return "bookmark"
        case .removeFromWatchlist: return "bookmark.slash"
        case .refreshMetadata: return "arrow.clockwise"
        case .startDownload: return "arrow.down.circle"
        case .pauseDownload: return "pause.circle"
        case .resumeDownload: return "arrow.clockwise.circle"
        case .removeDownload: return "trash"
        }
    }

    /// Whether this action navigates (handled by the view layer's router) rather
    /// than mutating state through the provider. Navigation actions are performed
    /// locally by the context menu, not the app-level action handler.
    public var isNavigation: Bool {
        switch self {
        case .goToSeason, .goToMovie, .goToEpisode: return true
        case .markWatched, .markUnwatched, .markWatchedUpToHere,
             .addToWatchlist, .removeFromWatchlist, .refreshMetadata,
             .startDownload, .pauseDownload, .resumeDownload, .removeDownload:
            return false
        }
    }

    /// Whether the action navigates to the item it was offered for. These are
    /// redundant on that item's own detail page (you are already there), unlike
    /// `goToSeason`, which leaves for the parent show.
    public var navigatesToSelf: Bool {
        switch self {
        case .goToEpisode, .goToMovie: return true
        case .goToSeason, .markWatched, .markUnwatched, .markWatchedUpToHere,
             .addToWatchlist, .removeFromWatchlist, .refreshMetadata,
             .startDownload, .pauseDownload, .resumeDownload, .removeDownload:
            return false
        }
    }

    /// Whether the platform should style the action as destructive (red). No
    /// current watched-state action loses data irreversibly; this exists so a
    /// future `delete` action can opt in without reworking the menu.
    public var isDestructive: Bool { self == .removeDownload }

    /// Whether this action is served by the download stack rather than a provider.
    /// The coordinator routes these to an injected download service instead of
    /// attempting a provider mutation.
    public var isDownload: Bool {
        switch self {
        case .startDownload, .pauseDownload, .resumeDownload, .removeDownload:
            return true
        default:
            return false
        }
    }

    /// Actions intentionally promoted into a detail hero's visible More menu.
    /// Navigation and server-maintenance actions remain in the context menu.
    public var isPrimaryDetailAction: Bool {
        switch self {
        case .markWatched, .markUnwatched,
             .addToWatchlist, .removeFromWatchlist:
            return true
        case .markWatchedUpToHere, .goToSeason, .goToMovie, .goToEpisode,
             .refreshMetadata, .startDownload, .pauseDownload,
             .resumeDownload, .removeDownload:
            return false
        }
    }
}
