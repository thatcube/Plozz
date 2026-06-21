import Foundation
import CoreModels

/// A titled group of search results (e.g. "Movies", "TV Shows", "Episodes"),
/// rendered as one section of the results grid.
public struct SearchSection: Identifiable, Equatable, Sendable {
    public var id: String { title }
    public let title: String
    public let items: [MediaItem]

    public init(title: String, items: [MediaItem]) {
        self.title = title
        self.items = items
    }

    /// Groups a flat result list into stably-ordered sections by kind, dropping
    /// empty groups. Order mirrors the search query's `IncludeItemTypes`
    /// (movies, then series, then episodes), with any other kinds last.
    public static func sections(from items: [MediaItem]) -> [SearchSection] {
        let groups: [(title: String, kinds: Set<MediaItemKind>)] = [
            ("Movies", [.movie]),
            ("TV Shows", [.series]),
            ("Episodes", [.episode]),
            ("Other", [.season, .video, .folder, .collection, .unknown])
        ]
        return groups.compactMap { group in
            let matching = items.filter { group.kinds.contains($0.kind) }
            return matching.isEmpty ? nil : SearchSection(title: group.title, items: matching)
        }
    }
}
