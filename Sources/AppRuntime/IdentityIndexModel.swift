import Foundation
import Observation
import CoreModels

/// The eager cross-server identity index shared by both app composition roots.
///
/// Owns the `identity → sources` index built at sign-in / sync — the single
/// shared source of truth every surface reads (Home/Browse/Search merge, the
/// detail server-picker, and the watch fan-out) so a title's cross-server /
/// cross-account set is identical regardless of entry path. Profile-scoped:
/// rebuilt (`reset()`) when the active profile changes so one profile's catalogue
/// never leaks into another.
///
/// This is a genuine single-responsibility collaborator, not a slice of
/// `AppState`: it owns the index actor, its warm lifecycle, the persisted store,
/// generation/high-water bookkeeping, and the observed snapshot. It depends on
/// `AppState` only through three injected closures (the active accounts to warm,
/// the active profile namespace, and a post-publish hook that re-drains the watch
/// outbox), so the dependency points OUT of the index, never back into the god
/// object. Kept `@MainActor @Observable` so `identitySnapshot` observation is
/// identical to when it lived on `AppState`.
@MainActor
@Observable
public final class IdentityIndexModel {
    /// The active accounts to warm/fan-out over — `AppState.homeAccounts` (active
    /// accounts with the primary fallback). Injected so the index never reaches
    /// back into account/provider resolution.
    @ObservationIgnored
    private let activeAccounts: @MainActor () -> [ResolvedAccount]
    /// The active profile's persistence namespace — `profilesModel.activeNamespace`.
    @ObservationIgnored
    private let namespace: @MainActor () -> String?
    /// Invoked on the main actor after each successful snapshot publish, right
    /// after the `.identityIndexDidUpdate` notification, so the watch outbox
    /// re-drains against the now-larger cross-server union. Wired by `AppState` to
    /// `drainWatchOutbox()`.
    @ObservationIgnored
    private let onPublish: @MainActor () -> Void

    public init(
        activeAccounts: @escaping @MainActor () -> [ResolvedAccount],
        namespace: @escaping @MainActor () -> String?,
        onPublish: @escaping @MainActor () -> Void
    ) {
        self.activeAccounts = activeAccounts
        self.namespace = namespace
        self.onPublish = onPublish
    }


    /// The eager `identity → sources` index built at sign-in / sync. The single
    /// shared store every surface reads (Home/Browse/Search merge, the detail
    /// server-picker, and the watch fan-out) so a title's cross-server/cross-account
    /// set is identical regardless of entry path. Profile-scoped: rebuilt when the
    /// active profile changes so one profile's catalogue never leaks into another.
    @ObservationIgnored
    private var _identityIndex = IdentityIndex()

    /// Profile-scoped disk store for the index membership, so cross-server unions
    /// survive relaunch and are known at t=0 (the cold-boot convergence fix). Built
    /// lazily for the active namespace; dropped on profile switch.
    @ObservationIgnored
    private var _identityIndexStore: (any IdentityIndexStoring)?
    private var identityIndexStore: any IdentityIndexStoring {
        if let store = _identityIndexStore { return store }
        let store = FileIdentityIndexStore(namespace: namespace())
        _identityIndexStore = store
        return store
    }

    /// Whether the persisted membership has been reloaded yet this launch / profile.
    /// Restore runs exactly once so a later warm never re-seeds stale disk data over
    /// fresher live scans.
    @ObservationIgnored
    private var didRestorePersistedIndex = false

    /// In-flight warming task, cancelled and replaced when the active accounts /
    /// profile change so a stale scan can't clobber a newer one.
    @ObservationIgnored
    private var identityWarmTask: Task<Void, Never>?

    /// Monotonically bumped every time the identity index is swapped out from under
    /// an in-flight warm — on a profile reset and at the start of each warm wave
    /// (which cancels its predecessor). A warm task captures the value at launch and
    /// stamps every snapshot publish with it; a publish whose generation no longer
    /// matches is dropped, so a task that slips past its cooperative cancellation
    /// check can never republish a superseded (or another profile's) snapshot over
    /// the live one. See ``publishWarmedSnapshot(_:generation:)``.
    @ObservationIgnored
    private var identityWarmGeneration = 0

