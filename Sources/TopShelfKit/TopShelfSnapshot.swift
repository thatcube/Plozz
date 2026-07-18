import Foundation

/// A lightweight, `Codable` snapshot of the rows Plozz wants to surface in the
/// tvOS Top Shelf. The main app writes this into the shared App Group
/// container; the Top Shelf extension (a separate process) reads it back.
///
/// Keeping this intentionally small and dependency-free means the same two
/// source files (`TopShelfSnapshot` + `TopShelfStore`) can be compiled into
/// both the app (via the `TopShelfKit` package) and the extension (by source
/// path) without dragging the Jellyfin client / UI stack into the extension's
/// tight memory budget. Jellyfin image URLs are token-free, so the extension
/// can render them directly from the snapshot with no auth.
public struct TopShelfSnapshot: Codable, Equatable, Sendable {
    /// When the snapshot was produced. Used purely for debugging/freshness.
    public var generatedAt: Date

    /// Ordered list of carousels to render in the Top Shelf.
    public var sections: [Section]

    public struct Section: Codable, Equatable, Identifiable, Sendable {
        /// Stable identifier for the section (e.g. "continue", "latest").
        public var id: String
        /// User-facing carousel title (e.g. "Continue Watching").
        public var title: String
        public var items: [Item]

        public init(id: String, title: String, items: [Item]) {
            self.id = id
            self.title = title
            self.items = items
        }
    }

    public struct Item: Codable, Equatable, Identifiable, Sendable {
        /// Stable identifier — the Jellyfin item id, used for the play deep link.
        public var id: String
        public var title: String
        public var subtitle: String?
        /// Poster artwork (2:3) shown on the shelf card, falling back to backdrop.
        public var imageURL: URL?
        /// Fraction watched (0…1). Drives the resume progress bar drawn on the
        /// card; `nil`/`0` means no bar.
        public var playbackProgress: Double?

        public init(
            id: String,
            title: String,
            subtitle: String? = nil,
            imageURL: URL? = nil,
            playbackProgress: Double? = nil
        ) {
            self.id = id
            self.title = title
            self.subtitle = subtitle
            self.imageURL = imageURL
            self.playbackProgress = playbackProgress
        }
    }

    public init(generatedAt: Date = Date(), sections: [Section]) {
        self.generatedAt = generatedAt
        self.sections = sections
    }
}
