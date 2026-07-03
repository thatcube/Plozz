import Foundation

/// Injected source of **featured** hero content — the seam the parallel Seerr
/// (Overseerr/Jellyseerr) work plugs into.
///
/// Returns trending/popular titles that may live *outside* the user's library.
/// The app injects a concrete implementation once a Seerr provider exists; until
/// then `HeroFeaturedProvider.none` (returning `[]`) is used, so the `.featured`
/// hero source is inert but present — no call site changes when Seerr lands.
///
/// Kept provider-agnostic (a closure over `MediaItem`) so nothing above the
/// provider layer needs to know Seerr exists.
public typealias FeaturedContentProviding = @Sendable (_ limit: Int) async -> [MediaItem]

/// Injected source of **random** hero picks drawn from the given library keys
/// (`AggregatedLibrary.key`). `libraryKeys` empty means "all visible libraries".
/// Implemented over `MediaProvider.items(in:kind:page:)` with `SortField.random`
/// so it works for both Jellyfin and Plex.
public typealias RandomLibraryContentProviding = @Sendable (_ libraryKeys: Set<String>, _ limit: Int) async -> [MediaItem]

/// Namespaced defaults for the hero content seams, so call sites can wire an
/// inert default without inventing an empty closure inline.
public enum HeroFeaturedProvider {
    /// The no-op featured provider used until Seerr is integrated.
    public static let none: FeaturedContentProviding = { _ in [] }
}

public enum HeroRandomProvider {
    /// The no-op random provider (e.g. previews/tests with no accounts).
    public static let none: RandomLibraryContentProviding = { _, _ in [] }
}
