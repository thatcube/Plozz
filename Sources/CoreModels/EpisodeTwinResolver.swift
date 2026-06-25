import Foundation

/// The outcome of expanding an episode mutation's cross-server **twin targets**:
/// the confidently-resolved targets to converge now, plus the accounts that were
/// probed but couldn't be confirmed (offline / timed out / un-enumerable) and so
/// are worth retrying on a later drain.
///
/// Empty `targets` + empty `inconclusiveAccountIDs` is the **conclusive "no twins"**
/// result (single-server household, or other servers confidently don't host the
/// title) — it lets the reconciler stop owing expansion. A non-empty
/// `inconclusiveAccountIDs` keeps expansion pending so an asleep twin server still
/// converges once it comes back.
public struct WatchTargetExpansion: Sendable, Equatable {
    /// Twin targets resolved with confidence (exact series identity + exact S·E).
    public var targets: [WatchMutationTarget]
    /// Accounts probed but not conclusively resolved — retry later, never guessed.
    public var inconclusiveAccountIDs: [String]

    public init(targets: [WatchMutationTarget] = [], inconclusiveAccountIDs: [String] = []) {
        self.targets = targets
        self.inconclusiveAccountIDs = inconclusiveAccountIDs
    }

    /// Conclusive "nothing to expand" — no twin targets, nothing left to retry.
    public static let none = WatchTargetExpansion()

    /// Whether the probe was conclusive (nothing left to retry). When `true` the
    /// reconciler clears `expansionPending`.
    public var isConclusive: Bool { inconclusiveAccountIDs.isEmpty }
}

/// Resolves the **same episode** on every *other* server that hosts a series, so a
/// watch played from one server converges across the household — the per-episode
/// analogue of ``CrossServerSourceResolver`` (which only resolves movie/series
/// *titles*).
///
/// Episodes loaded inside a series come from one server at a time, so an episode's
/// ``MediaItem/sources`` is effectively single-server and a watch fanned out from
/// it reaches only its origin. This resolver closes that gap: given the origin
/// **series** identity and the episode's `(season, episode)` ordinal, it discovers
/// the series' twin on each other server (by shared strong external id) and walks
/// that server's seasons → episodes to find the matching episode's *own* id.
///
/// ## Confidence gating (never write a guessed episode id)
/// - **Series** twins match ONLY by a shared strong external id (imdb/tmdb/tvdb)
///   via ``MediaItemIdentity`` — series title identity is deliberately unavailable
///   (reboots/anime vs live-action share names), so this can't false-merge shows.
/// - **Episode** is chosen ONLY when *exactly one* episode under the matched
///   series has the exact `(seasonNumber, episodeNumber)`. Zero matches is a
///   confident "that server doesn't have this episode" (no target). Multiple
///   distinct candidate ids (ambiguous duplicate series/episodes) → skip THAT
///   server rather than guess.
/// - A server whose search or child enumeration *failed* (offline / timeout) is
///   reported **inconclusive** so the caller retries it instead of writing nothing
///   forever — and never instead of writing a wrong id.
public enum EpisodeTwinResolver {
    /// Resolve twin episode targets for `(seasonNumber, episodeNumber)` of the
    /// series described by `originSeries`, across `otherAccountIDs`.
    ///
    /// - Parameters:
    ///   - originSeries: the origin **series** item (its `providerIDs` / title drive
    ///     the cross-server match). Must be the series, not the episode.
    ///   - otherAccountIDs: every signed-in account *except* the origin — the
    ///     servers to probe for a twin. Empty ⇒ single-server ⇒ `.none`.
    ///   - searchSeries: free-text series search against an account. Returns `nil`
    ///     to signal the probe *failed* (so the account is reported inconclusive),
    ///     `[]` to signal a successful empty result.
    ///   - children: enumerates a container's children (series → seasons, season →
    ///     episodes) on an account. Returns `nil` on failure (inconclusive).
    ///   - providerKind: backend kind for an account, stamped onto resolved targets.
    public static func resolve(
        originSeries: MediaItem,
        seasonNumber: Int,
        episodeNumber: Int,
        otherAccountIDs: [String],
        searchSeries: @Sendable @escaping (_ accountID: String, _ query: String) async -> [MediaItem]?,
        children: @Sendable @escaping (_ accountID: String, _ containerID: String) async -> [MediaItem]?,
        providerKind: @Sendable @escaping (_ accountID: String) -> ProviderKind? = { _ in nil }
    ) async -> WatchTargetExpansion {
        let originIdentities = Set(MediaItemIdentity.identities(for: originSeries))
        let queries = CrossServerSourceResolver.searchQueries(for: originSeries)
        // Without a strong series identity we can never confidently match a twin —
        // give up conclusively rather than retry forever on a hopeless probe.
        guard !originIdentities.isEmpty, !queries.isEmpty, !otherAccountIDs.isEmpty else {
            return .none
        }

        let results: [(target: WatchMutationTarget?, inconclusive: String?)] =
            await withTaskGroup(of: (target: WatchMutationTarget?, inconclusive: String?).self) { group in
                for accountID in otherAccountIDs {
                    group.addTask {
                        await resolveAccount(
                            accountID: accountID,
                            originIdentities: originIdentities,
                            queries: queries,
                            seasonNumber: seasonNumber,
                            episodeNumber: episodeNumber,
                            searchSeries: searchSeries,
                            children: children,
                            providerKind: providerKind
                        )
                    }
                }
                var collected: [(target: WatchMutationTarget?, inconclusive: String?)] = []
                for await result in group { collected.append(result) }
                return collected
            }

        var targets: [WatchMutationTarget] = []
        var seen = Set<String>()
        var inconclusive: [String] = []
        for result in results {
            if let target = result.target, seen.insert(target.id).inserted {
                targets.append(target)
            }
            if let account = result.inconclusive {
                inconclusive.append(account)
            }
        }
        return WatchTargetExpansion(targets: targets, inconclusiveAccountIDs: inconclusive)
    }

