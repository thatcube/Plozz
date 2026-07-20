#if canImport(SwiftUI)
import SwiftUI
import AppRuntime
import CoreModels
import CoreUI
import FeatureHome
import FeatureHomeCore
import FeatureMusic
import FeaturePlayback
import MediaTransportCore
import MetadataKit
import FeatureSearch
import FeatureSettings
import FeatureProfiles
import ProviderTrailers
import RatingsService
import TraktService
import SeerService
import SimklService
import AniListService
import MALService
import LastFmService

extension View {
    /// Applies the native tvOS 18 `TabView` presentation matching the user's
    /// `NavigationStyle`. Kept as a `@ViewBuilder` switch (rather than a ternary)
    /// because `.sidebarAdaptable` and `.tabBarOnly` are distinct concrete
    /// `TabViewStyle` types that can't share one expression.
    @ViewBuilder
    func plozzTabStyle(_ style: NavigationStyle) -> some View {
        switch style {
        case .tabBar: self.tabViewStyle(.tabBarOnly)
        case .sidebar: self.tabViewStyle(.sidebarAdaptable)
        }
    }
}

/// Resolves the provider that owns `accountID`, falling back to the primary
/// (first) account. `accounts` is guaranteed non-empty by the caller
/// (`RootView`).
///
/// The fallback is legitimate only for a **nil** `accountID` (a genuinely
/// untagged item — e.g. a route with no owning server — plays from the primary
/// account). A **non-nil but unmatched** `accountID` is different: it means the
/// caller handed an explicit source whose account is no longer signed in, and
/// silently playing it from `accounts[0]` is the "random / wrong server" symptom
/// — you'd stream a *different server's* copy than the one selected. The play
/// paths prune to live accounts first (`bestSourcePlayItem`) so this shouldn't
/// be reached in practice; when it is, emit a (gated) diagnostic so the stale
/// pick is observable on device rather than masquerading as a successful play.
func resolveProvider(_ accountID: String?, in accounts: [ResolvedAccount]) -> any MediaProvider {
    if let accountID {
        if let match = accounts.first(where: { $0.account.id == accountID }) {
            return match.provider
        }
        FanoutDiagnostics.emit("resolveProvider fallback: explicit account \(accountID) not signed in; using primary \(accounts[0].account.id)")
    }
    return accounts[0].provider
}

/// Resolves a specific account id to its provider, or `nil` when that account is
/// no longer signed in. Used by the detail page to fetch a merged title's
/// *alternate* servers' versions/watch-state for the server picker — a missing
/// account simply drops that source rather than falling back to another server.
func resolveOptionalProvider(_ accountID: String, in accounts: [ResolvedAccount]) -> (any MediaProvider)? {
    accounts.first(where: { $0.account.id == accountID })?.provider
}

/// Builds the Home hero's **featured** provider from the Seerr service: trending
/// titles (movies + TV) that may live outside the user's library. Returns `[]`
/// when Seerr is unconfigured or the fetch fails, so the `.featured` hero source
/// stays inert until a server is connected — exactly the seam `HeroCurator`
/// expects.
func makeHeroFeaturedProvider(
    seer: SeerService,
    accounts: [ResolvedAccount],
    hideWatched: Bool,
    identitySources: @escaping @Sendable (MediaItem) -> [MediaSourceRef]
) -> FeaturedContentProviding {
    let fetchWatchState = makeHeroWatchStateFetcher(accounts: accounts)
    return { limit in
        let candidateLimit = HeroCandidatePool.requestLimit(
            finalLimit: limit,
            hideWatched: hideWatched
        )
        let items = (try? await seer.trending(limit: candidateLimit)) ?? []
        return await HeroCandidateWatchStateEnricher.enrich(
            items,
            enabled: hideWatched,
            sourceRefs: identitySources,
            fetch: fetchWatchState
        )
    }
}

func makeHeroFeaturedStatusProvider(
    seer: SeerService,
    hideWatched: Bool
) -> FeaturedContentProviding {
    { limit in
        let candidateLimit = HeroCandidatePool.requestLimit(
            finalLimit: limit,
            hideWatched: hideWatched
        )
        return (try? await seer.trending(limit: candidateLimit)) ?? []
    }
}