    /// High-water mark of `indexedAccountIDs.count` published within the current
    /// warm generation. The index only grows as accounts finish within a wave, so a
    /// snapshot carrying fewer accounts than one already published is a stale,
    /// out-of-order fold from a concurrent warm task; rejecting it stops a smaller
    /// snapshot clobbering a fuller one (last-writer-wins). Reset to 0 whenever the
    /// generation bumps so a legitimately smaller set (accounts removed) still
    /// publishes on the next wave.
    @ObservationIgnored
    private var publishedIndexAccountCount = 0

    /// An immutable snapshot of ``_identityIndex`` that synchronous callers read.
    /// `.empty` until the first account warms — every lookup then returns `[]`, so
    /// callers degrade to their existing on-demand discovery and never drop a write.
    public private(set) var identitySnapshot: IdentityIndexSnapshot = .empty

    /// Thread-safe mirror of ``identitySnapshot`` so the `@Sendable` lookup closure
    /// handed to Home/Browse/Search merging and the off-main player stop hook can
    /// read the live source-of-truth without hopping to the main actor.
    @ObservationIgnored
    public let identitySnapshotStore = IdentityIndexSnapshotStore()

    /// A `@Sendable` identity → cross-server sources lookup over the live index.
    /// The single accessor every surface (merge enrichment, detail picker, watch
    /// fan-out) uses to read the shared source of truth.
    public var identitySourcesProvider: @Sendable (MediaItem) -> [MediaSourceRef] {
        identitySnapshotStore.sourcesProvider()
    }

    /// How long an account's index stays fresh before an opportunistic re-warm.
    private let identityIndexTTL: TimeInterval = 600

    /// Per-library scan caps so building the index can never become an unbounded
    /// full-library walk that stalls launch on a huge catalogue.
    private let identityChunkSize = 200
    /// Per-library ceiling on how many items a single warm pass indexes. Sized
    /// far above any realistic personal library so it's effectively "all of it".
    ///
    /// KNOWN EDGE (r6-10k-cap-complete, documented/deferred): if a library really
    /// does exceed this, the account is still marked rebuilt for the wave, so a
    /// twin living past the 10k boundary in one server's ordering may not get
    /// indexed and could miss its cross-server merge until a future full re-warm
    /// happens to reach it. Closing this fully would need cursor persistence
    /// (resume the scan past the cap across warms). Left as-is: 10k per library is
    /// enormous for a home media server, so the miss window is negligible in
    /// practice and not worth the added state.
    private let identityMaxItemsPerLibrary = 10_000

    /// Caps how many accounts are indexed concurrently during a warm. Without a
    /// cap a many-server library fans out one full library scan per account at
    /// once, swamping launch-time network/decoding — the per-library fan-out
    /// inside `indexAccount` is bounded, but the per-account group was not. Sized
    /// to a typical multi-server household (mirrors `HomeAggregator`'s account
    /// fan-out) so the common case still runs in a single wave.
    private let identityWarmFanoutLimit = 5

