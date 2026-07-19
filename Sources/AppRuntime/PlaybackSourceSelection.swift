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