/// Maps a `SeerRequestOutcome` to the provider-agnostic `MediaRequestActionResult`
/// the detail page consumes, translating failure reasons into TV-friendly copy
/// (with the acting user's name where it clarifies *whose* limit/permission).
/// `actingName` is the mapped Seerr user, or `nil` when requesting as admin.
func seerRequestResult(_ outcome: SeerRequestOutcome, actingName: String?) -> MediaRequestActionResult {
    switch outcome {
    case let .success(status):
        return .success(status)
    case let .failure(reason):
        let who = actingName ?? "This account"
        switch reason {
        case .noDefaults:
            return .failure(
                title: "No Default Server",
                message: "\(actingName ?? "Your Seerr user") has no default quality profile or server set. Set one in the Seerr web app, then try again."
            )
        case .noPermission:
            return .failure(
                title: "Not Allowed",
                message: "\(who) doesn’t have permission to request this. Check the user’s permissions in Seerr."
            )
        case .quotaExceeded:
            return .failure(
                title: "Request Limit Reached",
                message: "\(who) has reached the request limit. Try again later or adjust the quota in Seerr."
            )
        case .alreadyRequested:
            return .failure(
                title: "Already Requested",
                message: "This title has already been requested."
            )
        case .invalidActingUser:
            return .failure(
                title: "Seerr User Not Found",
                message: "The linked Seerr user no longer exists. Re-link this profile in Settings ▸ This Apple TV ▸ Seerr."
            )
        case .unreachable:
            return .failure(
                title: "Can’t Reach Seerr",
                message: "Couldn’t reach the Seerr server. Check your connection and try again."
            )
        case let .unknown(message):
            return .failure(title: "Request Failed", message: message)
        }
    }
}

/// Builds the Home hero's Random source fetcher (dual-provider): given a set of
/// already-resolved library descriptors (selected from Home's loaded catalog), it
/// fetches server-shuffled pages from Jellyfin and Plex with bounded concurrency.
/// Home carries each library's kind into this seam, so Random no longer repeats a
/// `provider.libraries()` request before it can issue the typed item query.
func makeHeroRandomProvider(
    accounts: [ResolvedAccount],
    hideWatched: Bool,
    identitySources: @escaping @Sendable (MediaItem) -> [MediaSourceRef]
) -> RandomLibraryContentProviding {
    let providersByAccount = Dictionary(
        accounts.map { ($0.account.id, $0.provider) },
        uniquingKeysWith: { first, _ in first }
    )
    let fetchWatchState = makeHeroWatchStateFetcher(accounts: accounts)
    return { libraries, limit in
        let candidateLimit = HeroCandidatePool.requestLimit(
            finalLimit: limit,
            hideWatched: hideWatched
        )
        let items = await HeroRandomLibraryLoader.load(libraries: libraries, limit: candidateLimit) { library, requestLimit in
            guard let provider = providersByAccount[library.accountID] else { return [] }
            let page = PageRequest(
                startIndex: 0,
                limit: requestLimit,
                sort: SortDescriptor(field: .random, direction: .descending)
            )
            guard let result = try? await provider.items(
                in: library.libraryID,
                kind: library.kind,
                page: page
            ) else {
                return []
            }
            return result.items.map {
                $0.taggingSource(library.accountID).taggingLibrary(library.libraryID)
            }
        }
        return await HeroCandidateWatchStateEnricher.enrich(
            items,
            enabled: hideWatched,
            sourceRefs: { item in
                identitySources(item).filter {
                    $0.accountID != item.sourceAccountID || $0.itemID != item.id
                }
            },
            fetch: fetchWatchState
        )
    }
}

private func makeHeroWatchStateFetcher(
    accounts: [ResolvedAccount]
) -> @Sendable (MediaSourceRef) async -> MediaItem? {
    let providersByAccount = Dictionary(
        accounts.map { ($0.account.id, $0.provider) },
        uniquingKeysWith: { first, _ in first }
    )
    return { source in
        guard let provider = providersByAccount[source.accountID],
              let item = try? await provider.item(id: source.itemID)
        else {
            return nil
        }
        return item.taggingSource(source.accountID)
    }
}

