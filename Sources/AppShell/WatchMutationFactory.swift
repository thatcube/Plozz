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
    /// server's* own item id. One per cross-server source, or the primary owner for
    /// a single-source / untagged item. Providers are resolved live at drain time,
    /// so a momentarily-unreachable server is still recorded.
    static func targets(for item: MediaItem, primaryAccountID: String?) -> [WatchMutationTarget] {
        if !item.sources.isEmpty {
            var seen = Set<String>()
            return item.sources.compactMap { source in
                guard seen.insert(source.id).inserted else { return nil }
                return WatchMutationTarget(
                    accountID: source.accountID,
                    itemID: source.itemID,
                    providerKind: source.providerKind
                )
            }
        }
        guard let accountID = item.sourceAccountID ?? primaryAccountID else { return [] }
        return [WatchMutationTarget(accountID: accountID, itemID: item.id)]
    }

    private static func canonicalID(for item: MediaItem) -> String {
        WatchMutation.canonicalMediaID(
            providerIDs: item.providerIDs,
            title: item.title,
            year: item.productionYear,
            fallback: item.id
        )
    }

    private static func traktIntent(for item: MediaItem, progress: Double) -> TraktScrobbleIntent {
        TraktScrobbleIntent(
            kind: item.kind,
            title: item.title,
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

    /// A mark-watched / mark-unwatched mutation. Marking watched clears resume
    /// everywhere and mirrors to Trakt (write-if-missing); unwatch never touches
    /// Trakt (no deletes) and leaves resume alone.
    static func playedToggle(item: MediaItem, played: Bool, primaryAccountID: String?, capturedAt: Date = Date()) -> WatchMutation? {
        let targets = targets(for: item, primaryAccountID: primaryAccountID)
        guard !targets.isEmpty else { return nil }
        let expansion = episodeExpansion(for: item, primaryAccountID: primaryAccountID)
        return WatchMutation(
            capturedAt: capturedAt,
            canonicalMediaID: canonicalID(for: item),
            seasonNumber: item.seasonNumber,
            episodeNumber: item.episodeNumber,
            played: played,
            clearResume: played,
            targets: targets,
            trakt: played ? traktIntent(for: item, progress: 100) : nil,
            episodeOrigin: expansion.origin,
            expansionPending: expansion.pending
        )
    }

    /// The convergence mutation for leaving the player: at/above the finished
    /// threshold it marks the title played everywhere (clearing resume) and mirrors
    /// to Trakt; otherwise it writes the resume position to every server so a
    /// best-source switch resumes where you left off, on whichever server backs it.
    /// Returns `nil` when there is nothing worth converging (no targets, or an
    /// unfinished item barely started).
    static func playbackStop(item: MediaItem, position: TimeInterval, watchedPercent: Double, primaryAccountID: String?, capturedAt: Date = Date()) -> WatchMutation? {
        let targets = targets(for: item, primaryAccountID: primaryAccountID)
        guard !targets.isEmpty else { return nil }
        let expansion = episodeExpansion(for: item, primaryAccountID: primaryAccountID)

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
                episodeOrigin: expansion.origin,
                expansionPending: expansion.pending
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
            episodeOrigin: expansion.origin,
            expansionPending: expansion.pending
        )
    }
}
