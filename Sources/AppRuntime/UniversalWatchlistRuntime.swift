import CoreModels
import CoreNetworking
import FeatureHomeCore
import FeatureWatchlistCore
import Foundation
import ProviderJellyfin
import ProviderPlex

/// The shell-side dependencies the universal watchlist needs.
///
/// This exists because `AppState+UniversalWatchlist.swift` (tvOS) and
/// `PlozziOSAppModel+UniversalWatchlist.swift` (iOS/iPadOS) had drifted into two
/// 560-line files that were identical line for line apart from one property being
/// spelled `profilesModel` on one shell and `profiles` on the other. Two copies of
/// the alias-resolution, fan-out, native-import and identity-reconciliation logic is
/// two places for the two platforms to disagree about what the viewer's watchlist
/// contains — and the whole point of the universal watchlist is that they do not.
///
/// The runtime keeps its mutable state **on the host** rather than owning it, so the
/// shells' existing lifecycle code (profile switch, sign-out, teardown) that nils
/// these out keeps working unchanged. The logic, which is the part that must not
/// diverge, lives here exactly once.
/// Which accounts the native watchlist import is allowed to read from.
///
/// A free function, not just a member of `UniversalWatchlistHost`, because the
/// shells' profile coordinators have to answer the same question when deciding
/// whether an identity question still gates the import — and the gate agreeing
/// with the import is the entire point. A second, similar-looking derivation is
/// exactly what this replaced.
@MainActor
public enum NativeWatchlistAccounts {
    /// Deliberately not `homeAccounts`, which exists so the signed-in UI is never
    /// blank and therefore falls back to the primary account when the active set
    /// is empty. That's right for a screen and wrong here: a profile that has
    /// explicitly chosen NO servers would import the primary account's watchlist —
    /// its owner's — having asked for nothing. The same applies when every server
    /// a profile chose has since been signed out: browsing falls back to the
    /// household so the profile isn't left blank, but reading a watchlist from
    /// servers it never chose is not a sensible recovery.
    ///
    /// So: no explicit choice means the household set (which genuinely is "all
    /// servers"), and an explicit choice is honoured exactly — including the empty
    /// one, which yields no destinations at all.
    public static func resolve(
        profiles: ProfilesModel,
        accountsProviders: AccountsProvidersModel
    ) -> [ResolvedAccount] {
        // A server whose identity question was declined is left alone entirely.
        // See `Profile.watchlistDeclinedAccountIDs`: dismissing "who are you
        // here?" is not permission to read the account owner's list.
        let declined = profiles.declinedWatchlistAccountIDs(
            forProfile: profiles.activeProfileID
        )
        guard let chosen = profiles.storedActiveAccountIDs(for: profiles.activeProfileID)
        else {
            return accountsProviders.resolvedActiveAccounts.filter {
                !declined.contains($0.account.id)
            }
        }
        let chosenIDs = Set(chosen)
        return accountsProviders.resolvedActiveAccounts.filter {
            chosenIDs.contains($0.account.id) && !declined.contains($0.account.id)
        }
    }
}

/// Scope keys for the universal-watchlist runtime.
///
/// The split is load-bearing:
///
/// - ``live(profileID:identityGeneration:accountsKey:)`` keys objects that capture
///   credentials. A token override changing must rebuild them even when the person
///   did not change.
/// - ``persistent(profileID:accountsKey:plexIdentityKey:)`` keys last-known
///   results on disk. It must survive token refreshes and process restarts, but
///   must change when the actual Plex Home user or server set changes.
///
/// Mixing the two made cached library ownership useless. The process-local
/// generation restarts at zero and bumps while credentials restore, so yesterday's
/// persisted scope almost never equalled today's. The whole native view — including
/// every `ownedSource` already proved — was dropped on every launch, and every card
/// showed "+" until a fresh network read and library resolution finished.
enum UniversalWatchlistScope {
    static func live(
        profileID: String,
        identityGeneration: Int,
        accountsKey: String
    ) -> String {
        "\(profileID)#\(identityGeneration)#\(accountsKey)"
    }

    static func persistent(
        profileID: String,
        accountsKey: String,
        plexIdentityKey: String
    ) -> String {
        "\(profileID)#\(accountsKey)#\(plexIdentityKey)"
    }
}

/// One memoized membership set, keyed by the revision that changes whenever the
/// watchlist would. Main-actor isolated and process-wide because the hosts are
/// per-shell singletons and a stale revision simply misses the cache.
@MainActor
final class UniversalWatchlistMembershipCache {
    static let shared = UniversalWatchlistMembershipCache()
    private var revision: UInt64?
    private var cached: Set<MediaAliasID> = []

    func ids(for revision: UInt64) -> Set<MediaAliasID>? {
        self.revision == revision ? cached : nil
    }

    func store(_ ids: Set<MediaAliasID>, revision: UInt64) {
        self.revision = revision
        cached = ids
    }

    /// Forget the memo outright.
    ///
    /// The revision key is a hash of COUNTS, so it cannot see a transition that
    /// leaves every count where it was — and a local removal is exactly that when
    /// the title's presence came from a destination's own list rather than from a
    /// local intent: the tombstone lands, `activeAliasIDs` never held the alias to
    /// begin with, and nothing the key hashes moves. The set is then served from
    /// this memo forever and the bookmark stays filled on a title that really did
    /// come off the list. Anything that mutates the watchlist locally calls this.
    func invalidate() {
        revision = nil
        cached = []
    }
}

@MainActor
public protocol UniversalWatchlistHost: AnyObject {
    var runtimeFeatureFlags: RuntimeFeatureFlags { get }
    var profiles: ProfilesModel { get }
    var universalWatchlist: WatchlistModel { get }
    var mediaAliasLedger: MediaAliasLedgerModel { get }
    var identityIndex: IdentityIndexModel { get }
    var accountsProviders: AccountsProvidersModel { get }

    /// The connected TRACKER destinations — Trakt, Simkl, and anything added
    /// later. Passed as destinations rather than as the services themselves so
    /// `AppRuntime` need not depend on any of them.
    ///
    /// A list rather than one property because these are peers: a viewer may sync
    /// to both, and when one service's API becomes unusable the others must carry
    /// on untouched.
    var trackerWatchlistDestinations: [any WatchlistDestination] { get }

    /// Where the durable mutation outbox lives. Each shell resolves its own writable
    /// state directory (they differ between tvOS and iOS).
    var universalWatchlistStorageDirectory: URL? { get }