/// A light re-enrichment of an already-curated hero set's watch-state — bounded
/// per-item provider lookups, no Seerr/random re-fetch and no artwork re-validation.
/// Backs `HomeView`'s external-refresh fast path so a warmed identity index or a
/// cross-device watch drops a now-seen title without the full re-curate that
/// profiling showed drove multi-second stalls while browsing. A no-op passthrough
/// when Hide Watched is off (nothing to re-check).
func makeHeroWatchStateRefresher(
    accounts: [ResolvedAccount],
    hideWatched: Bool,
    identitySources: @escaping @Sendable (MediaItem) -> [MediaSourceRef]
) -> @Sendable ([MediaItem]) async -> [MediaItem] {
    let fetchWatchState = makeHeroWatchStateFetcher(accounts: accounts)
    return { items in
        await HeroCandidateWatchStateEnricher.enrich(
            items,
            enabled: hideWatched,
            sourceRefs: identitySources,
            fetch: fetchWatchState
        )
    }
}

/// Hydrates only sparse metadata needed by the hero chrome. List endpoints are kept
/// lightweight, but some Plex show rows omit `contentRating` and Jellyfin Favorites
/// omit `overview` / `taglines` even though the full item record contains them. Fetch
/// at most four details at once, preserve curated identity/order/watch state, and
/// copy only missing presentation fields so this cannot reseat the carousel or alter
/// playback routing.
func makeHeroMetadataEnricher(
    accounts: [ResolvedAccount],
    identitySources: @escaping @Sendable (MediaItem) -> [MediaSourceRef]
) -> @Sendable ([MediaItem]) async -> [MediaItem] {
    let providersByAccount = Dictionary(
        accounts.map { ($0.account.id, $0.provider) },
        uniquingKeysWith: { first, _ in first }
    )
    return { items in
        let targets = Dictionary(uniqueKeysWithValues: items.indices.compactMap { index -> (Int, MediaItem)? in
            let item = items[index]
            guard item.officialRating?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
                    || item.productionYear == nil
                    || item.overview?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
                    || item.taglines.isEmpty else { return nil }
            let target = bestSourcePlayItem(
                item,
                accounts: accounts,
                identitySources: identitySources
            )
            guard let accountID = target.sourceAccountID,
                  providersByAccount[accountID] != nil else { return nil }
            return (index, target)
        })
        let candidates = targets.keys.sorted()
        guard !candidates.isEmpty else { return items }

        let concurrency = min(4, candidates.count)
        let details = await withTaskGroup(
            of: (Int, MediaItem?).self,
            returning: [Int: MediaItem].self
        ) { group in
            var next = 0
            for _ in 0..<concurrency {
                let index = candidates[next]
                next += 1
                guard let target = targets[index],
                      let accountID = target.sourceAccountID,
                      let provider = providersByAccount[accountID] else { continue }
                group.addTask { (index, try? await provider.item(id: target.id)) }
            }

            var result: [Int: MediaItem] = [:]
            while let (index, detail) = await group.next() {
                if let detail { result[index] = detail }
                if next < candidates.count, !Task.isCancelled {
                    let queuedIndex = candidates[next]
                    next += 1
                    guard let target = targets[queuedIndex],
                          let accountID = target.sourceAccountID,
                          let provider = providersByAccount[accountID] else { continue }
                    group.addTask { (queuedIndex, try? await provider.item(id: target.id)) }
                }
            }
            return result
        }
        guard !Task.isCancelled else { return items }

        var enriched = items
        for (index, detail) in details {
            if enriched[index].officialRating?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                enriched[index].officialRating = detail.officialRating
            }
            if enriched[index].productionYear == nil {
                enriched[index].productionYear = detail.productionYear
            }
            if enriched[index].genres.isEmpty {
                enriched[index].genres = detail.genres
            }
            if enriched[index].overview?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                enriched[index].overview = detail.overview
            }
            if enriched[index].taglines.isEmpty {
                enriched[index].taglines = detail.taglines
            }
        }
        return enriched
    }
}

