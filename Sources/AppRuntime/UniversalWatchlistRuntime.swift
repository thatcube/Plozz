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
    var universalWatchlistProfileID: String? { get set }
    var universalWatchlistRetryScheduler: WatchlistRetryScheduler? { get set }
    var universalWatchlistShouldResumeAuthentication: Bool { get set }
    var universalWatchlistIdentityUpdateTask: Task<Void, Never>? { get set }

    func scheduleCloudPublish()

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
}

public extension UniversalWatchlistHost {


    func prepareUniversalWatchlist() async {
        guard runtimeFeatureFlags.isEnabled(.universalWatchlist) else { return }
        let profileID = profiles.activeProfileID
        let started = Date()
        do {
            try universalWatchlist.activate(profileID: profileID)
            try await mediaAliasLedger.activate(profileID: profileID)
            try await seedLegacyUniversalWatchlist()
            // Before anything reads a destination.
            await ensureTrackersScopedToActiveProfile()
            try await makeUniversalWatchlistReconciler(profileID: profileID)
            if universalWatchlistShouldResumeAuthentication {
                universalWatchlistShouldResumeAuthentication = false
                await resumeUniversalWatchlistAuthentication()
            }
            PlozzLog.app.info(
                "Watchlist hydrate entries=\(universalWatchlist.activeSnapshot.orderedEntries.count) ms=\(Int(Date().timeIntervalSince(started) * 1000))"
            )
            // A profile that hasn't been through setup inherits every server in
            // the household, so importing now would hand it the household's
            // aggregate watchlist. Its own state is hydrated above; the import
            // waits until it knows which servers this profile actually uses.
            if profiles.activeProfile.needsSetup {
                PlozzLog.app.info("Watchlist import deferred — profile awaiting setup")
            } else {
                await importUniversalNativeWatchlists()
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
        return UInt64(bitPattern: Int64(hasher.finalize()))
    }

    func universalWatchlistMembership(_ item: MediaItem) -> Bool {
        guard runtimeFeatureFlags.isEnabled(.universalWatchlist) else {
            return false
        }
        // One identity path. Resolving through `TitleIdentityResolver` rather than
        // the item's own evidence means a Plex Discover row (which carries only a
        // PlexGuid) and a Jellyfin row (which carries IMDb) both reach the same Plozz
        // UUID when the index knows they are one title — so the heart on a card and
        // the heart on the page it opens can no longer disagree.
        guard let aliasID = titleIdentityResolver.aliasID(for: item) else { return false }
        return universalWatchlist.activeSnapshot.contains(aliasID: aliasID)
    }

    func resolvedUniversalWatchlistItems(
        candidates: [MediaItem]
    ) -> [MediaItem] {
        let aliasSnapshot = mediaAliasLedger.activeSnapshot
        let current = WatchlistPresentationResolver.indexCurrentItems(
            candidates,
            in: aliasSnapshot
        )
        return (try? universalWatchlist.presentationSnapshot(
            profileID: profiles.activeProfileID,
            aliasSnapshot: aliasSnapshot,
            currentItemsByAliasID: current,
            // Lets an entry with no live candidate still find its owned copy — a
            // library film watchlisted in Plozz appears in no other Home row, so
            // without this it renders as "not in your library" while sitting in it.
            indexedSources: identityIndex.identitySourcesProvider,
            capabilities: .detected()
        ).map(\.item)) ?? []
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
                preferredAliasID: item.watchlistAliasID
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
            NotificationCenter.default.post(
                name: .universalWatchlistDidChange,
                object: nil
            )
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
                preferredAliasID: item.watchlistAliasID,
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

    func importUniversalNativeWatchlists() async {
        guard let reconciler = universalWatchlistReconciler else { return }
        let profileID = profiles.activeProfileID
        let started = Date()
        let report = await reconciler.fetchNativeEntries()
        // Belt to the caller's braces. Fetching is network work, and what comes
        // back reflects whatever credentials the destinations held when it
        // started; if the active profile moved underneath us in the meantime,
        // these are somebody else's entries and must not be written here.
        // Ordering the switch is the real fix — this makes a mistake there
        // fail closed instead of silently persisting a stranger's watchlist.
        guard profiles.activeProfileID == profileID else {
            PlozzLog.app.info("Watchlist import dropped — profile changed mid-fetch")
            return
        }
        let successfulDestinationIDs = Set(
            report.successes.map(\.destinationID)
        )
        var importedCount = 0
        var resolvedByDestination:
            [WatchlistDestinationID: [(MediaAliasID, WatchlistDestinationEntry)]] = [:]
        for read in report.successes {
            for entry in read.entries {
                guard let evidence = entry.mediaAliasEvidence else { continue }
                guard let aliasID = try? await mediaAliasLedger.resolveOrCreate(
                    profileID: profileID,
                    evidence: evidence
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
            targetsByAlias[intent.aliasID] = target
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

        for read in report.successes {
            let observations = (try? await reconciler.observeNativeBatch(
                profileID: profileID,
                destinationID: read.destinationID,
                candidates: candidatesByDestination[read.destinationID] ?? []
            )) ?? [:]
            let imports = resolvedByDestination[read.destinationID, default: []]
                .map { aliasID, entry in
                    WatchlistNativeImportCandidate(
                        aliasID: aliasID,
                        kind: entry.kind,
                        presentation: entry.presentation,
                        observedAfterConfirmedAbsence:
                            observations[aliasID] == .nativeAddition
                    )
                }
            importedCount += (try? universalWatchlist.importNativeBatch(
                profileID: profileID,
                destinationID: read.destinationID,
                candidates: imports
            )) ?? 0
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
        NotificationCenter.default.post(
            name: .universalWatchlistDidChange,
            object: nil
        )
        _ = await reconciler.drain(profileID: profileID)
        await universalWatchlistRetryScheduler?.reschedule()
        PlozzLog.app.info(
            "Watchlist native import count=\(importedCount) failures=\(report.failures.count) ms=\(Int(Date().timeIntervalSince(started) * 1000))"
        )
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
        let observedAt = Date()
        var enrichments: [MediaAliasEnrichment] = []
        for intent in intents {
            guard let record = mediaAliasLedger.activeSnapshot.record(
                for: intent.aliasID
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
                aliasID: intent.aliasID,
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
        await reconciler.forgetConfirmations(
            profileID: profileID,
            keepingAliasIDs: Set(intents.map(\.aliasID))
        )
        try? await reconciler.identityEvidenceChanged(
            profileID: profileID,
            changes: changes
        )
        _ = await reconciler.drain(profileID: profileID)
        await universalWatchlistRetryScheduler?.reschedule()
        if !changes.isEmpty {
            PlozzLog.app.info(
                "Watchlist late fan-out count=\(changes.count) aliases=\(enrichments.count)"
            )
        }
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
            if self.universalWatchlistProfileID == profileID {
                self.universalWatchlistIdentityUpdateTask?.cancel()
                self.universalWatchlistIdentityUpdateTask = nil
                await self.universalWatchlistRetryScheduler?.cancel()
                self.universalWatchlistRetryScheduler = nil
                self.universalWatchlistProfileID = nil
                self.universalWatchlistReconciler = nil
                self.universalWatchlistMutationStore = nil
            }
        }
    }

    func makeUniversalWatchlistReconciler(
        profileID: String
    ) async throws {
        guard universalWatchlistProfileID != profileID else { return }
        universalWatchlistIdentityUpdateTask?.cancel()
        universalWatchlistIdentityUpdateTask = nil
        await universalWatchlistRetryScheduler?.cancel()
        universalWatchlistRetryScheduler = nil
        var destinations: [any WatchlistDestination] = []
        for resolved in accountsProviders.homeAccounts {
            if let provider = resolved.provider as? PlexProvider,
               let destination = PlexWatchlistDestination(provider: provider) {
                destinations.append(destination)
            } else if let provider = resolved.provider as? JellyfinProvider,
                      let destination = MediaBrowserWatchlistDestination(
                        provider: provider
                      ) {
                destinations.append(destination)
            }
        }
        destinations.append(contentsOf: trackerWatchlistDestinations)
        let fileURL = universalWatchlistStorageDirectory?
            .appendingPathComponent("Mutations", isDirectory: true)
            .appendingPathComponent("\(profileID).json")
        let stateStore: any WatchlistMutationStateStoring = fileURL.map {
            AtomicWatchlistMutationStateStore(fileURL: $0)
        } ?? InMemoryWatchlistMutationStateStore()
        let mutationStore = try DurableWatchlistMutationStore(store: stateStore)
        universalWatchlistMutationStore = mutationStore
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
        universalWatchlistProfileID = profileID
        await scheduler.reschedule()
    }

    func resumeUniversalWatchlistAuthentication() async {
        guard let reconciler = universalWatchlistReconciler else { return }
        _ = try? await reconciler.resumeAuthentication()
        _ = await reconciler.drain(profileID: profiles.activeProfileID)
        await universalWatchlistRetryScheduler?.reschedule()
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
            bindingHints: hints,
            locallyValidatedBindings: Set(bindings)
        )
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
