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
    /// Every signed-in `Account.id`, so episode twin expansion knows which *other*
    /// servers to probe. Resolved live (main-actor) so a sign-in/out is reflected.
    var allAccountIDs: @Sendable () async -> [String] = { [] }
    /// The eager identity index's known **series** sources for an origin series —
    /// the shared source of truth for "which servers host this show", each carrying
    /// *that server's own* series item id. When the index already knows a twin
    /// series on a server we skip the per-server search and go straight to the
    /// children-walk for the final per-(season,episode) step, satisfying the SSOT
    /// rule "derive the episode on each known server as the last step; never
    /// re-resolve the series by id at drain time". Empty (cold index / unknown
    /// server) ⇒ that server falls back to the existing search probe, so a write is
    /// never dropped while the index warms.
    var indexedSeriesSources: @Sendable (MediaItem) -> [IndexedSource] = { _ in [] }
    /// Per-server bounded series search. Mirrors the cross-server detail resolver's
    /// `searchWithDeadline` so a slow/asleep server can't stall convergence.
    var searchDeadline: TimeInterval = 4

    func setPlayed(_ played: Bool, on target: WatchMutationTarget) async throws {
        guard let provider = await resolveProvider(target.accountID) else {
            FanoutDiagnostics.emit("write.setPlayed acct=\(target.accountID) item=\(target.itemID) -> provider=nil (unreachable/unresolved, will retry)")
            throw AppError.serverUnreachable
        }
        guard let watch = provider as? WatchStateProviding else {
            FanoutDiagnostics.emit("write.setPlayed acct=\(target.accountID) item=\(target.itemID) -> provider=\(provider.kind.rawValue) NOT WatchStateProviding (no write, treated success)")
            return
        }
        try await watch.setPlayed(played, itemID: target.itemID)
    }

    func setResumePosition(_ seconds: TimeInterval, on target: WatchMutationTarget) async throws {
        guard let provider = await resolveProvider(target.accountID) else {
            FanoutDiagnostics.emit("write.setResume acct=\(target.accountID) item=\(target.itemID) -> provider=nil (unreachable/unresolved, will retry)")
            throw AppError.serverUnreachable
        }
        guard let resumeWriter = provider as? ResumeStateWriting else {
            FanoutDiagnostics.emit("write.setResume acct=\(target.accountID) item=\(target.itemID) -> provider=\(provider.kind.rawValue) NOT ResumeStateWriting (no write, treated success)")
            return
        }
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

    /// Resolves the episode's cross-server twins: discovers the origin series'
    /// identity (origin episode → its series) and hands it to the pure
    /// ``EpisodeTwinResolver`` to find the same `(season, episode)` on every other
    /// signed-in server. Bounded and best-effort; the origin server being down is
    /// reported inconclusive so the reconciler retries rather than giving up.
    func expandTargets(for mutation: WatchMutation) async -> WatchTargetExpansion {
        guard let season = mutation.seasonNumber,
              let episode = mutation.episodeNumber,
              let origin = mutation.episodeOrigin
        else { return .none }

        // Which OTHER servers to probe. None ⇒ single-server household ⇒ no probing.
        let everyAccount = await allAccountIDs()
        let otherAccountIDs = everyAccount.filter { $0 != origin.accountID }
        guard !otherAccountIDs.isEmpty else { return .none }

        // Discover the origin series identity. Needs the origin server; if it can't
        // be reached, report it inconclusive so a later drain retries (we never
        // guess a series identity).
        guard let originProvider = await resolveProvider(origin.accountID) else {
            return WatchTargetExpansion(inconclusiveAccountIDs: [origin.accountID])
        }
        let originSeries: MediaItem
        do {
            let episodeItem = try await originProvider.item(id: origin.itemID)
            guard let seriesID = episodeItem.seriesID else { return .none }
            originSeries = try await originProvider.item(id: seriesID)
        } catch {
            return WatchTargetExpansion(inconclusiveAccountIDs: [origin.accountID])
        }

        // Resolve the other servers' providers up front so the pure resolver's
        // search/children closures can call them (and report provider kinds).
        var providers: [String: any MediaProvider] = [:]
        for accountID in otherAccountIDs {
            if let provider = await resolveProvider(accountID) {
                providers[accountID] = provider
            }
        }
        // An account whose provider can't be resolved (signed out / still resolving)
        // is inconclusive — retry it later rather than concluding it lacks the show.
        let unresolved = otherAccountIDs.filter { providers[$0] == nil }
        let resolvableAccountIDs = otherAccountIDs.filter { providers[$0] != nil }
        guard !resolvableAccountIDs.isEmpty else {
            return WatchTargetExpansion(inconclusiveAccountIDs: unresolved)
        }

        let deadline = searchDeadline
        // The SSOT's known series twins for this origin, keyed by account → that
        // server's own series item id. For these accounts the children-walk runs
        // directly on the known id (no drain-time series re-resolution / search);
        // unknown accounts fall back to the live search probe below.
        let knownSeriesByAccount: [String: String] = {
            var map: [String: String] = [:]
            for source in indexedSeriesSources(originSeries) where source.kind == .series {
                map[source.accountID] = source.itemID
            }
            return map
        }()
        // A synthetic series carrying the origin's identity so the resolver's
        // identity match succeeds without a network round-trip. The id is the
        // index's known server-local series id, so the children-walk addresses the
        // right show on that server.
        let originSeriesForSynthesis = originSeries
        let expansion = await EpisodeTwinResolver.resolve(
            originSeries: originSeries,
            seasonNumber: season,
            episodeNumber: episode,
            otherAccountIDs: resolvableAccountIDs,
            searchSeries: { accountID, query in
                if let knownID = knownSeriesByAccount[accountID] {
                    var synthetic = originSeriesForSynthesis
                    synthetic.id = knownID
                    synthetic.sourceAccountID = accountID
                    return [synthetic]
                }
                guard let provider = providers[accountID] else { return nil }
                return await Self.searchSeries(provider, query: query, seconds: deadline)
            },
            children: { accountID, containerID in
                guard let provider = providers[accountID] else { return nil }
                return try? await provider.children(of: containerID)
            },
            providerKind: { providers[$0]?.kind }
        )

        // Fold the unresolved accounts into the inconclusive set so they retry too.
        return WatchTargetExpansion(
            targets: expansion.targets,
            inconclusiveAccountIDs: expansion.inconclusiveAccountIDs + unresolved
        )
    }

    /// Bounded series search returning `nil` on timeout/failure (vs `[]` for a real
    /// empty result), so the resolver can tell "couldn't reach this server" from
    /// "this server doesn't have the show". A libdispatch timer cancels the search
    /// task so a saturated cooperative pool can't defeat the deadline.
    private static func searchSeries(_ provider: any MediaProvider, query: String, seconds: TimeInterval) async -> [MediaItem]? {
        let searchTask = Task { try await provider.search(query: query, limit: 25) }
        let timeout = DispatchWorkItem { searchTask.cancel() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds, execute: timeout)
        defer { timeout.cancel() }
        return try? await searchTask.value
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