/// Builds the provider that backs a Library-browse grid for `library`. When the
/// Home aggregator merged the same library across several servers
/// (`allSourceAccountIDs.count > 1`) it returns an ``AggregatedLibraryProvider``
/// that pages and de-duplicates every server's copy into one grid (criterion 1
/// for Library browse); otherwise it returns the single owning provider. The
/// returned `sourceAccountID` is `nil` for the aggregated case so the browse
/// view-model doesn't re-tag items and clobber their per-source identity.
func resolveLibraryBrowse(
    for library: MediaLibrary,
    in accounts: [ResolvedAccount],
    identitySources: @escaping @Sendable (MediaItem) -> [MediaSourceRef]
) -> (provider: any MediaProvider, sourceAccountID: String?) {
    let accountIDs = library.allSourceAccountIDs
    if accountIDs.count > 1 {
        let sources: [AggregatedLibrarySource] = accountIDs.compactMap { accountID in
            guard
                let provider = resolveOptionalProvider(accountID, in: accounts),
                let containerID = library.containerID(forSourceAccountID: accountID)
            else { return nil }
            return AggregatedLibrarySource(accountID: accountID, containerID: containerID, provider: provider)
        }
        if sources.count > 1 {
            return (
                AggregatedLibraryProvider(
                    sources: sources,
                    serverInfo: accounts.sourceServerInfo(),
                    identitySources: identitySources
                ),
                nil
            )
        }
        // Only one source still resolves (others signed out): browse it directly.
        if let only = sources.first {
            return (only.provider, only.accountID)
        }
    }
    return (resolveProvider(library.sourceAccountID, in: accounts), library.sourceAccountID)
}

/// Retargets a cross-server-merged card to the **locality-best** copy before it
/// is handed to the player, mirroring the detail page's best-source routing.
///
/// Home "Continue Watching" and Search play items directly (`requestPlay`)
/// instead of opening the detail page, so without this they'd launch the
/// arbitrary merge-primary source — which is why the server a card played from
/// felt random. Routing through ``CrossSourceSelector/bestSelection(from:capabilities:)``
/// makes a merged title stream from the copy on the same LAN when one exists
/// (a remote/Tailscale copy only wins when it's the sole source), and
/// ``MediaItem/retargetedForPlayback(item:sources:activeAccountID:versionID:)``
/// reconciles resume to the cross-server furthest progress so switching to the
/// local copy never rewinds. Single-source items pass through untouched.
///
/// Locality is refreshed **live** from each owning provider right here, at the
/// moment of selection, rather than trusting the value the merge/index captured
/// earlier. Locality is a runtime property — it flips the instant you leave the
/// LAN, and a Plex server advertises its own LAN address even to remote clients,
/// so a value sampled before the connection resolver had probed (and then
/// persisted in the identity index) can wrongly read `.local`. By play time every
/// provider has been exercised, so its resolver has settled on the truly-reachable
/// connection; reading `provider.connectionLocality` now and overriding each
/// source's stale locality is what makes "play from the local server" actually
/// hold instead of feeling random.
///
/// `accounts` are the currently signed-in accounts. A merged card's `sources`
/// can still list a server the user has since removed (the eager index snapshot
/// lags an account sign-out), and ``resolveProvider(_:in:)`` silently falls back
/// to `accounts[0]` for an unknown account — so selecting a dead source would
/// play the *wrong* server's copy (or fail). Pruning to live accounts before
/// selection guarantees we only ever pick a server we can actually resolve, and
/// drops the stale refs from the item handed to the player.
///
/// `identitySources` folds in cross-server twins the **live** identity index
/// knows but this card's own `sources` don't yet carry. Home "Continue Watching"
/// and Search play directly (no detail-page resolver runs), so a card that was
/// merged before a local twin finished indexing lists only the server(s) known
/// then — often the remote merge-primary. By play time the index has usually
/// warmed the local copy; unioning it here (deduped by `account:item`, the
/// card's own refs winning on collision because they carry live versions and
/// watch-state) lets the locality selection route to the LAN copy instead of
/// streaming remotely. This is the direct-play counterpart to the detail page's
/// cross-server resolver.
///
/// Episodes are a deliberate exception: the identity index only ingests movies
/// and series, so `identitySources` returns nothing for an episode and a
/// Continue-Watching episode keeps its single CW-feed source. That is by design —
/// resume progress lives on the specific server the episode was watched on, so
/// continuity (resume where you left off) beats locality for a mid-episode card.
/// Local-first for episodic content is instead achieved by navigating into the
/// series (whose detail page retargets to the most-local source once its
/// cross-server twins are discovered).
func bestSourcePlayItem(
    _ item: MediaItem,
    accounts: [ResolvedAccount],
    identitySources: (MediaItem) -> [MediaSourceRef]
) -> MediaItem {
    PlaybackSourceSelection.bestPlayItem(
        item,
        accounts: accounts,
        identitySources: identitySources
    )
}