    var universalWatchlistReconciler: WatchlistReconciler? { get set }
    var universalWatchlistMutationStore: DurableWatchlistMutationStore? { get set }
    /// The last-known native watchlist of every destination this profile reads,
    /// and the ids of the destinations currently allowed to contribute.
    ///
    /// Evidence, never intent — see `WatchlistUnion`. Held on the host like the
    /// reconciler beside it, so the shells' existing teardown keeps working, and
    /// held in memory as well as on disk because watchlist membership is asked
    /// once per card and must not touch the filesystem to answer.
    var universalWatchlistNativeView: NativeWatchlistView { get set }
    /// Maps an anime between the id spaces trackers and media servers use, which
    /// otherwise never meet. See `AnimeIDBridgeStore`.
    var universalWatchlistAnimeBridge: AnimeIDBridgeStore { get }
    var universalWatchlistNativeViewStore:
        (any NativeWatchlistViewStoring)? { get set }
    /// True only after the native view for the CURRENT profile/identity/server
    /// scope has been decoded, scoped and installed.
    ///
    /// `store != nil` is not equivalent: while a new scope is being prepared the
    /// old store object still exists, and Home used that to resolve against the
    /// new scope's still-empty in-memory view.
    var universalWatchlistNativeViewLoaded: Bool { get set }
    var universalWatchlistDestinationIDs:
        Set<WatchlistDestinationID> { get set }
    /// Identity of the built reconciler: profile + Plex identity generation, so a
    /// "watching as" change rebuilds its destinations. Not just a profile id
    /// despite the name.
    var universalWatchlistProfileID: String? { get set }
    /// Bumps whenever the active Plex identity (token override) changes. Keys the
    /// reconciler above, so "watching as" someone else rebuilds its destinations.
    var plexWatchlistIdentityGeneration: Int { get }
    var universalWatchlistRetryScheduler: WatchlistRetryScheduler? { get set }
    var universalWatchlistShouldResumeAuthentication: Bool { get set }
    var universalWatchlistIdentityUpdateTask: Task<Void, Never>? { get set }

    func scheduleCloudPublish()

    /// Live account-level plex.tv tokens for Discover, read at the moment of use
    /// by the watchlist destinations.
    var plexDiscoverTokens: PlexDiscoverTokenBox { get }

    /// Guarantees every tracker's token store points at the ACTIVE profile,
    /// re-pointing if it doesn't and returning only once it does.
    ///
    /// The import reads whatever credentials the destinations hold, so this has
    /// to be true before it runs — otherwise it pulls another profile's
    /// watchlist and writes it here. Ordering the profile-switch path fixed the
    /// obvious caller and missed a second one (accounts invalidating re-enters
    /// `prepareUniversalWatchlist` on its own Task), which is why the guarantee
    /// belongs here rather than at each call site. Implementations must be
    /// idempotent and cheap when already scoped — this is called on every
    /// prepare.
    func ensureTrackersScopedToActiveProfile() async

    /// Whether the ACTIVE profile is locked and nobody has entered its PIN this
    /// run.
    ///
    /// Asked here, in the shared path, rather than trusted to each shell's
    /// control flow. A profile becomes active through many routes — deleting the
    /// one before it, a sync arriving, a credential refresh — and every one of
    /// them ends up invalidating accounts, which re-enters this runtime on its
    /// own Task. Guarding the routes individually means a route added later
    /// silently isn't guarded, and the two shells already disagreed about which
    /// ones were. Reading it once, here, is what makes the rule hold everywhere.
    var activeProfileAwaitsUnlock: Bool { get }
}

public extension UniversalWatchlistHost {

    /// The accounts the NATIVE watchlist import may read from — see
    /// `NativeWatchlistAccounts.resolve(profiles:accountsProviders:)`.
    var nativeWatchlistAccounts: [ResolvedAccount] {
        NativeWatchlistAccounts.resolve(
            profiles: profiles,
            accountsProviders: accountsProviders
        )
    }

    func prepareUniversalWatchlist() async {
        guard runtimeFeatureFlags.isEnabled(.universalWatchlist) else { return }
        let profileID = profiles.activeProfileID
        let started = Date()
        do {
            try universalWatchlist.activate(profileID: profileID)
            // The old import wrote every native entry into the ledger as durable
            // intent. Drop those records once, before anything reads the
            // watchlist, so a title only survives while a server that actually
            // holds it is still switched on.
            // Undo declines that were never chosen. A closed sheet used to be
            // read as "don't use this server", and watching as the account
            // owner leaves no Home-user binding either — so a viewer who simply
            // dismissed the question had their own server excluded and their
            // watchlist emptied. Clearing once is safe: a decline the person
            // actually meant is one tap to make again, whereas the silent
            // version is invisible and unexplained.
            profiles.clearInferredWatchlistDeclines()
            let retired = try universalWatchlist.retireNativeImports(
                profileID: profileID
            )
            if retired > 0 {
                PlozzLog.app.info("Watchlist retired imported intents count=\(retired)")
                scheduleCloudPublish()
            }
            try await mediaAliasLedger.activate(profileID: profileID)
            try await seedLegacyUniversalWatchlist()
            // Before anything reads a destination.
            await ensureTrackersScopedToActiveProfile()
            // Every step above suspends, and the active profile can change across
            // any of them. Building the reconciler for a profile that is no
            // longer active gives it THAT profile's destinations and credentials,
            // and the refresh below would then cache one profile's watchlist
            // against another — the guard inside the refresh only notices changes
            // that happen after it starts, so it can't catch this. The switch
            // that superseded us runs its own prepare; dropping here is correct.
            guard profiles.activeProfileID == profileID else {
                PlozzLog.app.info("Watchlist prepare superseded — profile changed during hydrate")
                return
            }
            try await makeUniversalWatchlistReconciler(profileID: profileID)
            if universalWatchlistShouldResumeAuthentication {
                universalWatchlistShouldResumeAuthentication = false
                await resumeUniversalWatchlistAuthentication()
            }
            PlozzLog.app.info(
                "Watchlist hydrate entries=\(universalWatchlist.activeSnapshot.orderedEntries.count) ms=\(Int(Date().timeIntervalSince(started) * 1000))"
            )
            // A profile that hasn't been through setup inherits every server in
            // the household, so reading now would show it the household's
            // aggregate watchlist. Its own state is hydrated above; the refresh
            // waits until it knows which servers this profile actually uses.
            // Re-checked immediately before the refresh for the same reason: the
            // reconciler build and the auth resume both suspend.
            guard profiles.activeProfileID == profileID else {
                PlozzLog.app.info("Watchlist refresh superseded — profile changed before refresh")
                return
            }
            let profile = profiles.activeProfile
            if activeProfileAwaitsUnlock {
                // Nobody has proved this profile's PIN. Its own watchlist is
                // still its own, so this isn't a leak between profiles — but
                // fetching and reconciling it is work done on behalf of someone
                // who hasn't shown they're allowed to be here, and it lands
                // behind a lock screen where it can't be seen anyway. The picker
                // is in front; this resumes when a profile is actually chosen.
                PlozzLog.app.info("Watchlist refresh deferred — profile locked")
            } else if profile.needsSetup {
                PlozzLog.app.info("Watchlist refresh deferred — profile awaiting setup")
            } else if !profiles.actionableIdentityAccountIDs(
                forProfile: profileID,
                importAccountIDs: ProfileServerIdentityPolicy
                    .importPlexAccountIDs(in: nativeWatchlistAccounts)
            ).isEmpty {
                // A server was switched on and nobody has said who this profile
                // is there yet. Reading it now reads it as the account OWNER and
                // shows their watchlist — the same leak setup defers, arriving
                // through a later door. See `Profile.accountsAwaitingIdentity`.
                PlozzLog.app.info("Watchlist refresh deferred — server awaiting identity")
            } else {
                await refreshNativeWatchlistView()
            }
        } catch {
            PlozzLog.app.error("Watchlist local preparation failed")
        }
    }