    /// Warms (or incrementally refreshes) the identity index for the currently
    /// active accounts. Cold and stale accounts are (re)scanned; removed accounts
    /// are pruned. Bounded and fully best-effort: a failing/asleep server simply
    /// contributes nothing and is retried on the next warm, so the index only ever
    /// grows toward completeness and never blocks playback or watch writes.
    public func warmIdentityIndex(force: Bool = false) {
        let resolved = activeAccounts()
        guard !resolved.isEmpty else { return }
        let activeIDs = Set(resolved.map(\.account.id))
        let serverInfo = resolved.sourceServerInfo()
        let index = _identityIndex
        let ttl = identityIndexTTL
        let chunkSize = identityChunkSize
        let maxPerLibrary = identityMaxItemsPerLibrary
        let store = identityIndexStore
        let fanoutLimit = identityWarmFanoutLimit

        identityWarmTask?.cancel()
        // Supersede any still-in-flight warm from a previous wave: bump the
        // generation (and reset the per-wave high-water mark) so a stale publish
        // that slips past its cancellation check is dropped, while a legitimately
        // smaller account set for THIS wave (e.g. a server was removed) still
        // publishes.
        identityWarmGeneration &+= 1
        publishedIndexAccountCount = 0
        let warmGeneration = identityWarmGeneration
        identityWarmTask = Task { [weak self] in
            // B2: On the first warm this launch, seed the index from the persisted
            // membership and publish immediately, so cross-server unions are known
            // at t=0 — the first post-boot stop fans out to every server instead of
            // origin-only while the live scan below refreshes things. Pruned to the
            // active accounts inside `restore` (B3) so a removed server / switched
            // profile is never resurrected.
            var publishedInRestore = false
            if let self, await self.consumePendingRestore() {
                let persisted = store.load()
                if !persisted.isEmpty, await index.restore(from: persisted, retaining: activeIDs) {
                    let snapshot = await index.snapshot()
                    publishedInRestore = await MainActor.run { () -> Bool in
                        guard self.publishWarmedSnapshot(snapshot, generation: warmGeneration) else { return false }
                        // Tell already-loaded surfaces (Home) that cross-server
                        // membership is now known so they re-fold the fuller source
                        // set into their in-place cards. Without this, a boot whose
                        // live warm surfaces no NEW membership (everything already in
                        // the persisted snapshot) would leave Home on its pre-restore
                        // origin-only sources for the whole session — play-time
                        // locality selection then had no local twin to route to.
                        NotificationCenter.default.post(name: .identityIndexDidUpdate, object: nil)
                        self.onPublish()
                        return true
                    }
                    FanoutDiagnostics.emit(FanoutDiagnostics.indexStateLine(snapshot, phase: "restore"))
                }
            }
            await index.retainAccounts(activeIDs)
            // r6-retain-publish: if the restore path didn't publish this wave,
            // publish the just-pruned snapshot now so a removed server's sources stop
            // appearing immediately — even when NO account needs a (re)scan (the
            // remaining accounts are warm & fresh, so `accountsToWarm` is empty and
            // the warm loop below would otherwise never publish the pruned set).
            if !publishedInRestore, let self {
                let snapshot = await index.snapshot()
                await MainActor.run {
                    guard self.publishWarmedSnapshot(snapshot, generation: warmGeneration) else { return }
                    NotificationCenter.default.post(name: .identityIndexDidUpdate, object: nil)
                    self.onPublish()
                }
            }
            let stale = await index.staleAccounts(olderThan: ttl)

            // Select the accounts that actually need a (re)scan: warm & fresh ones
            // are skipped unless `force`. Resolved up front so the concurrent warm
            // below only spawns real work.
            var accountsToWarm: [ResolvedAccount] = []
            for resolvedAccount in resolved {
                if Task.isCancelled { break }
                let warm = await index.isWarm(resolvedAccount.account.id)
                if warm && !force && !stale.contains(resolvedAccount.account.id) { continue }
                accountsToWarm.append(resolvedAccount)
            }

            // Warm accounts CONCURRENTLY but BOUNDED. Cold-boot warm time used to be
            // the *sum* of each server's scan (a sequential loop), which is the
            // visible "takes a while to warm up on first boot" cost. The identity
            // index is an `actor` keyed by accountID, so concurrent per-account
            // begin/ingest/finish never race. We cap the per-account fan-out (a
            // sliding window) so a many-server library can't launch one full library
            // scan per account at once and swamp the network/decoding pipeline — the
            // window keeps the common household case running in a single wave while
            // bounding pathological (many-server) cases. Each account still
            // publishes its snapshot, persists, and re-drains the outbox the moment
            // IT finishes, so surfaces and fan-out see progress incrementally.
            if !accountsToWarm.isEmpty {
                let warmOne: @Sendable (ResolvedAccount) async -> Void = { resolvedAccount in
                    let accountID = resolvedAccount.account.id
                    if Task.isCancelled { return }
                    await Self.indexAccount(
                        resolvedAccount,
                        into: index,
                        serverInfo: serverInfo[accountID],
                        chunkSize: chunkSize,
                        maxPerLibrary: maxPerLibrary
                    )
                    if Task.isCancelled { return }
                    // Publish progressively so surfaces see each warmed account.
                    let snapshot = await index.snapshot()
                    await MainActor.run {
                        guard let self, self.publishWarmedSnapshot(snapshot, generation: warmGeneration) else { return }
                        // Tell already-loaded surfaces (Home) that the shared
                        // cross-server membership just grew, so they can re-fold
                        // the fuller source set into their in-place cards without
                        // a refetch. Cheap and idempotent: a surface whose rows
                        // gained no new sources no-ops on the re-merge.
                        NotificationCenter.default.post(name: .identityIndexDidUpdate, object: nil)
                        // Re-drain the watch outbox now that another account is
                        // indexed: a movie / series mutation stopped before the
                        // index finished warming re-expands against the larger
                        // union and fans out to the newly-known servers. No-op
                        // when the outbox is empty.
                        self.onPublish()
                    }
                    // Make warm progress visible: each publish shows how many
                    // identities and cross-server unions the index now holds.
                    // crossServer staying 0 as accounts warm is the H1 signal
                    // (no union ⇒ nothing fans out).
                    FanoutDiagnostics.emit(FanoutDiagnostics.indexStateLine(snapshot, phase: "warm"))
                }

                let window = max(1, min(fanoutLimit, accountsToWarm.count))
                await withTaskGroup(of: Void.self) { group in
                    var next = 0
                    for _ in 0..<window {
                        let account = accountsToWarm[next]
                        next += 1
                        group.addTask { await warmOne(account) }
                    }
                    while await group.next() != nil {
                        guard next < accountsToWarm.count else { continue }
                        let account = accountsToWarm[next]
                        next += 1
                        group.addTask { await warmOne(account) }
                    }
                }
                // B1: persist the freshly-warmed membership so the next cold boot can
                // seed it at t=0. Done ONCE after the whole wave rather than after
                // each account: `export()` serializes the entire warm index every
                // time, so a per-account save is O(accounts²) redundant full-JSON
                // writes for a many-server library. Only warm accounts are exported,
                // so a half-scan is never frozen as authoritative; skipped on cancel
                // (a superseding wave will persist its own result).
                if !Task.isCancelled {
                    let persisted = await index.export()
                    try? store.save(persisted)
                }
            }
        }
    }

