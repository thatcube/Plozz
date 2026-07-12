import Foundation
import CoreModels

/// Builds durable ``WatchMutation`` values from a ``MediaItem`` so the action
/// coordinator (mark watched/unwatched) and the player (resume / finish fan-out)
/// produce identical, cross-server-correct intents. Centralised so the target
/// derivation and Trakt-mirror policy live in exactly one place.
enum WatchMutationFactory {
    /// Considered "finished" at or above this watched percentage — finishing marks
    /// the title played everywhere, clears resume, and mirrors to Trakt.
    static let finishedThreshold: Double = 90

    /// Every server target this title should converge on, addressed by *that
    /// server's* own item id. The **origin** (where the user actually watched it)
    /// is always present, plus the item's own `sources` and any `additionalSources`
    /// the eager identity index knows for the title.
    ///
    /// `additionalSources` are the eager identity index's known servers for the
    /// title (the shared source of truth). They're unioned with the origin and the
    /// item's own `sources` so the fan-out is **origin-agnostic and N-account
    /// complete** even when the item was reached from a Home row that only one
    /// server populated.
    ///
    /// The origin is unioned **unconditionally** (not merely as an empty-result
    /// fallback): a partial / cold index can know the title on a *different* account
    /// than the one played, and dropping the origin there would skip the resume /
    /// played write on the very server the user watched on. Dedup keeps it to one
    /// entry when the origin is already among the sources.
    static func targets(
        for item: MediaItem,
        primaryAccountID: String?,
        additionalSources: [MediaSourceRef] = [],
        crossServerSync: Bool = true
    ) -> [WatchMutationTarget] {
        var seen = Set<String>()
        var result: [WatchMutationTarget] = []
        func append(accountID: String, itemID: String, providerKind: ProviderKind?) {
            guard seen.insert("\(accountID):\(itemID)").inserted else { return }
            result.append(WatchMutationTarget(
                accountID: accountID,
                itemID: itemID,
                providerKind: providerKind
            ))
        }
        // Origin first and always: you watched it there, so it must converge
        // regardless of how warm (or which-account-warm) the index is. Because
        // dedup is first-wins, resolve the origin's providerKind UP FRONT from the
        // item's own sources ∪ the warm identity snapshot, so the origin entry
        // carries its known kind instead of nil — otherwise the later enriched
        // source for the same accountID+itemID would be dedup-dropped and the
        // provider-kind metadata lost. Stays nil only when genuinely unknown
        // (cold index / origin absent from every source).
        if let originAccountID = item.sourceAccountID ?? primaryAccountID {
            let originKind = (item.sources + additionalSources)
                .first { $0.accountID == originAccountID && $0.itemID == item.id }?
                .providerKind
            append(accountID: originAccountID, itemID: item.id, providerKind: originKind)
        }
        // Cross-server sync OFF: scope the write to the origin server only. We
        // still resolved the origin's providerKind above (that's origin metadata,
        // not a fan-out target), but we skip unioning the item's own peer sources
        // and the identity-index union so no other server is touched.
        guard crossServerSync else { return result }
        // Episodes deliberately ignore pre-merged peers here. Some providers expose
        // show-level IDs on episodes, so a stale identity snapshot can contain a
        // different episode from the same series. The episode expansion resolver
        // below is the authoritative cross-server path: series identity followed by
        // exact season+episode lookup. The origin above is always retained.
        if item.kind != .episode {
            item.sources.forEach { append(accountID: $0.accountID, itemID: $0.itemID, providerKind: $0.providerKind) }
            additionalSources.forEach { append(accountID: $0.accountID, itemID: $0.itemID, providerKind: $0.providerKind) }
        }
        return result
    }

    private static func canonicalID(for item: MediaItem) -> String {
        // For episodes the title fallback (used only when no strong external id is
        // present) must key on the SERIES title, not the episode title: generic
        // episode titles like "Pilot" / "Episode 1" collide across unrelated shows,
        // which would coalesce two different series' S1E1 into one outbox entry and
        // cross-apply watched state. The season/episode numbers on the coalesce key
        // then disambiguate within the series. Fall back to the episode title only
        // when the parent series title is unavailable. Passing `kind` lets
        // `canonicalMediaID` scope the fallback to what the merger actually unites
        // (movies-by-title only with a year; episodes by series-title+s/e; nothing
        // for whole series / no-year movies) — see r8-canonicalid.
        let canonicalTitle = (item.kind == .episode ? item.parentTitle : nil) ?? item.title
        return WatchMutation.canonicalMediaID(
            providerIDs: item.providerIDs,
            title: canonicalTitle,
            year: item.productionYear,
            kind: item.kind,
            fallback: item.id
        )
    }

    private static func traktIntent(for item: MediaItem, progress: Double) -> TraktScrobbleIntent {
        TraktScrobbleIntent(
            kind: item.kind,
            title: item.title,
            seriesTitle: item.parentTitle,
            year: item.productionYear,
            seasonNumber: item.seasonNumber,
            episodeNumber: item.episodeNumber,
            providerIDs: item.providerIDs,
            progress: progress
        )
    }

    /// The origin episode seed + expansion flag for an episode item, so the
    /// reconciler can fan a watch out to the same episode on every other server
    /// hosting the series. Movies (or items missing a season/episode) get no seed
    /// and never trigger cross-server probing — single-target convergence is
    /// unchanged.
    private static func episodeExpansion(
        for item: MediaItem,
        primaryAccountID: String?
    ) -> (origin: EpisodeOrigin?, pending: Bool) {
        guard item.kind == .episode, item.seasonNumber != nil, item.episodeNumber != nil,
              let accountID = item.sourceAccountID ?? primaryAccountID
        else { return (nil, false) }
        return (EpisodeOrigin(accountID: accountID, itemID: item.id), true)
    }