    /// Resolves one account: search → identity-match the series → walk to the exact
    /// episode. Returns a target only when confidently resolved; reports the account
    /// id as inconclusive when a probe failed and nothing confident could be decided.
    private static func resolveAccount(
        accountID: String,
        originIdentities: Set<MediaIdentity>,
        queries: [String],
        seasonNumber: Int,
        episodeNumber: Int,
        searchSeries: @Sendable (_ accountID: String, _ query: String) async -> [MediaItem]?,
        children: @Sendable (_ accountID: String, _ containerID: String) async -> [MediaItem]?,
        providerKind: @Sendable (_ accountID: String) -> ProviderKind?
    ) async -> (target: WatchMutationTarget?, inconclusive: String?) {
        // 1) Search for the series on this server, matching by shared strong id.
        var anySearchSucceeded = false
        var matchedSeries: [MediaItem] = []
        var seenSeries = Set<String>()
        for query in queries {
            guard let hits = await searchSeries(accountID, query) else { continue }
            anySearchSucceeded = true
            for hit in hits where hit.kind == .series && seenSeries.insert(hit.id).inserted {
                if !originIdentities.isDisjoint(with: Set(MediaItemIdentity.identities(for: hit))) {
                    matchedSeries.append(hit)
                }
            }
        }
        // Every search failed: we can't tell if this server has it — retry later.
        guard anySearchSucceeded else { return (nil, accountID) }
        // Searched fine, no twin series here: confident no target, nothing to retry.
        guard !matchedSeries.isEmpty else { return (nil, nil) }

        // 2) Walk each matched series to the exact (season, episode).
        var episodeIDs = Set<String>()
        var enumerationFailed = false
        for series in matchedSeries {
            switch await episodeID(
                accountID: accountID,
                seriesID: series.id,
                seasonNumber: seasonNumber,
                episodeNumber: episodeNumber,
                children: children
            ) {
            case .failed:
                enumerationFailed = true
            case .resolved(let ids):
                episodeIDs.formUnion(ids)
            }
        }

        // Exactly one candidate ⇒ confident twin.
        if episodeIDs.count == 1, let only = episodeIDs.first {
            return (WatchMutationTarget(accountID: accountID, itemID: only, providerKind: providerKind(accountID)), nil)
        }
        // Ambiguous (multiple distinct ids) ⇒ skip rather than guess; conclusive.
        if episodeIDs.count > 1 {
            return (nil, nil)
        }
        // No candidate: inconclusive only if enumeration actually failed.
        return (nil, enumerationFailed ? accountID : nil)
    }

    private enum EpisodeLookup {
        case failed
        case resolved([String])
    }

    /// Walks `series → seasons → episodes` on one server to the ids of every
    /// episode whose `(seasonNumber, episodeNumber)` matches. `.failed` when a
    /// required child fetch failed (so the caller can mark it inconclusive).
    private static func episodeID(
        accountID: String,
        seriesID: String,
        seasonNumber: Int,
        episodeNumber: Int,
        children: @Sendable (_ accountID: String, _ containerID: String) async -> [MediaItem]?
    ) async -> EpisodeLookup {
        guard let topLevel = await children(accountID, seriesID) else { return .failed }

        // Some servers/queries surface episodes directly under the series; honor
        // those too so a flat enumeration still resolves.
        var matches = topLevel
            .filter { $0.kind == .episode && $0.seasonNumber == seasonNumber && $0.episodeNumber == episodeNumber }
            .map(\.id)

        let seasons = topLevel.filter { $0.kind == .season && $0.seasonNumber == seasonNumber }
        var anyFailure = false
        for season in seasons {
            guard let episodes = await children(accountID, season.id) else { anyFailure = true; continue }
            for episode in episodes
            where episode.kind == .episode && episode.seasonNumber == seasonNumber && episode.episodeNumber == episodeNumber {
                matches.append(episode.id)
            }
        }

        let unique = Array(Set(matches))
        if unique.isEmpty && anyFailure { return .failed }
        return .resolved(unique)
    }
}
