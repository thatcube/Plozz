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
        /// Poster artwork (2:3) for the shelf card. Usually a remote Jellyfin
        /// poster URL, but for a mid-playback Continue-Watching item it's a
        /// **local file URL** in the shared App Group container pointing at a
        /// poster with the resume bar composited in (see `TopShelfPosterComposer`).
        public var imageURL: URL?
        /// Fraction watched (0…1), recorded for reference. The bar itself is
        /// burned into `imageURL` (posters can't show the native Top Shelf bar),
        /// so the extension doesn't read this — it renders the artwork as-is.
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
