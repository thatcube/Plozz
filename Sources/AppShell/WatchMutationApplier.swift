import Foundation
import CoreModels
import TraktService

/// Concrete ``WatchMutationApplying`` for the app: resolves an `accountID` to its
/// live `MediaProvider` (on the main actor) and performs the played / resume write,
/// and mirrors finished watches to Trakt via the shared scrobbler.
///
/// Capability rules:
///  - **Unresolved provider** (signed out / still resolving) → throw, so the outbox
///    keeps the write queued and retries when the account is back.
///  - **Resolved but missing the capability** (a provider that can't express the
///    state) → return success, since retrying could never succeed (no silent loss —
///    there is genuinely nothing to write).
struct AppShellWatchMutationApplier: WatchMutationApplying {
    /// Main-actor provider resolution (account id → live provider).
    let resolveProvider: @Sendable (String) async -> (any MediaProvider)?
    /// The active Trakt scrobbler (durable, throwing variant used).
    let traktScrobbler: @Sendable () async -> any TraktScrobbling

    func setPlayed(_ played: Bool, on target: WatchMutationTarget) async throws {
        guard let provider = await resolveProvider(target.accountID) else {
            throw AppError.serverUnreachable
        }
        guard let watch = provider as? WatchStateProviding else { return }
        try await watch.setPlayed(played, itemID: target.itemID)
    }

    func setResumePosition(_ seconds: TimeInterval, on target: WatchMutationTarget) async throws {
        guard let provider = await resolveProvider(target.accountID) else {
            throw AppError.serverUnreachable
        }
        guard let resumeWriter = provider as? ResumeStateWriting else { return }
        try await resumeWriter.setResumePosition(seconds, itemID: target.itemID)
    }

    func scrobbleTrakt(_ intent: TraktScrobbleIntent) async throws {
        let scrobbler = await traktScrobbler()
        try await scrobbler.scrobbleResult(
            item: intent.makeScrobbleItem(),
            progress: intent.progress,
            event: .stop
        )
    }
}

extension TraktScrobbleIntent {
    /// Rebuilds a minimal `MediaItem` carrying just the fields a Trakt scrobble body
    /// needs (kind, ids, season/episode, title/year), so the durable intent can be
    /// replayed without retaining the original item.
    func makeScrobbleItem() -> MediaItem {
        MediaItem(
            id: "trakt-intent",
            title: title ?? "",
            kind: kind,
            seasonNumber: seasonNumber,
            episodeNumber: episodeNumber,
            productionYear: year,
            providerIDs: providerIDs
        )
    }
}