    /// Returns `true` exactly once per launch / profile so the persisted-index
    /// restore runs a single time even though `warmIdentityIndex` is invoked on
    /// every account-set change.
    @MainActor
    private func consumePendingRestore() -> Bool {
        guard !didRestorePersistedIndex else { return false }
        didRestorePersistedIndex = true
        return true
    }

    /// Scans one account's movie + series libraries in bounded pages and ingests
    /// every catalogue entry's identity → source into the index.
    private static func indexAccount(
        _ resolved: ResolvedAccount,
        into index: IdentityIndex,
        serverInfo: SourceServerInfo?,
        chunkSize: Int,
        maxPerLibrary: Int
    ) async {
        let provider = resolved.provider
        let accountID = resolved.account.id
        guard let libraries = try? await provider.libraries() else { return }

        // `libraries()` forced the connection resolver to probe and settle, so the
        // provider now reports its truly-reachable locality. Refresh the captured
        // serverInfo before it's ingested/persisted: it was sampled at warm-start
        // (before any request), when a Plex provider still reports its first
        // *advertised* connection — a server advertises its own LAN address even to
        // remote clients, so the pre-probe value can wrongly read `.local` and get
        // frozen into the persisted index. Sampling it post-probe keeps the stored
        // local/remote classification honest for the server picker's default.
        let liveServerInfo = serverInfo.map { info -> SourceServerInfo in
            var copy = info
            copy.locality = provider.connectionLocality
            return copy
        }

        // A cancelled warm (account set changed / profile switch) must not begin a
        // rebuild that empties this account's bucket only to abandon it — and must
        // not ingest a further page into a bucket the retain/rebuild logic may have
        // just reset for a removed account, which would resurrect it. The group
        // children are cancelled when `identityWarmTask.cancel()` fires; check right
        // before the mutating index calls (there are awaits above that can suspend
        // long enough for cancellation to land).
        if Task.isCancelled { return }
        await index.beginRebuild(for: accountID)
        // `true` if any page needed an enrichment fetch that failed **or** a
        // catalogue page fetch itself failed, so we leave the account un-finished
        // (cold) and a later warm retries it — the index grows toward completeness
        // and never drops a server permanently, and a transient network blip is
        // never frozen as a "complete" (but truncated) scan until the TTL.
        var inconclusive = false
        for library in libraries where library.kind == .movie || library.kind == .series {
            if Task.isCancelled { return }
            var offset = 0
            while offset < maxPerLibrary {
                if Task.isCancelled { return }
                guard let page = try? await provider.items(
                    in: library.id,
                    kind: library.kind,
                    page: PageRequest(startIndex: offset, limit: chunkSize, sort: .default)
                ) else {
                    // A page fetch threw (network / server error), not a clean end
                    // of catalogue. Mark the scan inconclusive so this library —
                    // and thus the account — is re-warmed rather than finished as
                    // complete while only partially indexed (which would silently
                    // drop that server's memberships from merges until the TTL).
                    inconclusive = true
                    break
                }
                if page.items.isEmpty { break }
                // Enrich any guid-less movie/series (e.g. a Plex series whose list
                // response omitted its Guid array) via its fuller per-item record,
                // so the store is keyed on real strong ids — origin-agnostic and
                // complete with Plex as a destination, not just a source.
                let prepared = await IdentityEnrichment.prepare(page.items) { item in
                    try? await provider.item(id: item.id)
                }
                inconclusive = inconclusive || prepared.inconclusive
                // Re-check just before the ingest: `provider.items` and the
                // per-item enrichment above are awaits during which the warm may
                // have been cancelled (account removed). Ingesting here would write
                // into a bucket a concurrent retain/rebuild already cleared.
                if Task.isCancelled { return }
                await index.ingest(prepared.indexable, accountID: accountID, serverInfo: liveServerInfo)
                offset += page.items.count
                // Only trust `totalCount` as an end-of-catalogue signal when the
                // provider actually reports one (> 0). A provider that returns a
                // full page of items but `totalCount == 0` (unknown/omitted) would
                // otherwise truncate the scan after the first page; rely on the
                // empty-page break above to terminate in that case.
                if page.totalCount > 0 && offset >= page.totalCount { break }
            }
        }
        // Only mark conclusively built when every guid-less item was resolved; an
        // inconclusive scan stays cold so the next warm retries it (never warm-and-
        // forget with a missing Plex copy).
        if !inconclusive {
            await index.finishRebuild(for: accountID)
        }
    }

