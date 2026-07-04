import Foundation

/// One horizontal row within a single library's unmerged Home section — e.g.
/// "Recently Added in Movies", "Continue Watching in TV", or a Plex discovery hub
/// like "More in Drama" / "Because you watched…".
///
/// Provider-agnostic and SwiftUI-free so it can be produced by any `MediaProvider`
/// (Plex maps its native `/hubs/sections/{id}` hubs onto these; the Home
/// aggregator synthesises the uniform base rows for every provider from the
/// existing scoped feeds). The Home view renders each as a normal media row.
public struct LibrarySection: Identifiable, Equatable, Sendable {
    /// The poster aspect the row renders with. Mirrors the Home feature's own
    /// row style but stays in `CoreModels` so the provider layer can pick a style
    /// without importing the UI layer.
    public enum Style: String, Equatable, Sendable {
        /// Portrait posters — movies, series, most discovery hubs.
        case poster
        /// Wide landscape stills — resume/continue-watching rows.
        case landscape
    }

    /// Stable, unique-within-a-library identity for the row. Global rows use a
    /// fixed token (e.g. `"recentlyAdded"`), Plex hubs use their `hubIdentifier`.
    /// The Home view composes this with the owning library key to form a
    /// screen-unique SwiftUI id, so two libraries can both have a "recentlyAdded"
    /// row without colliding.
    public let id: String

    /// The row heading shown above the cards (already localised/humanised by the
    /// producer — e.g. "Recently Added", "More in Drama").
    public let title: String

    /// Poster vs landscape presentation.
    public let style: Style

    /// The cards to render. Never empty for a section the aggregator keeps — empty
    /// sections are dropped upstream so the view never renders a headed-but-blank
    /// row.
    public var items: [MediaItem]

    public init(id: String, title: String, style: Style = .poster, items: [MediaItem] = []) {
        self.id = id
        self.title = title
        self.style = style
        self.items = items
    }
}
