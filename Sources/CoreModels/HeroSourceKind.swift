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
    public var displayName: LocalizedStringResource {
        switch self {
        case .featured:
            return LocalizedStringResource(
                "heroSource.featured",
                defaultValue: "Featured",
                comment: "Home hero content-source option in Settings."
            )
        case .continueWatching:
            return LocalizedStringResource(
                "heroSource.continueWatching",
                defaultValue: "Continue Watching",
                comment: "Home hero content-source option in Settings."
            )
        case .randomFromLibrary:
            return LocalizedStringResource(
                "heroSource.randomFromLibrary",
                defaultValue: "Random from Library",
                comment: "Home hero content-source option in Settings."
            )
        case .watchlist:
            return LocalizedStringResource(
                "heroSource.watchlist",
                defaultValue: "Watchlist",
                comment: "Home hero content-source option in Settings."
            )
        }
    }

    /// One-line explanation shown under the option in Settings.
    public var detail: LocalizedStringResource {
        switch self {
        case .featured:
            return LocalizedStringResource(
                "Trending titles available to stream (requires Seerr).",
                comment: "Explanation shown under the Featured hero source option in Settings."
            )
        case .continueWatching:
            return LocalizedStringResource(
                "Pick up where you left off, front and centre.",
                comment: "Explanation shown under the Continue Watching hero source option in Settings."
            )
        case .randomFromLibrary:
            return LocalizedStringResource(
                "A rotating spotlight on titles from your libraries.",
                comment: "Explanation shown under the Random from Library hero source option in Settings."
            )
        case .watchlist:
            return LocalizedStringResource(
                "Titles you've saved to watch later.",
                comment: "Explanation shown under the Watchlist hero source option in Settings."
            )
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