    /// Publishes a warmed identity snapshot to the observed property + the
    /// `@Sendable` store, but only when it is safe to do so. Returns whether the
    /// publish was applied (callers gate the "membership grew" notification + outbox
    /// re-drain on it).
    ///
    /// Rejected when:
    ///  - `generation` no longer matches the live warm generation — the index was
    ///    swapped out (profile reset) or a newer warm wave started, so this snapshot
    ///    is from a superseded / different-profile index and must not overwrite the
    ///    current one.
    ///  - the snapshot carries fewer indexed accounts than one already published in
    ///    this generation — within a wave the index only grows, so a smaller set is a
    ///    stale, out-of-order fold from a concurrent warm task racing a fuller one.
    @MainActor
    private func publishWarmedSnapshot(_ snapshot: IdentityIndexSnapshot, generation: Int) -> Bool {
        guard generation == identityWarmGeneration else { return false }
        let accountCount = snapshot.indexedAccountIDs.count
        guard accountCount >= publishedIndexAccountCount else { return false }
        publishedIndexAccountCount = accountCount
        identitySnapshot = snapshot
        identitySnapshotStore.update(snapshot)
        return true
    }

    /// Flushes the identity index when the active profile changes so the next warm
    /// rebuilds it for the now-active profile's accounts.
    public func reset() {
        identityWarmTask?.cancel()
        identityWarmTask = nil
        // Supersede any in-flight warm publish so a task mid-`snapshot()` from the
        // OLD profile's index can't overwrite the freshly-emptied snapshot once the
        // new profile takes over.
        identityWarmGeneration &+= 1
        publishedIndexAccountCount = 0
        _identityIndex = IdentityIndex()
        _identityIndexStore = nil
        didRestorePersistedIndex = false
        identitySnapshot = .empty
        identitySnapshotStore.update(.empty)
    }
}