    /// The universal identity resolver over this device's live evidence and the
    /// profile's durable Plozz ledger.
    ///
    /// Built on demand rather than published: it is a value over two snapshots the
    /// shells already observe, and publishing a third observable derived from both
    /// would add an observation edge — and a republication wave — for nothing. Take
    /// one per prepared-state pass and reuse it; never call this from a SwiftUI
    /// `body` or `init`.
    var titleIdentityResolver: TitleIdentityResolver {
        let index = identityIndex.identitySnapshot
        let aliases = mediaAliasLedger.activeSnapshot
        var hasher = Hasher()
        // Counts only, and only O(1) ones. `crossServerIdentityCount` looks like a
        // peer of `identityCount` but is documented diagnostics: it scans every
        // indexed identity and builds a Set per entry. It has no place on a path
        // callers reach per item.
        hasher.combine(index.identityCount)
        hasher.combine(aliases.recordsByID.count)
        hasher.combine(aliases.activeRecordCount)
        return TitleIdentityResolver(
            index: index,
            aliases: aliases,
            revision: UInt64(bitPattern: Int64(hasher.finalize()))
        )
    }

    /// A cheap value that changes whenever anything `universalWatchlistMembership`
    /// depends on changes: the identity index, the durable alias ledger, or the
    /// watchlist itself. Consumers cache membership against it rather than resolving
    /// an identity per card body — see `MediaItemActionCoordinator.membershipCache`.
    ///
    /// Every input is O(1), because this is read once per item: hashing the whole
    /// active id set would be O(watchlist) per card, trading one hot cost for
    /// another. A local toggle additionally clears the cache outright, so the only
    /// gap is a REMOTE sync that adds and removes the same number of titles between
    /// two reads — which self-heals on the next change of any input.
    var universalWatchlistMembershipRevision: UInt64 {
        let index = identityIndex.identitySnapshot
        let aliases = mediaAliasLedger.activeSnapshot
        var hasher = Hasher()
        hasher.combine(index.identityCount)
        hasher.combine(aliases.recordsByID.count)
        hasher.combine(aliases.activeRecordCount)
        hasher.combine(universalWatchlist.activeSnapshot.activeAliasIDs.count)
        // Tombstones, not just active ids. Removing a title whose presence came
        // from a DESTINATION's list rather than from a local intent adds an
        // `.absent` intent without ever decrementing the active count — every
        // other input here is untouched too, so without this the revision is
        // identical before and after the removal and the memoized membership set
        // is reused: the write reached the server, and the bookmark stayed filled.
        hasher.combine(universalWatchlist.activeSnapshot.tombstoneCount)
        // The native side moves independently of the ledger: a server switched
        // off, or a refresh that returns a different list, changes what the
        // viewer sees without touching a single intent. Counting destinations
        // and their entries keeps this O(1) while still noticing both.
        hasher.combine(universalWatchlistDestinationIDs.count)
        hasher.combine(universalWatchlistNativeView.bucketsByDestinationID.count)
        for bucket in universalWatchlistNativeView.bucketsByDestinationID.values {
            hasher.combine(bucket.entries.count)
        }
        return UInt64(bitPattern: Int64(hasher.finalize()))
    }

    /// The watchlist as the viewer sees it. See `WatchlistUnion`.
    ///
    /// Built on demand rather than published, for the same reason as
    /// `titleIdentityResolver`: it is a value over state the shells already
    /// observe. Take one per prepared-state pass and reuse it; never call this
    /// from a SwiftUI `body`.
    /// The alias ids on the watchlist, memoized against the same revision the
    /// card-level membership cache keys on.
    ///
    /// Separate from `universalWatchlistUnion` because the two have opposite
    /// shapes: a card asks "is this one title on the list" thousands of times
    /// and needs a Set, while the row asks "what is on the list, in order" once
    /// and needs the sorted entries. Serving the first from the second rebuilt
    /// and re-sorted the whole watchlist per card.
    var universalWatchlistMembershipIDs: Set<MediaAliasID> {
        let revision = universalWatchlistMembershipRevision
        if let cached = UniversalWatchlistMembershipCache.shared.ids(for: revision) {
            return cached
        }
        let ids = universalWatchlistUnion.activeAliasIDs
        UniversalWatchlistMembershipCache.shared.store(ids, revision: revision)
        return ids
    }

    var universalWatchlistUnion: WatchlistUnion {
        universalWatchlist.union(
            profileID: profiles.activeProfileID,
            nativeView: universalWatchlistNativeView,
            aliasSnapshot: mediaAliasLedger.activeSnapshot,
            enabledDestinationIDs: universalWatchlistDestinationIDs
        )
    }

    func universalWatchlistMembership(_ item: MediaItem) -> Bool {
        guard runtimeFeatureFlags.isEnabled(.universalWatchlist) else {
            return false
        }
        // One identity path. Resolving through `universalWatchlistAliasID` rather
        // than the item's own evidence means a Plex Discover row (which carries only
        // a PlexGuid) and a Jellyfin row (which carries IMDb) both reach the same
        // Plozz UUID when the index knows they are one title — so the heart on a card
        // and the heart on the page it opens can no longer disagree. It is also the
        // SAME call the write makes, which is what keeps a freshly created alias
        // visible to the button that just created it.
        guard let aliasID = universalWatchlistAliasID(for: item) else { return false }
        // Through the LEDGER's redirect graph, which is the same map the union
        // keyed itself by. Going through the watchlist snapshot's own table
        // instead left a merged title with two ids and made the card disagree
        // with the page it opens.
        let resolved = mediaAliasLedger.activeSnapshot.resolvedAliasID(for: aliasID)
            ?? aliasID
        // The MEMBERSHIP SET, not the union. This is a per-card path, and
        // building the union means allocating and SORTING every entry — 178 of
        // them on the reporting device — once per card body. That is the exact
        // trade the comment on `universalWatchlistMembershipRevision` warns
        // against, and it turned a Set lookup into the app's startup stall.
        return universalWatchlistMembershipIDs.contains(resolved)
    }

    func resolvedUniversalWatchlistItems(
        candidates: [MediaItem]
    ) -> [MediaItem] {
        let aliasSnapshot = mediaAliasLedger.activeSnapshot
        let current = WatchlistPresentationResolver.indexCurrentItems(
            candidates,
            in: aliasSnapshot
        )
        let resolved = (try? universalWatchlist.presentationSnapshot(
            profileID: profiles.activeProfileID,
            union: universalWatchlistUnion,
            aliasSnapshot: aliasSnapshot,
            currentItemsByAliasID: current,
            // Lets an entry with no live candidate still find its owned copy — a
            // library film watchlisted in Plozz appears in no other Home row, so
            // without this it renders as "not in your library" while sitting in it.
            indexedSources: identityIndex.identitySourcesProvider,
            capabilities: .detected()
        ).map(\.item)) ?? []
        return resolved
    }

    func performUniversalWatchlist(
        adding: Bool,
        item: MediaItem
    ) async -> Bool {
        guard runtimeFeatureFlags.isEnabled(.universalWatchlist),
              item.kind == .movie || item.kind == .series else { return false }
        let profileID = profiles.activeProfileID
        guard profileID == profiles.activeProfileID,
              let evidence = universalWatchlistEvidence(for: item)
        else { return false }
        do {
            let aliasID = try await mediaAliasLedger.resolveOrCreate(
                profileID: profileID,
                evidence: evidence,
                preferredAliasID: universalWatchlistPreferredAliasID(for: item)
            )
            if adding {
                try universalWatchlist.add(
                    profileID: profileID,
                    aliasID: aliasID,
                    kind: item.kind,
                    presentation: evidence.presentation
                )
            } else {
                try universalWatchlist.remove(
                    profileID: profileID,
                    aliasID: aliasID,
                    kind: item.kind,
                    presentation: evidence.presentation
                )
            }
            announceUniversalWatchlistDidChange()
            scheduleCloudPublish()
            return true
        } catch {
            PlozzLog.app.error("Watchlist local mutation failed")
            return false
        }
    }

