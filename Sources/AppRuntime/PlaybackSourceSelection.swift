import Foundation
import CoreModels

public enum PlaybackSourceSelection {
    /// Permanent, opt-in tracing of every playback routing decision
    /// (`PLOZZ_TRACE_SOURCE=1`).
    ///
    /// Not scaffolding. Cross-server routing depends on the identity index, live
    /// locality and the merge all agreeing, and when the wrong server plays there
    /// is nothing on screen to say why — the app just streams from somewhere
    /// unexpected. Diagnosing that without this means a rebuild and a redeploy
    /// before the first question can even be asked.
    private static let tracesRouting =
        ProcessInfo.processInfo.environment["PLOZZ_TRACE_SOURCE"] == "1"

    private static func trace(_ message: @autoclosure () -> String) {
        guard tracesRouting else { return }
        print("PLZSRC " + message())
    }

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
            trace("  KEPT explicit pick acct=\(picked.prefix(10))")
            return item
        }

        let primaryIsPlayable = liveSources.contains {
            $0.accountID == item.sourceAccountID && $0.itemID == item.id
        }
        // Rank whenever there is a real choice — not only when the item's own
        // server is unplayable.
        //
        // Short-circuiting on "the origin works" silently defeated the closest-
        // server guarantee for every row play. A Continue Watching card carries
        // whichever server's resume state won the merge, which for a shared title
        // can be a remote/Tailscale Jellyfin; because that source was perfectly
        // playable, the local Plex copy was never even considered. Reported as
        // "it plays my sister's server instead of mine".
        //
        // Ranking is safe here precisely because the selector already encodes the
        // intended policy: locality first, with the item's own account passed as
        // `preferring` — a SOFT tie-break that only decides between otherwise-
        // equal candidates. An explicit user pick has already returned above, so
        // this can never override a deliberate choice.
        let hasCrossServerChoice = Set(liveSources.map(\.accountID)).count > 1
        if tracesRouting {
            let describe: (MediaSourceRef) -> String = { source in
                let kind = source.providerKind.map(String.init(describing:)) ?? "?"
                let locality = source.locality.map(String.init(describing:)) ?? "nil"
                return "[\(kind) acct=\(source.accountID.prefix(10)) item=\(source.itemID) loc=\(locality)]"
            }
            trace(
                "route \(item.title) id=\(item.id) kind=\(item.kind) origin=\(item.sourceAccountID ?? "nil") "
                    + "own=\(item.sources.count) identity=\(identitySources(item).count) live=\(liveSources.count) "
                    + "ids=\(item.providerIDs.keys.sorted().joined(separator: ",")) "
                    + "primaryPlayable=\(primaryIsPlayable) crossChoice=\(hasCrossServerChoice)"
            )
            trace("  live: \(liveSources.map(describe).joined(separator: " "))")
        }
        if !liveSources.isEmpty, !primaryIsPlayable || hasCrossServerChoice {
            let selection = CrossSourceSelector.bestSelection(
                from: liveSources,
                capabilities: .detected(),
                preferring: item.sourceAccountID
            )
            let target = selection?.source ?? liveSources[0]
            trace("  CHOSE acct=\(target.accountID.prefix(10)) item=\(target.itemID)")
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
            trace("  UNCHANGED — nothing better to route to")
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