/// Re-selects the next-best playable source after the server a card was already
/// routed to failed to start playback, so a dead/unreachable copy transparently
/// falls through to another server's copy instead of dead-ending on an error
/// screen (r8-play-failover). `tried` is the set of source account IDs already
/// attempted (the just-failed one included); the function returns `nil` once every
/// live source has been exhausted, letting the caller surface the graceful player
/// error rather than loop forever.
///
/// It mirrors ``bestSourcePlayItem``'s live-locality refresh and identity-index
/// union so failover still prefers a same-LAN copy, but differs in two ways that
/// matter only on the failure path: it does **not** honor an explicit user pick
/// (that pick is exactly what just failed, so it must be allowed to fall through),
/// and it does **not** pass a single source through untouched — a lone source that
/// failed has no alternative, so an empty untried set is a real dead end. Resume
/// is still reconciled across the full live source set (not just the untried
/// subset) so switching servers mid-title never rewinds.
private func failoverPlayItem(
    _ item: MediaItem,
    accounts: [ResolvedAccount],
    identitySources: (MediaItem) -> [MediaSourceRef],
    tried: Set<String>
) -> MediaItem? {
    let activeAccountIDs = Set(accounts.map(\.account.id))
    let liveLocality: [String: SourceLocality] = Dictionary(
        accounts.map { ($0.account.id, $0.provider.connectionLocality) },
        uniquingKeysWith: { first, _ in first }
    )
    func withLiveLocality(_ source: MediaSourceRef) -> MediaSourceRef {
        guard let locality = liveLocality[source.accountID] else { return source }
        var copy = source
        copy.locality = locality
        return copy
    }

    var unioned = item.sources
    var seen = Set(unioned.map(\.id))
    for ref in identitySources(item) where seen.insert(ref.id).inserted {
        unioned.append(ref)
    }

    let liveSources = (activeAccountIDs.isEmpty
        ? unioned
        : unioned.filter { activeAccountIDs.contains($0.accountID) })
        .map(withLiveLocality)

    // Delegate the exclusion + exhaustion decision to the (tested) selector: it
    // drops every already-tried server and returns nil when none remain.
    guard let selection = CrossSourceSelector.bestSelection(
        from: liveSources,
        capabilities: .detected(),
        preferring: nil,
        excluding: tried
    ) else {
        return nil
    }

    // Retarget against the FULL live source set so resume reconciliation still sees
    // every server's progress (furthest-wins), while the chosen account comes from
    // the untried subset the selector picked.
    return MediaItem.retargetedForPlayback(
        item: item,
        sources: liveSources,
        activeAccountID: selection.source.accountID,
        versionID: selection.version?.id
    )
}