    func beginUniversalWatchlistFanOut(
        adding: Bool,
        item: MediaItem
    ) {
        let profileID = profiles.activeProfileID
        guard let evidence = universalWatchlistEvidence(for: item),
              let aliasID = MediaAliasResolver.lookup(
                evidence: evidence,
                preferredAliasID: universalWatchlistPreferredAliasID(for: item),
                in: mediaAliasLedger.activeSnapshot
              ),
              let target = universalMutationTarget(
                aliasID: aliasID,
                item: item
              ),
              let reconciler = universalWatchlistReconciler else {
            return
        }
        let retryScheduler = universalWatchlistRetryScheduler
        Task {
            try? await reconciler.enqueueFanOut(
                profileID: profileID,
                desiredState: adding ? .present : .absent,
                target: target
            )
            let processed = await reconciler.drain(profileID: profileID)
            await retryScheduler?.reschedule()
            let status = await reconciler.diagnostics(profileID: profileID)
            PlozzLog.app.info(
                "Watchlist queue depth=\(status.queueDepth) processed=\(processed) retry=\(status.transientFailureCount) auth=\(status.authenticationFailureCount) identity=\(status.unsupportedIdentityCount) permanent=\(status.permanentFailureCount)"
            )
        }
    }

    func seedLegacyUniversalWatchlist() async throws {
        let profileID = profiles.activeProfileID
        guard try universalWatchlist.migrationMetadata(
            profileID: profileID
        ).legacyHomeSeedCompletedAt == nil else { return }
        let cached = HomeContentStore(
            namespace: profiles.activeNamespace
        ).load()?.watchlist ?? []
        var entries: [(MediaAliasID, MediaItemKind, MediaAliasPresentation?)] = []
        for item in cached where item.kind == .movie || item.kind == .series {
            guard let evidence = universalWatchlistEvidence(for: item) else { continue }
            let aliasID = try await mediaAliasLedger.resolveOrCreate(
                profileID: profileID,
                evidence: evidence
            )
            entries.append((aliasID, item.kind, evidence.presentation))
        }
        try universalWatchlist.seedLegacyIfNeeded(
            profileID: profileID,
            entries: entries
        )
        PlozzLog.app.info("Watchlist legacy seed count=\(entries.count)")
    }

