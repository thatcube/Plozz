import Foundation
import CoreModels

/// Concrete ``WatchMutationApplying`` for either app: resolves an `accountID` to its
/// live `MediaProvider` (on the main actor) and performs the played / resume write,
/// and mirrors finished watches through injected tracker closures.
///
/// Capability rules:
///  - **Unresolved provider** (signed out / still resolving) → throw, so the outbox
///    keeps the write queued and retries when the account is back.
///  - **Resolved but missing the capability** (a provider that can't express the
///    state) → return success, since retrying could never succeed (no silent loss —
///    there is genuinely nothing to write).
public struct AppShellWatchMutationApplier: WatchMutationApplying {
    /// Fences a reconciler to the profile it was created for. A superseded
    /// profile's in-flight drain must keep its mutations queued, never write
    /// through services/providers now scoped to another profile.
    private let isActive: @Sendable () async -> Bool
    /// Main-actor provider resolution (account id → live provider).
    private let resolveProvider: @Sendable (String) async -> (any MediaProvider)?
    private let applyTrakt: @Sendable (TraktScrobbleIntent) async throws -> Void
    private let applySimkl: @Sendable (TraktScrobbleIntent) async throws -> Void
    private let applyAniList: @Sendable (TraktScrobbleIntent) async throws -> Void
    private let applyMAL: @Sendable (TraktScrobbleIntent) async throws -> Void
    /// The **active** `Account.id`s (the set the identity index warms and that
    /// Home/Search fan out over), so episode twin expansion knows which *other*
    /// servers to probe and identity expansion can conclude once they're all
    /// indexed. Resolved live (main-actor) so a sign-in/out or profile switch is
    /// reflected. Deliberately NOT every signed-in account: an inactive account is
    /// never indexed, so including it would keep expansion perpetually inconclusive
    /// and make episode expansion probe servers outside the active profile.
    private let allAccountIDs: @Sendable () async -> [String]
    /// The eager identity index's known **series** sources for an origin series —
    /// the shared source of truth for "which servers host this show", each carrying
    /// *that server's own* series item id. When the index already knows a twin
    /// series on a server we skip the per-server search and go straight to the
    /// children-walk for the final per-(season,episode) step, satisfying the SSOT
    /// rule "derive the episode on each known server as the last step; never
    /// re-resolve the series by id at drain time". Empty (cold index / unknown
    /// server) ⇒ that server falls back to the existing search probe, so a write is
    /// never dropped while the index warms.
    private let indexedSeriesSources: @Sendable (MediaItem) -> [IndexedSource]
    /// The eager identity index's full known sources for a set of ``MediaIdentity``
    /// — the SSOT cross-server set used to fan a **movie / series** watch out to
    /// every server as the index warms. Read live off the published snapshot so a
    /// queued mutation re-resolves against ever-more-complete data on each drain.
    /// Empty (cold index / no match) ⇒ no extra targets that pass, so a watch is
    /// never dropped while the index warms. The trailing `(anchorTitle, anchorYear)`
    /// split the union apart when a server mis-tagged a *different* movie with the
    /// same external id (so a Scream 7 watch never fans out to a mis-tagged
    /// Scream 6); `nil` anchor ⇒ prior unguarded union.
    private let indexedSources: @Sendable ([MediaIdentity], MediaItemKind?, String?, Int?) -> [IndexedSource]
    /// Every `Account.id` the identity index has indexed at least once. A movie /
    /// series identity expansion is **conclusive** only once every active account
    /// appears here (the union can still grow until then), so a mutation stopped
    /// mid-warm stays queued and picks up the rest on later drains.
    private let indexedAccountIDs: @Sendable () -> Set<String>
    /// Safety cap on identity-expansion retries so a permanently-unreachable
    /// (never-indexing) account can't keep a mutation queued forever: once a
    /// mutation has been drained this many times, its identity expansion is treated
    /// as conclusive with whatever the index currently knows. Deliberately
    /// generous: a normal multi-account warm concludes via the *all-indexed*
    /// success path within its warm window (a handful of drains), so this budget
    /// only trips for a mutation that has survived many natural drains (warm
    /// cycles / foregrounds / replays across launches) without the index ever
    /// covering every active account — i.e. a genuinely dead destination.
    private let maxIdentityExpansionAttempts: Int
    /// Per-server bounded series search. Mirrors the cross-server detail resolver's
    /// `searchWithDeadline` so a slow/asleep server can't stall convergence.
    private let searchDeadline: TimeInterval