/// Builds the player for a play request. Online (TMDb → YouTube) trailers carry a
/// YouTube video-id marker and have no backing account, so they are routed to
/// ``YouTubeTrailerProvider`` (which extracts a playable stream); every other
/// item resolves through its owning account provider as usual.
@MainActor
private func makePlayerViewModel(
    for request: PlayRequest,
    accounts: [ResolvedAccount],
    networkFileResolver: any MediaTransportNetworkFileResolving,
    authenticatedHTTPResolver: any AuthenticatedHTTPResourceResolving,
    offlinePlaybackResolver: (any OfflinePlaybackResolving)? = nil,
    behavior: SubtitleBehavior,
    style: SubtitleStyle,
    playbackSettings: PlaybackSettings,
    spoilerSettings: SpoilerSettings,
    subtitlePolicy: SubtitlePolicy,
    audioPolicy: AudioPolicy,
    seriesTrackStore: any SeriesTrackPreferenceStoring,
    scrobbler: any TraktScrobbling,
    watchBridge: WatchOutboxBridge,
    identitySources: @escaping @Sendable (MediaItem) -> [MediaSourceRef],
    onSubtitleStyleChanged: @escaping (SubtitleStyle) -> Void = { _ in },
    adoptedResolved: PlayerViewModel.PrefetchedPlayback? = nil
) -> PlayerViewModel {
    if let videoID = request.item.youTubeTrailerVideoID {
        let trailerItem = request.item
        let onlineTrailerResolver = ItemDetailViewModel.defaultOnlineTrailerResolver
        let engineFactory = HybridPlayback.engineFactory(
            networkFileResolver: networkFileResolver,
            authenticatedHTTPResolver: authenticatedHTTPResolver
        )
        let trailerViewModel = PlayerViewModel(
            provider: YouTubeTrailerProvider(
                item: trailerItem,
                videoID: videoID,
                alternatives: {
                    // The server's stored trailer URL can go stale (the YouTube
                    // video gets made private/removed). When that happens, fall
                    // back to a keyless search for a still-playable replacement
                    // trailer for the same title.
                    let results = await onlineTrailerResolver(
                        trailerItem.alternativeTrailerSearchSubject
                    )
                    return results.compactMap(\.youTubeTrailerVideoID)
                },
                // Adaptive (separate audio) trailers pair a video-only stream
                // with an audio-only stream. The native engine muxes them via a
                // synthesized HLS master (TrailerAudioMuxComposer) so AVPlayer
                // plays them in sync — unlocking 1080p H.264, which YouTube only
                // serves as adaptive tracks. Falls back to the progressive muxed
                // (~360p) stream if the adaptive path fails.
                allowsSeparateAudio: true
            ),
            itemID: videoID,
            behavior: behavior,
            style: style,
            subtitlePolicy: subtitlePolicy,
            audioPolicy: audioPolicy,
            playbackSettings: playbackSettings,
            spoilerSettings: spoilerSettings,
            seriesTrackStore: seriesTrackStore,
            startPosition: request.startPosition,
            scrobbler: scrobbler,
            engineFactory: engineFactory,
            authenticatedHTTPResolver: authenticatedHTTPResolver,
            autoDismissOnEnd: true
        )
        trailerViewModel.onSubtitleStyleChanged = onSubtitleStyleChanged
        return trailerViewModel
    }
    // Capture only Sendable value types / closures for the durable convergence hook
    // so it can run off the main actor when the player stops. The eager identity
    // lookup itself is resolved at stop time, after the shared index has had the
    // full playback window to warm.
    let convergingItem = request.item
    let primaryAccountID = accounts.first?.account.id
    // The live session key must match the origin target the factory derives for
    // the streaming server, so the reconciler defers writes against exactly that
    // (account,item) while it plays. `sourceAccountID` falls back to the primary
    // account for single-source items, mirroring WatchMutationFactory.targets(for:).
    let liveAccountID = request.item.sourceAccountID ?? primaryAccountID
    let liveItemID = request.item.id
    // For an episode, resolve its neighbours off the main actor so a clean
    // playthrough auto-advances and controls can offer a mid-play jump. The
    // provider is captured (a value-type session); `children(of:)` lists the
    // season in broadcast order. Movies/trailers pass no resolver.
    let episodeProvider = resolveProvider(request.item.sourceAccountID, in: accounts)
    let neighborResolver: (@Sendable () async -> (previous: MediaItem?, next: MediaItem?))?
    if convergingItem.kind == .episode, let seasonID = convergingItem.seasonID {
        let originAccountID = convergingItem.sourceAccountID
        neighborResolver = {
            let siblings = (try? await episodeProvider.children(of: seasonID)) ?? []
            let tagged = originAccountID.map { id in siblings.map { $0.taggingSource(id) } } ?? siblings
            return EpisodeSequence.neighbors(of: convergingItem, in: tagged)
        }
    } else {
        neighborResolver = nil
    }
    // Resolve the series' external ids once so an episode that only carries
    // episode-level ids can still identify its show to Simkl.
    let seriesIDResolver: (@Sendable () async -> [String: String]?)?
    if convergingItem.kind == .episode, let seriesID = convergingItem.seriesID {
        seriesIDResolver = {
            (try? await episodeProvider.item(id: seriesID))?.providerIDs
        }
    } else {
        seriesIDResolver = nil
    }
    let episodeViewModel = PlayerViewModel(
        provider: episodeProvider,
        itemID: request.item.id,
        mediaSourceID: request.item.selectedVersionID,
        offlinePlaybackResolver: offlinePlaybackResolver,
        behavior: behavior,
        style: style,
        subtitlePolicy: subtitlePolicy,
        audioPolicy: audioPolicy,
        playbackSettings: playbackSettings,
        spoilerSettings: spoilerSettings,
        seriesTrackStore: seriesTrackStore,
        seriesAccountFallbackID: primaryAccountID,
        startPosition: request.startPosition,
        scrobbler: scrobbler,
        engineFactory: HybridPlayback.engineFactory(
            networkFileResolver: networkFileResolver,
            authenticatedHTTPResolver: authenticatedHTTPResolver
        ),
        authenticatedHTTPResolver: authenticatedHTTPResolver,
        neighborResolver: neighborResolver,
        seriesIDResolver: seriesIDResolver,
        onPlaybackStopped: makePlaybackStoppedHandler(
            convergingItem: convergingItem,
            primaryAccountID: primaryAccountID,
            liveAccountID: liveAccountID,
            liveItemID: liveItemID,
            watchBridge: watchBridge,
            identitySources: identitySources
        ),
        onPlaybackStarted: {
            // Guard the streaming server while it plays: a mid-play drain can't
            // disturb/zero its now-playing session. Deferred, not dropped.
            if let liveAccountID {
                watchBridge.beginLiveSession(liveAccountID, liveItemID)
            }
        },
        onPlaybackCheckpoint: makePlaybackCheckpointHandler(
            convergingItem: convergingItem,
            primaryAccountID: primaryAccountID,
            watchBridge: watchBridge,
            identitySources: identitySources
        ),
        adoptedResolved: adoptedResolved
    )
    episodeViewModel.onSubtitleStyleChanged = onSubtitleStyleChanged
    return episodeViewModel
}

