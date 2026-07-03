import Foundation

/// The kinds of content a Home **hero** carousel can source from (pure data
/// model). Ordered, per-profile-configurable, and additive: a new source is a
/// new case plus its curation branch, never a rewrite of the hero.
///
/// `.featured` is the **Seerr seam** — trending/popular content that may sit
/// *outside* the user's library. It yields nothing until a Seerr/Overseerr
/// provider is wired in (built in parallel), so including it in the default set
/// is harmless today and lights up automatically once that lands.
public enum HeroSourceKind: String, CaseIterable, Identifiable, Codable, Sendable {
    /// Trending/popular streaming content from Seerr (outside your library).
    /// Empty until the Seerr provider exists.
    case featured
    /// Your in-progress, resumable titles presented in a featured format.
    case continueWatching
    /// Random picks from your (chosen) libraries.
    case randomFromLibrary
    /// Titles you've saved to your watchlist.
    case watchlist

    public var id: String { rawValue }

    /// User-facing label for the Settings source picker.
    public var displayName: String {
        switch self {
        case .featured: return "Featured"
        case .continueWatching: return "Continue Watching"
        case .randomFromLibrary: return "Random from Library"
        case .watchlist: return "Watchlist"
        }
    }

    /// One-line explanation shown under the option in Settings.
    public var detail: String {
        switch self {
        case .featured: return "Trending titles available to stream (requires Seerr)."
        case .continueWatching: return "Pick up where you left off, front and centre."
        case .randomFromLibrary: return "A rotating spotlight on titles from your libraries."
        case .watchlist: return "Titles you've saved to watch later."
        }
    }

    /// SF Symbol shown next to the option in Settings.
    public var symbolName: String {
        switch self {
        case .featured: return "sparkles.tv"
        case .continueWatching: return "play.circle"
        case .randomFromLibrary: return "shuffle"
        case .watchlist: return "bookmark"
        }
    }

    /// Whether this source draws from local library content (as opposed to the
    /// external Seerr `.featured` feed). Used by the curator to know which
    /// sources depend on already-aggregated Home content vs. an injected fetch.
    public var isLibrarySourced: Bool {
        self != .featured
    }
}