    /// Re-reads every enabled destination's own watchlist into the read-time
    /// view, and reconciles what they hold against explicit intent.
    ///
    /// This used to be `importUniversalNativeWatchlists`, and it wrote what it
    /// read into the profile's durable ledger as `.present` intents. That made a
    /// server's contribution permanent: switching the server off left every
    /// title it had supplied behind, because intent is deliberately
    /// server-independent and nothing recorded where those titles had come from
    /// in a way that could be undone. Now the entries land in
    /// `universalWatchlistNativeView`, which the union reads over the
    /// destinations that are enabled *right now* — so switching a server off
    /// retracts its contribution for free.
    ///
    /// The reconciliation below is unchanged and still matters: it is how an
    /// explicit ADD gets re-asserted on a server that lost it, and how an
    /// explicit REMOVE is confirmed and then, if the server later adds the title
    /// back, superseded.
    func refreshNativeWatchlistView() async {
        guard let reconciler = universalWatchlistReconciler else { return }
        let profileID = profiles.activeProfileID
        let started = Date()
        let report = await reconciler.fetchNativeEntries()
        // Belt to the caller's braces. Fetching is network work, and what comes
        // back reflects whatever credentials the destinations held when it
        // started; if the active profile moved underneath us in the meantime,
        // these are somebody else's entries and must not be recorded here.
        // Ordering the switch is the real fix — this makes a mistake there
        // fail closed instead of silently caching a stranger's watchlist.
        guard profiles.activeProfileID == profileID else {
            PlozzLog.app.info("Watchlist refresh dropped — profile changed mid-fetch")
            return
        }
        let successfulDestinationIDs = Set(
            report.successes.map(\.destinationID)
        )
        var resolvedByDestination:
            [WatchlistDestinationID: [(MediaAliasID, WatchlistDestinationEntry)]] = [:]
        // Widen every entry's ids before anything is resolved. A tracker's row
        // knows a show only as AniList/MAL and a server's row only as
        // AniDB/TMDb/TVDb, so without this they share nothing to match on and
        // the ledger — correctly refusing to merge records with no common
        // evidence — mints two aliases for one show. The viewer then sees it
        // twice: once as the copy they own, once as one to request.
        let animeBridge = await universalWatchlistAnimeBridge.refreshIfNeeded()
        for read in report.successes {
            for entry in read.entries {
                guard let evidence = entry.mediaAliasEvidence else { continue }
                guard let aliasID = try? await mediaAliasLedger.resolveOrCreate(
                    profileID: profileID,
                    evidence: evidence.bridgingAnimeIdentities(using: animeBridge)
                ) else { continue }
                resolvedByDestination[read.destinationID, default: []]
                    .append((aliasID, entry))
            }
        }

        let targetedKeys = await reconciler.targetedKeys(profileID: profileID)
        var candidatesByDestination:
            [WatchlistDestinationID: [WatchlistNativeReconciliationCandidate]] = [:]
        var targetsByAlias: [MediaAliasID: WatchlistMutationTarget] = [:]
        let presentByDestination = resolvedByDestination.mapValues {
            Set($0.map(\.0))
        }
        for intent in universalWatchlist.activeSnapshot.intentsByAliasID.values {
            guard let record = mediaAliasLedger.activeSnapshot.record(
                for: intent.aliasID
            ), let target = WatchlistMutationTarget(
                aliasID: intent.aliasID,
                aliasRecord: record
            ) else { continue }
            // Only what the person actually asked for may be WRITTEN OUT to a
            // server. Anything else is evidence that some server's list held
            // this title, not a statement that the viewer wants it — and
            // reasserting it pushed one server's list (often the account
            // OWNER's) into every other server the profile is bound to, where
            // removing it in Plozz afterwards no longer took it back out.
            if intent.origin == .local { targetsByAlias[intent.aliasID] = target }
            var destinationIDs = await reconciler.eligibleDestinationIDs(
                for: target
            )
            destinationIDs.formUnion(
                intent.metadata.sourceDestinationIDs.compactMap(
                    WatchlistDestinationID.init(rawValue:)
                )
            )
            destinationIDs.formUnion(targetedKeys.lazy.filter {
                $0.aliasID == intent.aliasID
            }.map(\.destinationID))
            for destinationID in destinationIDs
            where successfulDestinationIDs.contains(destinationID) {
                candidatesByDestination[destinationID, default: []].append(
                    WatchlistNativeReconciliationCandidate(
                        aliasID: intent.aliasID,
                        isPresent:
                            presentByDestination[destinationID, default: []]
                                .contains(intent.aliasID),
                        localDesiredState: intent.desiredState,
                        target: target
                    )
                )
            }
        }

        var view = universalWatchlistNativeView
        var supersededCount = 0
        for read in report.successes {
            let observations = (try? await reconciler.observeNativeBatch(
                profileID: profileID,
                destinationID: read.destinationID,
                candidates: candidatesByDestination[read.destinationID] ?? []
            )) ?? [:]
            // Ask the server which of these it actually holds. It is the same
            // server that just handed us the list, so the answer arrives with
            // the watchlist rather than waiting on a full client-side catalogue
            // scan to complete and publish — which is what used to decide this,
            // and what made a film sitting in the library read as one to go and
            // request until the scan landed.
            //
            // Bounded and cached: only entries whose owned copy isn't already
            // known are asked, and the answer is persisted with the view, so a
            // steady watchlist costs nothing on later refreshes.
            let known = Dictionary(
                universalWatchlistNativeView.bucket(for: read.destinationID)?
                    .entries.compactMap { entry in
                        entry.ownedCopy.map { (entry.aliasID, $0) }
                    } ?? [],
                uniquingKeysWith: { first, _ in first }
            )
            let resolver = await reconciler.libraryResolver(for: read.destinationID)
            var entries: [NativeWatchlistEntry] = []
            for (offset, resolved) in resolvedByDestination[
                read.destinationID,
                default: []
            ].enumerated() {
                let (aliasID, entry) = resolved
                var owned = known[aliasID]
                if owned?.presentation == nil, let resolver,
                   let refreshed = await resolver(entry) {
                    // Also refresh an older cached ownership that has a source
                    // but predates `ownedPresentation`. Without this, the source
                    // made the badge instant but the missing presentation could
                    // never heal — `owned != nil` suppressed the only lookup that
                    // knew the local poster.
                    owned = refreshed
                }
                guard let value = NativeWatchlistEntry(
                    aliasID: aliasID,
                    kind: entry.kind,
                    presentation: entry.presentation,
                    index: offset,
                    ownedSource: owned?.source,
                    // Once the server has proved its own copy, its presentation
                    // belongs with that answer. Persisting only the source ref let
                    // the badge flip now but left Discover artwork on screen
                    // until a later Home rebuild happened to find the full local
                    // MediaItem.
                    ownedPresentation: owned?.presentation
                ) else { continue }
                entries.append(value)
            }
            // A successful read REPLACES what this destination held, empty
            // included: the viewer clearing a server's watchlist is an answer,
            // not a blip. Home learned the same lesson the expensive way.
            view.applySuccess(
                destinationID: read.destinationID,
                entries: entries
            )
            FanoutDiagnostics.emit(
                "watchlist.owned dest=\(read.destinationID.rawValue) entries=\(entries.count) resolved=\(entries.filter { $0.ownedSource != nil }.count) hadResolver=\(resolver != nil)"
            )
            for (aliasID, observation) in observations
            where observation == .nativeAddition {
                // The removal was applied here and the server has since added
                // the title back. Stop the tombstone suppressing it, rather than
                // re-asserting it as intent — presence now comes from the native
                // view, so switching this server off still takes it away.
                if (try? universalWatchlist.markRemovalSuperseded(
                    profileID: profileID,
                    aliasID: aliasID
                )) == true {
                    supersededCount += 1
                }
            }
            let reassertTargets = observations.compactMap {
                aliasID, observation in
                observation == .reassertPresent
                    ? targetsByAlias[aliasID]
                    : nil
            }
            try? await reconciler.enqueue(
                profileID: profileID,
                desiredState: .present,
                targets: reassertTargets,
                destinationID: read.destinationID
            )
        }
        // A destination that could not be read keeps whatever it last told us,
        // marked stale. Blanking the watchlist because one server is down for a
        // moment is exactly the failure the cached-snapshot rules exist to stop.
        for failure in report.failures {
            view.applyFailure(destinationID: failure.destinationID)
        }
        // And one that is no longer enabled contributes nothing at all. This is
        // the whole point: turning a server off retracts its titles, with
        // nothing left behind in the ledger to undo.
        view.retainOnly(destinationIDs: universalWatchlistDestinationIDs)
        persistUniversalWatchlistNativeView(view)

        announceUniversalWatchlistDidChange()
        _ = await reconciler.drain(profileID: profileID)
        await universalWatchlistRetryScheduler?.reschedule()
        // The aliases a native read just created have no provider bindings yet,
        // and nothing else triggers the identity pass now that native entries
        // aren't intents. Without this a title sits in the row unable to find
        // its own library copy, and the page it opens can't tell it is on the
        // watchlist at all.
        await reconcileUniversalWatchlistIdentity(profileID: profileID)

        let union = universalWatchlistUnion
        // Off the startup path entirely: detached so nothing awaits it, and it
        // only fetches when the cached copy is actually stale. The next launch
        // reads the fresher mapping from disk instantly.
        Task.detached(priority: .utility) { [box = universalWatchlistAnimeBridge] in
            await box.refreshIfNeeded()
        }
        let refreshLine = "watchlist.refresh destinations=\(view.bucketsByDestinationID.count) accounts=\(nativeWatchlistAccounts.count) enabled=\(universalWatchlistDestinationIDs.count) reads=\(report.successes.count) entries=\(report.successes.reduce(0) { $0 + $1.entries.count }) failures=\(report.failures.map { "\($0.destinationID.rawValue):\($0.classification)" }) superseded=\(supersededCount) bridge=\(animeBridge.count) ms=\(Int(Date().timeIntervalSince(started) * 1000))"
        PlozzLog.app.info("Watchlist \(refreshLine)")
        FanoutDiagnostics.emit(refreshLine)
        // Counts only — no titles, ids or server names. `nativeOnly` is the half
        // that used to be durable intent; if the row shows titles that a card
        // then claims are not on the watchlist, this is the number to look at.
        // How many union titles the ledger can actually IDENTIFY. A record with
        // no strong external id can only ever match on title+year, which is why
        // a film sitting in the library still renders as "not in your library".
        //
        // Behind the gate: this walks every entry, and `emit` would discard the
        // result anyway when diagnostics are off — which is the default in a
        // shipping build. Counting first and checking after would pay the cost
        // for nobody.
        guard FanoutDiagnostics.isEnabled else { return }
        // Nothing below this point does anything but describe what just
        // happened, so returning here skips only the description.
        let ledger = mediaAliasLedger.activeSnapshot
        var weakOnly = 0
        var noRecord = 0
        var matchable = 0
        for entry in union.orderedEntries {
            guard let record = ledger.record(for: entry.aliasID) else {
                noRecord += 1
                continue
            }
            if record.strongEvidence.isEmpty { weakOnly += 1 } else { matchable += 1 }
        }
        let unionLine = "watchlist.union total=\(union.orderedEntries.count) explicit=\(union.orderedEntries.filter(\.isExplicit).count) nativeOnly=\(union.orderedEntries.filter { !$0.isExplicit }.count) strongID=\(matchable) weakOnly=\(weakOnly) noRecord=\(noRecord) stale=\(union.hasStaleDestinations)"
        PlozzLog.app.info("Watchlist \(unionLine)")
        // Mirrored through the fan-out diagnostics seam so `devicectl … --console`
        // can stream it: `os_log` alone doesn't reach stdout, which is the only
        // channel a remote driver can read on this toolchain.
        FanoutDiagnostics.emit(unionLine)
    }