    /// The persisted identity set + expansion flag + split-guard anchor for a
    /// **non-episode** title (movie or whole series), so the reconciler can fan its
    /// watch out to every server the eager identity index knows for the title —
    /// including servers that hadn't finished indexing when the user stopped —
    /// **without** cross-marking a different movie a server mis-tagged with the same
    /// external id (the anchor title/year splits that apart at drain time). Empty /
    /// not-pending for episodes (they use ``episodeExpansion``) and for items with
    /// no strong identity (nothing to index-match), so single-server convergence is
    /// unchanged. The anchor is only meaningful for movies (the split-guard is
    /// movies-only); it's carried for any non-episode title and left inert otherwise.
    private static func identityExpansion(
        for item: MediaItem
    ) -> (identities: [MediaIdentity], pending: Bool, anchorTitle: String?, anchorYear: Int?) {
        guard item.kind != .episode else { return ([], false, nil, nil) }
        let identities = MediaItemIdentity.identities(for: item)
        let normalized = MediaItemIdentity.normalizedTitle(item.title)
        return (identities, !identities.isEmpty, normalized.isEmpty ? nil : normalized, item.productionYear)
    }

    /// A mark-watched / mark-unwatched mutation. Marking watched clears resume
    /// everywhere and mirrors to Trakt (write-if-missing); unwatch never touches
    /// Trakt (no deletes) and leaves resume alone.
    static func playedToggle(item: MediaItem, played: Bool, primaryAccountID: String?, additionalSources: [MediaSourceRef] = [], crossServerSync: Bool = true, capturedAt: Date = Date()) -> WatchMutation? {
        let targets = targets(for: item, primaryAccountID: primaryAccountID, additionalSources: additionalSources, crossServerSync: crossServerSync)
        guard !targets.isEmpty else { return nil }
        // OFF: suppress ALL cross-server expansion seeds too — not just the extra
        // targets. Leaving episodeOrigin/identities/expansionPending populated
        // would let the reconciler re-expand at drain time and silently undo the
        // opt-out, so the origin-only write must carry no expansion intent.
        let episode = crossServerSync ? episodeExpansion(for: item, primaryAccountID: primaryAccountID) : (origin: nil, pending: false)
        let identity = crossServerSync ? identityExpansion(for: item) : (identities: [], pending: false, anchorTitle: nil, anchorYear: nil)
        return WatchMutation(
            capturedAt: capturedAt,
            canonicalMediaID: canonicalID(for: item),
            seasonNumber: item.seasonNumber,
            episodeNumber: item.episodeNumber,
            played: played,
            clearResume: played,
            targets: targets,
            trakt: played ? traktIntent(for: item, progress: 100) : nil,
            episodeOrigin: episode.origin,
            expansionPending: episode.pending || identity.pending,
            identities: identity.identities,
            kind: item.kind,
            anchorTitle: identity.anchorTitle,
            anchorYear: identity.anchorYear
        )
    }

    /// The convergence mutation for leaving the player: at/above the finished
    /// threshold it marks the title played everywhere (clearing resume) and mirrors
    /// to Trakt; otherwise it writes the resume position to every server so a
    /// best-source switch resumes where you left off, on whichever server backs it.
    /// Returns `nil` when there is nothing worth converging (no targets, or an
    /// unfinished item barely started).
    static func playbackStop(item: MediaItem, position: TimeInterval, watchedPercent: Double, primaryAccountID: String?, additionalSources: [MediaSourceRef] = [], crossServerSync: Bool = true, capturedAt: Date = Date()) -> WatchMutation? {
        let targets = targets(for: item, primaryAccountID: primaryAccountID, additionalSources: additionalSources, crossServerSync: crossServerSync)
        guard !targets.isEmpty else { return nil }
        // OFF: origin-only convergence with no expansion seeds (see `playedToggle`).
        let episode = crossServerSync ? episodeExpansion(for: item, primaryAccountID: primaryAccountID) : (origin: nil, pending: false)
        let identity = crossServerSync ? identityExpansion(for: item) : (identities: [], pending: false, anchorTitle: nil, anchorYear: nil)

        if watchedPercent >= finishedThreshold {
            return WatchMutation(
                capturedAt: capturedAt,
                canonicalMediaID: canonicalID(for: item),
                seasonNumber: item.seasonNumber,
                episodeNumber: item.episodeNumber,
                played: true,
                clearResume: true,
                targets: targets,
                trakt: traktIntent(for: item, progress: 100),
                episodeOrigin: episode.origin,
                expansionPending: episode.pending || identity.pending,
                identities: identity.identities,
                kind: item.kind,
                anchorTitle: identity.anchorTitle,
                anchorYear: identity.anchorYear
            )
        }

        // Not finished: only worth recording a real, resumable position.
        guard position > 1 else { return nil }
        return WatchMutation(
            capturedAt: capturedAt,
            canonicalMediaID: canonicalID(for: item),
            seasonNumber: item.seasonNumber,
            episodeNumber: item.episodeNumber,
            resumePosition: position,
            targets: targets,
            episodeOrigin: episode.origin,
            expansionPending: episode.pending || identity.pending,
            identities: identity.identities,
            kind: item.kind,
            anchorTitle: identity.anchorTitle,
            anchorYear: identity.anchorYear
        )
    }
}