/// Builds the periodic mid-play convergence hook. Mirrors
/// ``makePlaybackStoppedHandler`` but **enqueue-only**: it does NOT end the live
/// session (the launch server keeps playing/deferred) and does NOT publish an
/// optimistic UI flip (the user is in the fullscreen player). Its sole job is to
/// fan the latest position out to the **other** servers so a "walk away" mid-movie
/// converges within ~60s without pressing Back.
func makePlaybackCheckpointHandler(
    convergingItem: MediaItem,
    primaryAccountID: String?,
    watchBridge: WatchOutboxBridge,
    identitySources: @escaping @Sendable (MediaItem) -> [MediaSourceRef]
) -> @Sendable (_ position: TimeInterval, _ watchedPercent: Double) -> Void {
    { position, percent in
        let union = identitySources(convergingItem)
        let mutation = WatchMutationFactory.playbackStop(
            item: convergingItem,
            position: position,
            watchedPercent: percent,
            primaryAccountID: primaryAccountID,
            additionalSources: union,
            crossServerSync: watchBridge.crossServerSync()
        )
        guard let mutation else { return }
        FanoutDiagnostics.emit(FanoutDiagnostics.stopLine(
            title: convergingItem.title,
            kind: convergingItem.kind,
            itemID: convergingItem.id,
            originAccountID: convergingItem.sourceAccountID ?? primaryAccountID,
            identities: MediaItemIdentity.identities(for: convergingItem),
            indexUnion: union,
            mutationTargets: mutation.targets,
            played: mutation.played,
            resumePosition: mutation.resumePosition,
            watchedPercent: percent,
            phase: "checkpoint"
        ))
        watchBridge.checkpoint(mutation)
    }
}

func makePlaybackStoppedHandler(
    convergingItem: MediaItem,
    primaryAccountID: String?,
    liveAccountID: String?,
    liveItemID: String,
    watchBridge: WatchOutboxBridge,
    identitySources: @escaping @Sendable (MediaItem) -> [MediaSourceRef]
) -> @Sendable (_ position: TimeInterval, _ watchedPercent: Double) -> Void {
    { position, percent in
        let union = identitySources(convergingItem)
        let mutation = WatchMutationFactory.playbackStop(
            item: convergingItem,
            position: position,
            watchedPercent: percent,
            primaryAccountID: primaryAccountID,
            additionalSources: union,
            crossServerSync: watchBridge.crossServerSync()
        )
        // (b)+(c) Make the stop event visible: the played item's resolved identity,
        // the index union found for it, and the final mutation target set. Pure
        // string building + fire-and-forget os_log — never delays the durable write.
        FanoutDiagnostics.emit(FanoutDiagnostics.stopLine(
            title: convergingItem.title,
            kind: convergingItem.kind,
            itemID: convergingItem.id,
            originAccountID: convergingItem.sourceAccountID ?? primaryAccountID,
            identities: MediaItemIdentity.identities(for: convergingItem),
            indexUnion: union,
            mutationTargets: mutation?.targets,
            played: mutation?.played,
            resumePosition: mutation?.resumePosition,
            watchedPercent: percent
        ))
        // End the live session (so the just-played server is no longer deferred)
        // and enqueue the final convergence write, in that order. `percent` rides
        // along so the surface the user returns to can flip its resume bar in place.
        watchBridge.finishPlayback(liveAccountID, liveItemID, percent, mutation)
    }
}




