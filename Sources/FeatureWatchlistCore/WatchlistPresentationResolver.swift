import CoreModels
import Foundation

public struct WatchlistPresentationEntry: Identifiable, Sendable, Equatable {
    public let id: MediaAliasID
    public let item: MediaItem

    public init(aliasID: MediaAliasID, item: MediaItem) {
        id = aliasID
        self.item = item
    }
}

public enum WatchlistPresentationResolver {
    /// Replaces offline presentation values with current items without changing
    /// alias identity or stable watchlist order.
    public static func resolve(
        snapshot: WatchlistSnapshot,
        aliasSnapshot: MediaAliasSnapshot,
        currentItemsByAliasID: [MediaAliasID: MediaItem]
    ) -> [WatchlistPresentationEntry] {
        snapshot.orderedEntries.compactMap { intent in
            let aliasID = snapshot.resolvedAliasID(for: intent.aliasID)
            if let item = currentItemsByAliasID[aliasID] {
                var item = item
                item.watchlistAliasID = aliasID
                return WatchlistPresentationEntry(aliasID: aliasID, item: item)
            }
            let presentation = aliasSnapshot.record(for: aliasID)?.presentation
                ?? intent.presentation
            guard let presentation else { return nil }
            return WatchlistPresentationEntry(
                aliasID: aliasID,
                item: MediaItem(
                    id: aliasID.description,
                    title: presentation.title,
                    kind: intent.kind,
                    watchlistAliasID: aliasID,
                    productionYear: presentation.year,
                    posterURL: presentation.artworkURL.flatMap(URL.init(string:)),
                    backdropURL: presentation.backdropURL.flatMap(URL.init(string:))
                )
            )
        }
    }

    public static func indexCurrentItems(
        _ items: [MediaItem],
        in aliasSnapshot: MediaAliasSnapshot
    ) -> [MediaAliasID: MediaItem] {
        var result: [MediaAliasID: MediaItem] = [:]
        for item in items {
            guard let evidence = MediaAliasEvidence(item: item) else { continue }
            let aliases = evidence.strong.reduce(into: Set<MediaAliasID>()) {
                $0.formUnion(aliasSnapshot.aliases(for: $1))
            }
            let candidates = aliases.isEmpty
                ? evidence.weak.map { aliasSnapshot.aliases(for: $0) } ?? []
                : aliases
            guard candidates.count == 1, let aliasID = candidates.first else { continue }
            result[aliasID] = item
        }
        return result
    }
}