    /// Keeps the in-memory view and its on-disk copy in step.
    ///
    /// A write failure is logged and otherwise ignored on purpose: this is a
    /// cache of what servers said, so the worst it costs is one refresh, and
    /// refusing to update what is on screen because a file would not write
    /// would be a strictly worse outcome.
    func persistUniversalWatchlistNativeView(_ view: NativeWatchlistView) {
        universalWatchlistNativeView = view
        do {
            try universalWatchlistNativeViewStore?.save(view)
        } catch {
            PlozzLog.app.error("Watchlist native view save failed")
        }
    }

    /// Restores the last-known native lists so the watchlist paints immediately
    /// on launch, instead of showing only explicit adds until the first network
    /// read lands — and so it survives a launch with no connection at all.
    ///
    /// Buckets belonging to destinations this profile no longer reads are
    /// dropped on the way in. Otherwise a server switched off while the app was
    /// closed would come back on the next launch, which is the exact bug the
    /// read-time view exists to fix.
    func loadUniversalWatchlistNativeView(profileID: String, scope: String) {
        let previous = universalWatchlistNativeView
        let store: (any NativeWatchlistViewStoring)?
        if let directory = universalWatchlistStorageDirectory {
            store = try? AtomicNativeWatchlistViewStore(
                directoryURL: directory.appendingPathComponent(
                    "NativeView",
                    isDirectory: true
                ),
                profileID: profileID
            )
        } else {
            store = InMemoryNativeWatchlistViewStore()
        }
        universalWatchlistNativeViewStore = store
        // Scoped BEFORE anything reads it: entries read as a different Plex
        // identity are somebody else's and must not be shown here even once.
        var view = ((try? store?.load()) ?? .empty).scoped(to: scope)
        view.retainOnly(destinationIDs: universalWatchlistDestinationIDs)
        universalWatchlistNativeView = view
        universalWatchlistNativeViewLoaded = true
        if FanoutDiagnostics.isEnabled {
            let entries = view.bucketsByDestinationID.values
                .reduce(0) { $0 + $1.entries.count }
            let owned = view.bucketsByDestinationID.values
                .reduce(0) { count, bucket in
                    count + bucket.entries.lazy
                        .filter { $0.ownedSource != nil }.count
                }
            FanoutDiagnostics.emit(
                "watchlist.cache loaded=\(entries) owned=\(owned) "
                + "destinations=\(view.bucketsByDestinationID.count) "
                + "changed=\(view != previous)"
            )
        }

        // Tell Home about a REAL cached answer immediately.
        //
        // `HomeViewModel` can paint its own content snapshot before this
        // preparation task reaches the native-view store. Its initializer then
        // asks the still-empty watchlist runtime to re-resolve that snapshot and
        // turns every title into "unknown" — a "+" on every card. The cache loads
        // milliseconds later with the `ownedSource` answers from last session,
        // but until now nobody announced that fact. Home only heard the later
        // destination refresh, 30–45 seconds away.
        //
        // Distinct from the ordinary watchlist notification because Home debounces
        // that one to keep a user press responsive. This is startup state already
        // in memory; it should be folded immediately.
        if view != previous, !view.bucketsByDestinationID.isEmpty {
            UniversalWatchlistMembershipCache.shared.invalidate()
            // The Home model can be constructed before its view has installed
            // the notification observer. Yield one main-actor turn: if Home was
            // already mounted this changes nothing; if it was still being built,
            // the subscription exists by the time this fires. Guard the profile
            // and value so a switch during the yield cannot publish somebody
            // else's cache.
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self,
                      self.profiles.activeProfileID == profileID,
                      self.universalWatchlistNativeView == view else { return }
                NotificationCenter.default.post(
                    name: .universalWatchlistCacheDidLoad,
                    object: nil
                )
            }
        }
    }

    func universalWatchlistIdentityDidUpdate() {
        guard runtimeFeatureFlags.isEnabled(.universalWatchlist) else { return }
        let profileID = profiles.activeProfileID
        universalWatchlistIdentityUpdateTask?.cancel()
        universalWatchlistIdentityUpdateTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            guard !Task.isCancelled,
                  let self,
                  self.profiles.activeProfileID == profileID else { return }
            await self.reconcileUniversalWatchlistIdentity(profileID: profileID)
        }
    }

    func reconcileUniversalWatchlistIdentity(profileID: String) async {
        guard let reconciler = universalWatchlistReconciler,
              profiles.activeProfileID == profileID else { return }
        let intents = Array(
            universalWatchlist.activeSnapshot.intentsByAliasID.values
        )
        // Enrichment runs over EVERYTHING the viewer can see, not just what
        // they explicitly asked for. A title that is on the watchlist only
        // because a server lists it still has to be recognisable when it turns
        // up somewhere else — that is what binds the alias to a provider item,
        // and it is how the card in the row and the page it opens agree about
        // whether the title is on the watchlist.
        //
        // Walking intents alone was correct while native entries WERE intents.
        // Once they became a read-time view, native-only titles silently stopped
        // being enriched and the detail page could no longer resolve them: the
        // row showed the film, the page it opened offered to add it.
        var aliasIDs = Set(intents.map(\.aliasID))
        aliasIDs.formUnion(universalWatchlistUnion.orderedEntries.map(\.aliasID))
        let observedAt = Date()
        var enrichments: [MediaAliasEnrichment] = []
        for aliasID in aliasIDs.sorted() {
            guard let record = mediaAliasLedger.activeSnapshot.record(
                for: aliasID
            ) else { continue }
            let identities = record.strongEvidence.compactMap { evidence in
                MediaItemIdentity.strongExternalNamespaces.first {
                    $0.namespace == evidence.namespace
                }.map {
                    MediaIdentity.external(
                        source: $0.canonical,
                        value: evidence.value
                    )
                }
            }
            let sources = identityIndex.identitySnapshot.sources(
                forIdentities: identities,
                kind: record.kind,
                anchorTitle: record.presentation?.title,
                anchorYear: record.presentation?.year
            )
            let bindings = Set(sources.compactMap {
                source -> MediaAliasProviderBindingKey? in
                guard source.providerKind?.usesMediaBrowserAPI == true else {
                    return nil
                }
                return MediaAliasProviderBindingKey(
                    providerKind: source.providerKind!,
                    accountDescriptorID: source.accountID,
                    providerItemID: source.itemID
                )
            }).subtracting(record.locallyValidatedBindings)
            guard !bindings.isEmpty,
                  let evidence = MediaAliasEvidence(
                    kind: record.kind,
                    strong: record.strongEvidence,
                    weak: record.weakEvidence.first,
                    presentation: record.presentation,
                    bindingHints: bindings.map {
                        MediaAliasProviderBindingHint(
                            binding: $0,
                            sourceValidation: .observedBySource,
                            observedAt: observedAt
                        )
                    },
                    locallyValidatedBindings: bindings
                  ) else { continue }
            enrichments.append(MediaAliasEnrichment(
                aliasID: aliasID,
                evidence: evidence
            ))
        }
        _ = try? await mediaAliasLedger.enrichBatch(
            profileID: profileID,
            enrichments: enrichments
        )

        var changes: [WatchlistIdentityEvidenceChange] = []
        for intent in intents {
            guard let record = mediaAliasLedger.activeSnapshot.record(
                for: intent.aliasID
            ), let target = WatchlistMutationTarget(
                aliasID: intent.aliasID,
                aliasRecord: record
            ) else { continue }
            changes.append(.init(
                desiredState: intent.desiredState,
                target: target
            ))
        }
        // Keep the confirmations for everything on the watchlist, native
        // entries included. Keying this on intents alone dropped what the
        // reconciler knew about every native-only title, and a forgotten
        // confirmation means the next pass re-sends the whole watchlist.
        await reconciler.forgetConfirmations(
            profileID: profileID,
            keepingAliasIDs: aliasIDs
        )
        try? await reconciler.identityEvidenceChanged(
            profileID: profileID,
            changes: changes
        )
        _ = await reconciler.drain(profileID: profileID)
        await universalWatchlistRetryScheduler?.reschedule()
        // `considered` must cover the native half too. When it equals the intent
        // count while the union is bigger, native-only titles are going
        // unenriched — which is what makes a card and the page it opens disagree.
        // Tell the screens to re-resolve.
        //
        // The identity index warms in the background, well after the watchlist
        // first paints — and until it does, the only copy of a watchlisted title
        // on hand is the Plex Discover one, which says "not in your library" by
        // construction. Enriching the aliases here is what finally makes the
        // owned copy findable, but nothing was announcing it, so Home kept the
        // items it had resolved at t=0 and every title stayed "request it" until
        // something else happened to rebuild the row.
        announceUniversalWatchlistDidChange()
        let indexSnapshot = identityIndex.identitySnapshot
        let reconcileLine = "watchlist.identity considered=\(aliasIDs.count) intents=\(intents.count) enriched=\(enrichments.count) fanOut=\(changes.count) indexedIdentities=\(indexSnapshot.identityCount) indexedAccounts=\(indexSnapshot.indexedAccountIDs.count)"
        PlozzLog.app.info("Watchlist \(reconcileLine)")
        FanoutDiagnostics.emit(reconcileLine)
    }

    func removeUniversalWatchlist(forProfileID profileID: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            try? self.universalWatchlist.removeProfile(profileID)
            if let fileURL = universalWatchlistStorageDirectory?
                .appendingPathComponent("Mutations", isDirectory: true)
                .appendingPathComponent("\(profileID).json"),
               let store = try? DurableWatchlistMutationStore(
                store: AtomicWatchlistMutationStateStore(fileURL: fileURL)
               ) {
                try? await store.removeProfile(profileID)
            } else {
                try? await self.universalWatchlistMutationStore?.removeProfile(
                    profileID
                )
            }
            // The profile's cached view of what its servers held goes with it.
            // It is not intent, so nothing is lost — but leaving one profile's
            // reading of a server on disk under a deleted id is not something to
            // do on purpose.
            if let directory = universalWatchlistStorageDirectory,
               let store = try? AtomicNativeWatchlistViewStore(
                directoryURL: directory.appendingPathComponent(
                    "NativeView",
                    isDirectory: true
                ),
                profileID: profileID
               ) {
                try? store.destructiveRemove()
            }
            // Compared by prefix because the reconciler is keyed by profile PLUS
            // the Plex identity and the account set, so the stored value is never
            // equal to a bare profile id.
            if self.universalWatchlistProfileID?.hasPrefix("\(profileID)#") == true {
                self.universalWatchlistIdentityUpdateTask?.cancel()
                self.universalWatchlistIdentityUpdateTask = nil
                await self.universalWatchlistRetryScheduler?.cancel()
                self.universalWatchlistRetryScheduler = nil
                self.universalWatchlistProfileID = nil
                self.universalWatchlistReconciler = nil
                self.universalWatchlistMutationStore = nil
                self.universalWatchlistNativeViewStore = nil
                self.universalWatchlistNativeViewLoaded = false
                self.universalWatchlistNativeView = .empty
                self.universalWatchlistDestinationIDs = []
            }
        }
    }

    func makeUniversalWatchlistReconciler(
        profileID: String
    ) async throws {
        // The LIVE reconciler is keyed by profile AND Plex identity generation.
        // The destinations capture the token of whoever the profile plays as,
        // and switching "watching as" changes that token without changing the
        // profile — so a profile-only key kept the previous identity's
        // destination alive and went on reading the previous person's watchlist.
        // `plexIdentityGeneration` bumps on every override change, which is
        // exactly the event that invalidates those live objects.
        //
        // The accounts are in the key too, because switching a server off for a
        // profile changes neither the profile nor the Plex identity. Without
        // them the registry kept the switched-off destination, went on reading
        // it, and went on showing its titles — which is precisely what the
        // read-time view exists to stop.
        let accountsKey = nativeWatchlistAccounts
            .map(\.account.id).sorted().joined(separator: ",")
        let reconcilerKey = UniversalWatchlistScope.live(
            profileID: profileID,
            identityGeneration: plexWatchlistIdentityGeneration,
            accountsKey: accountsKey
        )
        guard universalWatchlistProfileID != reconcilerKey else { return }
        // From here until `loadUniversalWatchlistNativeView` completes, any
        // durable resolution would be against an empty or previous-scope view.
        universalWatchlistNativeViewLoaded = false
        universalWatchlistIdentityUpdateTask?.cancel()
        universalWatchlistIdentityUpdateTask = nil
        await universalWatchlistRetryScheduler?.cancel()
        universalWatchlistRetryScheduler = nil
        var destinations: [any WatchlistDestination] = []
        let profile = profiles.activeProfile
        // The PERSISTED native view must use a stable identity, never the
        // generation above.
        //
        // A generation is a process-local counter: it starts at zero every
        // launch and bumps while the saved Home-user credential is restored.
        // Persisting it into `NativeWatchlistView.identityScope` meant a warm
        // launch almost always compared yesterday's `#1` with today's `#0` (or
        // vice versa), rejected the whole cached view, and forgot every
        // `ownedSource` it had already proved. The row painted every title with
        // a "+" until a fresh network read + library resolution finished 30–45
        // seconds later — on every launch, for a watchlist the viewer had opened
        // a hundred times.
        //
        // `plexPlaybackIdentityKey` is the existing canonical answer: account id
        // + bound Home-user id (or "owner"), stable across token refreshes and
        // different when the actual viewer changes. Accounts stay in the scope
        // too, so switching a server off still invalidates what it contributed.
        let plexIdentityKey = profile.plexPlaybackIdentityKey(
            for: nativeWatchlistAccounts.map(\.account)
        )
        let cacheScopeKey = UniversalWatchlistScope.persistent(
            profileID: profileID,
            accountsKey: accountsKey,
            plexIdentityKey: plexIdentityKey
        )
        for resolved in nativeWatchlistAccounts {
            if let provider = resolved.provider as? PlexProvider,
               let destination = PlexWatchlistDestination(provider: provider) {
                // Talk to Discover as the person this profile plays as: their
                // account-level plex.tv token, not the per-server one browsing
                // uses (Discover rejects a server token with 401/403).
                //
                // Resolved per call rather than captured — the Home-user switch
                // is a network round trip, so a token captured here is often
                // still nil — and when the profile IS bound to a Home user the
                // destination refuses to act until it arrives, instead of falling
                // back to the account owner's list.
                let accountID = resolved.account.id
                let playsAsHomeUser = profile.homeUserBinding(forPlexAccount: accountID) != nil
                destinations.append(
                    PlexWatchlistDestination(
                        provider: provider,
                        requiresHomeUserToken: playsAsHomeUser,
                        discoverToken: { [box = plexDiscoverTokens] in
                            box.token(for: accountID)
                        }
                    ) ?? destination
                )
            } else if let provider = resolved.provider as? JellyfinProvider,
                      let destination = MediaBrowserWatchlistDestination(
                        provider: provider
                      ) {
                destinations.append(destination)
            }
        }
        destinations.append(contentsOf: trackerWatchlistDestinations)
        // Which destinations may contribute to what the viewer sees. Taken from
        // the destinations actually built, so it can never drift from the set
        // that gets read — and narrowing it is exactly what makes switching a
        // server off retract its titles.
        universalWatchlistDestinationIDs = Set(destinations.map(\.id))
        let fileURL = universalWatchlistStorageDirectory?
            .appendingPathComponent("Mutations", isDirectory: true)
            .appendingPathComponent("\(profileID).json")
        let stateStore: any WatchlistMutationStateStoring = fileURL.map {
            AtomicWatchlistMutationStateStore(fileURL: $0)
        } ?? InMemoryWatchlistMutationStateStore()
        let mutationStore = try DurableWatchlistMutationStore(store: stateStore)
        universalWatchlistMutationStore = mutationStore
        loadUniversalWatchlistNativeView(
            profileID: profileID,
            scope: cacheScopeKey
        )
        universalWatchlistReconciler = WatchlistReconciler(
            registry: WatchlistDestinationRegistry(destinations),
            mutationStore: mutationStore
        )
        let reconciler = universalWatchlistReconciler!
        let scheduler = WatchlistRetryScheduler(
            profileID: profileID,
            nextAttempt: { profileID in
                await reconciler.earliestNextAttempt(profileID: profileID)
            },
            drain: { profileID, now in
                await reconciler.drainForRetryScheduler(
                    profileID: profileID,
                    now: now
                )
            }
        )
        universalWatchlistRetryScheduler = scheduler
        universalWatchlistProfileID = reconcilerKey
        await scheduler.reschedule()
    }

    func resumeUniversalWatchlistAuthentication() async {
        guard let reconciler = universalWatchlistReconciler else { return }
        _ = try? await reconciler.resumeAuthentication()
        _ = await reconciler.drain(profileID: profiles.activeProfileID)
        await universalWatchlistRetryScheduler?.reschedule()
    }

    /// Tell every surface the watchlist moved, and drop the memoized membership
    /// set first.
    ///
    /// Both halves, always, in this order. Announcing without invalidating is what
    /// made a removal appear to do nothing: the shells rebuilt promptly, asked
    /// membership again, and were served the pre-removal set out of
    /// ``UniversalWatchlistMembershipCache`` because its O(1) revision key could
    /// not see the change. Anything that mutates the watchlist announces here
    /// rather than posting the notification itself.
    func announceUniversalWatchlistDidChange() {
        UniversalWatchlistMembershipCache.shared.invalidate()
        NotificationCenter.default.post(
            name: .universalWatchlistDidChange,
            object: nil
        )
    }

    func universalWatchlistEvidence(
        for item: MediaItem
    ) -> MediaAliasEvidence? {
        var refs = item.sources
        var seen = Set(refs.map(\.id))
        for ref in identityIndex.identitySnapshot.sourceRefs(for: item)
        where seen.insert(ref.id).inserted {
            refs.append(ref)
        }

        if let accountID = item.sourceAccountID,
           !refs.contains(where: {
               $0.accountID == accountID && $0.itemID == item.id
           }) {
            refs.append(MediaSourceRef(
                accountID: accountID,
                itemID: item.id,
                kind: item.kind,
                providerKind: accountsProviders.accounts.first {
                    $0.id == accountID
                }?.server.provider
            ))
        }
        let bindings = refs.compactMap { ref -> MediaAliasProviderBindingKey? in
            guard ref.providerKind?.usesMediaBrowserAPI == true else { return nil }
            return MediaAliasProviderBindingKey(
                providerKind: ref.providerKind!,
                accountDescriptorID: ref.accountID,
                providerItemID: ref.itemID
            )
        }
        let hints = bindings.map {
            MediaAliasProviderBindingHint(
                binding: $0,
                sourceValidation: .observedBySource,
                observedAt: Date()
            )
        }
        return MediaAliasEvidence(
            item: item,
            // The SAME widening `TitleIdentityResolver` applies when it answers
            // `universalWatchlistMembership`. Without it the read and the write
            // resolved identity differently, and a target that carries no ids of
            // its own — the show a series page promotes its episode hero to, which
            // is a bare `id` + `title` stub — produced evidence with no strong id
            // and no year at all. `resolveOrCreate` then minted a FRESH alias and
            // the removal tombstone landed on a row nothing else referenced: the
            // toast said "Removed from Watchlist" while the filled bookmark, which
            // reads through the index, kept answering about the real alias. Movies
            // were unaffected only because a movie hero is already the movie.
            canonicalEvidence: identityIndex.identitySnapshot.canonicalEvidence(for: item),
            bindingHints: hints,
            locallyValidatedBindings: Set(bindings)
        )
    }

    /// The alias this item is watchlisted AS — the single resolution both the
    /// button's state and the write it performs go through.
    ///
    /// `TitleIdentityResolver` alone is not enough, and the gap is not academic.
    /// It builds evidence from the item's own payload widened by the identity
    /// index; the write widens further with provider bindings (see
    /// `universalWatchlistEvidence`). A subject with no ids of its own — the show
    /// an episode hero is promoted to, which is a bare id + title stub with no
    /// year, so it has no strong evidence and no *weak* evidence either — reaches
    /// the ledger only by its ``MediaAliasLocalSourceKey``. Resolving through one
    /// function means the read and the write cannot look for it under different
    /// keys.
    func universalWatchlistAliasID(for item: MediaItem) -> MediaAliasID? {
        if let preferred = item.watchlistAliasID,
           let resolved = mediaAliasLedger.activeSnapshot.resolvedAliasID(for: preferred) {
            return resolved
        }
        if let indexed = titleIdentityResolver.aliasID(for: item) {
            return indexed
        }
        guard let evidence = universalWatchlistEvidence(for: item) else { return nil }
        return MediaAliasResolver.lookup(
            evidence: evidence,
            in: mediaAliasLedger.activeSnapshot
        )
    }

    /// The alias a watchlist mutation must address: whichever one
    /// ``universalWatchlistMembership`` answered from, so the write can never
    /// target a different row than the button the viewer just pressed.
    func universalWatchlistPreferredAliasID(for item: MediaItem) -> MediaAliasID? {
        universalWatchlistAliasID(for: item)
    }


    func universalMutationTarget(
        aliasID: MediaAliasID,
        item: MediaItem
    ) -> WatchlistMutationTarget? {
        let itemTarget = WatchlistMutationTarget(aliasID: aliasID, item: item)
        let recordTarget = mediaAliasLedger.activeSnapshot.record(
            for: aliasID
        ).flatMap {
            WatchlistMutationTarget(aliasID: aliasID, aliasRecord: $0)
        }
        return WatchlistMutationTarget(
            aliasID: aliasID,
            kind: item.kind,
            externalIDs:
                (itemTarget?.externalIDs ?? [])
                + (recordTarget?.externalIDs ?? []),
            validatedBindings:
                (itemTarget?.validatedBindings ?? [])
                + (recordTarget?.validatedBindings ?? [])
        )
    }}