    public init(
        isActive: @escaping @Sendable () async -> Bool = { true },
        resolveProvider: @escaping @Sendable (String) async -> (any MediaProvider)?,
        applyTrakt: @escaping @Sendable (TraktScrobbleIntent) async throws -> Void,
        applySimkl: @escaping @Sendable (TraktScrobbleIntent) async throws -> Void,
        applyAniList: @escaping @Sendable (TraktScrobbleIntent) async throws -> Void,
        applyMAL: @escaping @Sendable (TraktScrobbleIntent) async throws -> Void,
        allAccountIDs: @escaping @Sendable () async -> [String] = { [] },
        indexedSeriesSources: @escaping @Sendable (MediaItem) -> [IndexedSource] = { _ in [] },
        indexedSources: @escaping @Sendable ([MediaIdentity], MediaItemKind?, String?, Int?) -> [IndexedSource] = { _, _, _, _ in [] },
        indexedAccountIDs: @escaping @Sendable () -> Set<String> = { [] },
        maxIdentityExpansionAttempts: Int = 12,
        searchDeadline: TimeInterval = 4
    ) {
        self.isActive = isActive
        self.resolveProvider = resolveProvider
        self.applyTrakt = applyTrakt
        self.applySimkl = applySimkl
        self.applyAniList = applyAniList
        self.applyMAL = applyMAL
        self.allAccountIDs = allAccountIDs
        self.indexedSeriesSources = indexedSeriesSources
        self.indexedSources = indexedSources
        self.indexedAccountIDs = indexedAccountIDs
        self.maxIdentityExpansionAttempts = maxIdentityExpansionAttempts
        self.searchDeadline = searchDeadline
    }

    public func setPlayed(_ played: Bool, on target: WatchMutationTarget) async throws {
        try await setPlayed(played, on: target, capturedAt: Date())
    }

    public func setPlayed(_ played: Bool, on target: WatchMutationTarget, capturedAt: Date) async throws {
        guard await isActive() else { throw AppError.serverUnreachable }
        guard let provider = await resolveProvider(target.accountID) else {
            FanoutDiagnostics.emit("write.setPlayed acct=\(target.accountID) item=\(target.itemID) -> provider=nil (unreachable/unresolved, will retry)")
            throw AppError.serverUnreachable
        }
        guard await isActive() else { throw AppError.serverUnreachable }
        // A locally-stored played state (the SMB share) is ordered last-writer-wins
        // by the play's real time, so prefer the timestamped write — otherwise a
        // late-draining stale played write, stamped at drain time, would clobber a
        // newer resume. A server-backed provider (Plex/Jellyfin) owns recency and
        // uses the plain write.
        if let timestamped = provider as? PlayedStateWriting {
            try await timestamped.setPlayed(played, itemID: target.itemID, capturedAt: capturedAt)
            return
        }
        guard let watch = provider as? WatchStateProviding else {
            FanoutDiagnostics.emit("write.setPlayed acct=\(target.accountID) item=\(target.itemID) -> provider=\(provider.kind.rawValue) NOT WatchStateProviding (no write, treated success)")
            return
        }
        try await watch.setPlayed(played, itemID: target.itemID)
    }

    public func setResumePosition(_ seconds: TimeInterval, on target: WatchMutationTarget, capturedAt: Date) async throws {
        guard await isActive() else { throw AppError.serverUnreachable }
        guard let provider = await resolveProvider(target.accountID) else {
            FanoutDiagnostics.emit("write.setResume acct=\(target.accountID) item=\(target.itemID) -> provider=nil (unreachable/unresolved, will retry)")
            throw AppError.serverUnreachable
        }
        guard await isActive() else { throw AppError.serverUnreachable }
        guard let resumeWriter = provider as? ResumeStateWriting else {
            FanoutDiagnostics.emit("write.setResume acct=\(target.accountID) item=\(target.itemID) -> provider=\(provider.kind.rawValue) NOT ResumeStateWriting (no write, treated success)")
            return
        }
        try await resumeWriter.setResumePosition(seconds, itemID: target.itemID, capturedAt: capturedAt)
    }

    public func scrobbleTrakt(_ intent: TraktScrobbleIntent) async throws {
        guard await isActive() else { throw AppError.serverUnreachable }
        try await applyTrakt(intent)
    }

    public func scrobbleSimkl(_ intent: TraktScrobbleIntent) async throws {
        guard await isActive() else { throw AppError.serverUnreachable }
        try await applySimkl(intent)
    }

    public func scrobbleAniList(_ intent: TraktScrobbleIntent) async throws {
        guard await isActive() else { throw AppError.serverUnreachable }
        try await applyAniList(intent)
    }

