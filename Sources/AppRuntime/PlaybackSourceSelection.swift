import CoreModels

public enum PlaybackSourceSelection {
    public static func bestPlayItem(
        _ item: MediaItem,
        accounts: [ResolvedAccount],
        identitySources: (MediaItem) -> [MediaSourceRef]
    ) -> MediaItem {
        let activeAccountIDs = Set(accounts.map(\.account.id))
        let liveLocality: [String: SourceLocality] = Dictionary(
            accounts.map { ($0.account.id, $0.provider.connectionLocality) },
            uniquingKeysWith: { first, _ in first }
        )
        func withLiveLocality(_ source: MediaSourceRef) -> MediaSourceRef {
            guard let locality = liveLocality[source.accountID] else {
                return source
            }
            var copy = source
            copy.locality = locality
            return copy
        }

        var unioned = item.sources
        var seen = Set(unioned.map(\.id))
        for ref in identitySources(item) where seen.insert(ref.id).inserted {
            unioned.append(ref)
        }
        // Enforce the cross-kind boundary before anything can be selected. The
        // identity index matches on title/provider ids, so a show and its
        // episodes can resolve to each other's refs — and `selectingSource`
        // rewrites `id` while KEEPING `kind`, which is how an item ends up
        // labelled `episode` while carrying the series' ratingKey. Playback then
        // asks the provider for a container id and gets notFound (Plex) or a 500
        // (Jellyfin), surfacing as "Can't play this right now" for a title the
        // user owns. `MediaItemMerger` already applies this same filter; the
        // playback path has to as well, since it unions in fresh identity refs.
        unioned = MediaSourceRef.retainingKindCompatible(
            unioned,
            itemKind: item.kind,
            // The item's own physical identity, in the merger's `account:item`
            // ref-id form, so a legacy untyped self-ref is still trusted.
            selfIDs: Set([item.sourceAccountID.map { "\($0):\(item.id)" }].compactMap { $0 })
        )

        if let guidTail = item.providerIDs["PlexGuid"]?
            .split(separator: "/").last.map(String.init) {
            let playable = unioned.filter { $0.itemID != guidTail }
            if !playable.isEmpty {
                unioned = playable
            }
        }

        let liveSources = (
            activeAccountIDs.isEmpty
                ? unioned
                : unioned.filter {
                    activeAccountIDs.contains($0.accountID)
                }
        )
        .map(withLiveLocality)

        if item.explicitSourceSelection,
           let picked = item.selectedSourceAccountID,
           liveSources.contains(where: { $0.accountID == picked }) {
            return item
        }

        let primaryIsPlayable = liveSources.contains {
            $0.accountID == item.sourceAccountID && $0.itemID == item.id
        }
        if !primaryIsPlayable, !liveSources.isEmpty {
            let selection = CrossSourceSelector.bestSelection(
                from: liveSources,
                capabilities: .detected(),
                preferring: item.sourceAccountID
            )
            let target = selection?.source ?? liveSources[0]
            return MediaItem.retargetedForPlayback(
                item: item,
                sources: liveSources,
                activeAccountID: target.accountID,
                versionID: selection?.version?.id
            )
        }

        guard liveSources.count > 1,
              let selection = CrossSourceSelector.bestSelection(
                  from: liveSources,
                  capabilities: .detected(),
                  preferring: item.selectedSourceAccountID
                      ?? item.sourceAccountID
              ) else {
            if let only = liveSources.first,
               liveSources.count < unioned.count
                   || only.accountID != item.sourceAccountID {
                return MediaItem.retargetedForPlayback(
                    item: item,
                    sources: liveSources,
                    activeAccountID: only.accountID,
                    versionID: nil
                )
            }
            return item
        }

        return MediaItem.retargetedForPlayback(
            item: item,
            sources: liveSources,
            activeAccountID: selection.source.accountID,
            versionID: selection.version?.id
        )
    }
}