extension View {
    /// Shared player presentation host: the full-screen player + resume prompt.
    /// HomeTab and SearchTab were byte-identical here, so both route through this
    /// one modifier — auto-advance and player wiring live in a single place.
    func playerHost(
        playRequest: Binding<PlayRequest?>,
        resumePrompt: Binding<MediaItem?>,
        accounts: [ResolvedAccount],
        networkFileResolver: any MediaTransportNetworkFileResolving,
        authenticatedHTTPResolver: any AuthenticatedHTTPResourceResolving,
        offlinePlaybackResolver: (any OfflinePlaybackResolving)?,
        behavior: SubtitleBehavior,
        style: SubtitleStyle,
        playbackSettings: PlaybackSettings,
        spoilerSettings: SpoilerSettings,
        subtitlePolicy: SubtitlePolicy,
        audioPolicy: AudioPolicy,
        seriesTrackStore: any SeriesTrackPreferenceStoring,
        scrobbler: any TraktScrobbling,
        watchBridge: WatchOutboxBridge,
        identitySources: @escaping @Sendable (MediaItem) -> [MediaSourceRef],
        showDiagnostics: Bool,
        themePalette: ThemePalette,
        onSubtitleStyleChanged: @escaping (SubtitleStyle) -> Void
    ) -> some View {
        fullScreenCover(item: playRequest) { request in
            PlayerPresentation(
                request: request,
                make: { request, adopted in
                    makePlayerViewModel(
                        for: request,
                        accounts: accounts,
                        networkFileResolver: networkFileResolver,
                        authenticatedHTTPResolver: authenticatedHTTPResolver,
                        offlinePlaybackResolver: offlinePlaybackResolver,
                        behavior: behavior,
                        style: style,
                        playbackSettings: playbackSettings,
                        spoilerSettings: spoilerSettings,
                        subtitlePolicy: subtitlePolicy,
                        audioPolicy: audioPolicy,
                        seriesTrackStore: seriesTrackStore,
                        scrobbler: scrobbler,
                        watchBridge: watchBridge,
                        identitySources: identitySources,
                        onSubtitleStyleChanged: onSubtitleStyleChanged,
                        adoptedResolved: adopted
                    )
                },
                makeFailover: { failedItem, tried in
                    failoverPlayItem(
                        failedItem,
                        accounts: accounts,
                        identitySources: identitySources,
                        tried: tried
                    )
                },
                showDiagnostics: showDiagnostics,
                themePalette: themePalette
            )
        }
        .resumePrompt(item: resumePrompt) { item, startPosition in
            let request = PlayRequest(
                item: item,
                startPosition: startPosition
            )
            HandoffDiagnostics.emit(
                "tap RESUME_CHOICE trace=\(request.traceID.uuidString.prefix(8)) "
                    + "item=\(item.id) start=\(Int(startPosition))"
            )
            playRequest.wrappedValue = request
        }
    }
}




extension View {
    /// Presents a "Resume vs Start Over" choice for an in-progress `item`.
    /// `onChoose` receives the chosen start position in seconds (the saved
    /// resume point for Resume, `0` for Start Over).
    func resumePrompt(
        item: Binding<MediaItem?>,
        onChoose: @escaping (MediaItem, TimeInterval) -> Void
    ) -> some View {
        confirmationDialog(
            item.wrappedValue?.title ?? "",
            isPresented: Binding(
                get: { item.wrappedValue != nil },
                set: { if !$0 { item.wrappedValue = nil } }
            ),
            titleVisibility: .visible,
            presenting: item.wrappedValue
        ) { presented in
            // Resume is listed first so it receives default focus.
            Button("Resume from \(PlaybackTimecode.string(from: presented.resumePosition ?? 0))") {
                onChoose(presented, presented.resumePosition ?? 0)
            }
            Button("Start Over") {
                onChoose(presented, 0)
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}
#endif