    public func scrobbleMAL(_ intent: TraktScrobbleIntent) async throws {
        guard await isActive() else { throw AppError.serverUnreachable }
        try await applyMAL(intent)
    }

    /// Resolves the cross-server twins for a queued mutation. Branches on the
    /// mutation shape: an **episode** (carries `episodeOrigin`) is resolved by
    /// walking each other server's matching series → episode; a **movie / series**
    /// (carries `identities`) is resolved by unioning the eager identity index's
    /// known servers for those identities. Both are best-effort and confidence-/
    /// warmth-gated via ``WatchTargetExpansion/inconclusiveAccountIDs`` so the
    /// reconciler retries rather than dropping or guessing.
    public func expandTargets(for mutation: WatchMutation) async -> WatchTargetExpansion {
        guard await isActive() else {
            return WatchTargetExpansion(
                targets: [],
                inconclusiveAccountIDs: ["inactive-profile"]
            )
        }
        let expansion: WatchTargetExpansion
        if mutation.episodeOrigin != nil {
            expansion = await expandEpisodeTargets(for: mutation)
        } else {
            expansion = await expandIdentityTargets(for: mutation)
        }
        guard await isActive() else {
            return WatchTargetExpansion(
                targets: [],
                inconclusiveAccountIDs: ["inactive-profile"]
            )
        }
        return expansion
    }

    /// Fans a **movie / series** watch out to every server the eager identity index
    /// knows for the title's ``MediaIdentity`` set. Because the index warms
    /// progressively at launch, the union grows over successive drains; the
    /// expansion is reported **inconclusive** for every active account not yet
    /// indexed so the mutation stays queued and re-resolves as the index warms
    /// (drains are kicked after each warm publish). Bounded by
    /// ``maxIdentityExpansionAttempts`` so a never-indexing account can't keep it
    /// pending forever. Never throws — an unwarmed server is inconclusive, not an
    /// error, and the origin target is written regardless.
    private func expandIdentityTargets(for mutation: WatchMutation) async -> WatchTargetExpansion {
        guard !mutation.identities.isEmpty else { return .none }
        // TMDb/TVDb reuse one integer id space across movies and series
        // (movie 550 ≠ tv 550), so the union must be scoped to the played title's
        // kind — otherwise a movie's watched-write could fan out to a *series* on
        // another server that merely shares the id (and vice-versa). The index does
        // the kind-scoping (and the transitive connected-component walk) internally
        // when a kind is supplied. Legacy mutations (nil kind, enqueued before this
        // field existed) get the prior unscoped single-level union so a queued write
        // is never dropped.
        let scopedSources = indexedSources(mutation.identities, mutation.kind, mutation.anchorTitle, mutation.anchorYear)
        let targets = scopedSources.map(\.target)
        let everyAccount = Set(await allAccountIDs())
        // Conclusive only once every active account has been indexed at least once
        // (the union can still grow until then), unless we've exhausted the attempt
        // budget so a never-indexing account can't keep the mutation queued forever.
        let indexed = indexedAccountIDs()
        let notYetIndexed = everyAccount.subtracting(indexed)
        let exhausted = mutation.attempts >= maxIdentityExpansionAttempts
        let inconclusive = exhausted ? [] : Array(notYetIndexed)
        return WatchTargetExpansion(targets: targets, inconclusiveAccountIDs: inconclusive)
    }

    /// Resolves the episode's cross-server twins: discovers the origin series'
    /// identity (origin episode → its series) and hands it to the pure
    /// ``EpisodeTwinResolver`` to find the same `(season, episode)` on every other
    /// signed-in server. Bounded and best-effort; the origin server being down is
    /// reported inconclusive so the reconciler retries rather than giving up.
    private func expandEpisodeTargets(for mutation: WatchMutation) async -> WatchTargetExpansion {
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
        let resolvedProviders = providers
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
                guard let provider = resolvedProviders[accountID] else { return nil }
                return await Self.searchSeries(provider, query: query, seconds: deadline)
            },
            children: { accountID, containerID in
                guard let provider = resolvedProviders[accountID] else { return nil }
                return try? await provider.children(of: containerID)
            },
            providerKind: { resolvedProviders[$0]?.kind }
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
    public func makeScrobbleItem() -> MediaItem {
        MediaItem(
            id: "trakt-intent",
            title: title ?? "",
            kind: kind,
            parentTitle: seriesTitle,
            seasonNumber: seasonNumber,
            episodeNumber: episodeNumber,
            productionYear: year,
            providerIDs: providerIDs
        )
    }
}
