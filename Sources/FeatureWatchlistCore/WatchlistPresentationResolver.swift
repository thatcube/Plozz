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
    /// - Parameters:
    ///   - indexedSources: the identity index, used only for entries with no live
    ///     candidate. The candidates a caller can offer are whatever other Home rows
    ///     happen to hold — Continue Watching, Recently Added, a provider's own
    ///     watchlist. A film sitting in the library that the viewer watchlisted in
    ///     Plozz appears in none of those, so it fell through to the offline
    ///     presentation below and rendered as "not in your library" despite being
    ///     right there. The index knows the whole library, so it can answer.
    ///
    ///     This is a publish path, not a card path: it runs once per watchlist
    ///     rebuild, over entries with no candidate only. A card body must never call
    ///     it (`tools/arch-guard.py` enforces that).
    public static func resolve(
        union: WatchlistUnion,
        aliasSnapshot: MediaAliasSnapshot,
        currentItemsByAliasID: [MediaAliasID: MediaItem],
        indexedSources: ((MediaItem) -> [MediaSourceRef])? = nil,
        capabilities: MediaCapabilities? = nil
    ) -> [WatchlistPresentationEntry] {
        union.orderedEntries.compactMap { entry in
            let aliasID = entry.aliasID
            if let item = currentItemsByAliasID[aliasID] {
                // A live candidate is not automatically a LIBRARY candidate. The
                // watchlist row's own items are Plex Discover copies, which say
                // "not in your library" by construction — so returning the match
                // as-is made a film that is sitting in the library render as
                // something to go and request. Retargeting was only ever tried on
                // the placeholder path below, which this match skipped.
                //
                // `retargetedToOwnedLibraryCopy` returns nil for an ordinary
                // library item (it is already pointed at its own server) and
                // refuses to act without a strong external id, so this can only
                // ever upgrade a discovery row to a copy the index vouched for.
                // `retargetedToOwnedLibraryCopy` only considers an item whose
                // `availability` says it is a discovery row — and a Plex
                // watchlist entry carries NO availability at all, so every one
                // of them failed that gate and was handed back as the Discover
                // copy it arrived as. Saying "unknown" is what the placeholder
                // branch below already does, and it is the honest value: no live
                // copy has been vouched for yet. The retarget itself still
                // refuses to act without a strong external id, so this widens
                // what gets ASKED, never what gets matched.
                var candidate = item
                if !candidate.locallyValidatedPlayableSource,
                   candidate.availability == nil {
                    candidate.availability = .unknown
                }
                // The server's own answer wins, and needs nothing else to be
                // ready. The index can only answer once a full catalogue scan
                // has completed and published; this came back with the
                // watchlist itself, so a title the viewer owns is recognised as
                // owned from the first paint rather than after a scan lands.
                if let owned = entry.ownedSource,
                   !candidate.locallyValidatedPlayableSource {
                    var resolved = candidate.selectingSource(owned)
                    resolved.availability = nil
                    resolved.watchlistAliasID = aliasID
                    return WatchlistPresentationEntry(
                        aliasID: aliasID,
                        item: resolved
                    )
                }
                // Falls back to the MARKED candidate, not the original. A Plex
                // watchlist entry is a Discover row carrying no availability at
                // all, and with none the UI reads it as an ordinary library
                // title: it offered no way to request the title, and opening it
                // asked the server for the children of an id the server has
                // never heard of — a page with no play button, no episodes and
                // nothing to do. Saying "unknown" is the honest answer when no
                // owned copy was found, and it is what makes the not-in-library
                // treatment apply.
                var item = indexedSources.flatMap {
                    candidate.retargetedToOwnedLibraryCopy(
                        indexedSources: $0,
                        capabilities: capabilities
                    )
                } ?? candidate
                item.watchlistAliasID = aliasID
                return WatchlistPresentationEntry(aliasID: aliasID, item: item)
            }
            let record = aliasSnapshot.record(for: aliasID)
            let presentation = record?.presentation ?? entry.presentation
            guard let presentation else { return nil }
            // Carry the record's own external ids onto the placeholder. Without them
            // nothing downstream can recognise the title — not the index, not a
            // detail page — so it could only ever stay a dead card.
            var providerIDs: [String: String] = [:]
            for evidence in record?.strongEvidence ?? [] where evidence.kind == entry.kind {
                providerIDs[evidence.namespace.canonicalKey] = evidence.value
            }
            let placeholder = MediaItem(
                id: aliasID.description,
                title: presentation.title,
                kind: entry.kind,
                watchlistAliasID: aliasID,
                productionYear: presentation.year,
                posterURL: presentation.artworkURL.flatMap(URL.init(string:)),
                backdropURL: presentation.backdropURL.flatMap(URL.init(string:)),
                providerIDs: providerIDs,
                // Honest until proven otherwise: no live copy has been offered for
                // this entry. `retargetedToOwnedLibraryCopy` requires this marker,
                // and it is also what makes the badge correct if the search below
                // finds nothing.
                availability: .unknown,
                locallyValidatedPlayableSource: false
            )
            let resolved = indexedSources.flatMap {
                placeholder.retargetedToOwnedLibraryCopy(
                    indexedSources: $0,
                    capabilities: capabilities
                )
            }
            // Same precedence for an entry with no live candidate: the server's
            // answer first, the index only as a fallback.
            var item = entry.ownedSource.map {
                var owned = placeholder.selectingSource($0)
                owned.availability = nil
                return owned
            } ?? resolved ?? placeholder
            item.watchlistAliasID = aliasID
            return WatchlistPresentationEntry(aliasID: aliasID, item: item)
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
            if result[aliasID]?.locallyValidatedPlayableSource == true,
               !item.locallyValidatedPlayableSource {
                continue
            }
            result[aliasID] = item
        }
        return result
    }
}
