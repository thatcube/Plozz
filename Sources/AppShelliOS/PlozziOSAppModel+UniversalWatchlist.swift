#if os(iOS)
import CoreModels
import CoreNetworking
import FeatureHomeCore
import FeatureWatchlistCore
import Foundation
import ProviderJellyfin
import ProviderPlex

extension PlozziOSAppModel {
    static func universalWatchlistStorageDirectory() -> URL? {
        writableStateDirectory()?
            .appendingPathComponent("PlozzMediaState", isDirectory: true)
            .appendingPathComponent("Watchlist", isDirectory: true)
    }

    func prepareUniversalWatchlist() async {
        guard runtimeFeatureFlags.isEnabled(.universalWatchlist) else { return }
        let profileID = profiles.activeProfileID
        let started = Date()
        do {
            try universalWatchlist.activate(profileID: profileID)
            try await mediaAliasLedger.activate(profileID: profileID)
            try await seedLegacyUniversalWatchlist()
            try await makeUniversalWatchlistReconciler(profileID: profileID)
            if universalWatchlistShouldResumeAuthentication {
                universalWatchlistShouldResumeAuthentication = false
                await resumeUniversalWatchlistAuthentication()
            }
            PlozzLog.app.info(
                "Watchlist hydrate entries=\(universalWatchlist.activeSnapshot.orderedEntries.count) ms=\(Int(Date().timeIntervalSince(started) * 1000))"
            )
            await importUniversalNativeWatchlists()
        } catch {
            PlozzLog.app.error("Watchlist local preparation failed")
        }
    }

    func universalWatchlistMembership(_ item: MediaItem) -> Bool {
        guard runtimeFeatureFlags.isEnabled(.universalWatchlist) else {
            return false
        }
        if let aliasID = item.watchlistAliasID {
            return universalWatchlist.activeSnapshot.contains(aliasID: aliasID)
        }
        guard let evidence = universalWatchlistLookupEvidence(for: item),
              let aliasID = MediaAliasResolver.lookup(
                evidence: evidence,
                in: mediaAliasLedger.activeSnapshot
              ) else { return false }
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
            currentItemsByAliasID: current
        ).map(\.item)) ?? []
    }

    func performUniversalWatchlist(adding: Bool, item: MediaItem) {
        guard runtimeFeatureFlags.isEnabled(.universalWatchlist),
              item.kind == .movie || item.kind == .series else { return }
        let profileID = profiles.activeProfileID
        Task { @MainActor [weak self] in
            guard let self,
                  profileID == self.profiles.activeProfileID,
                  let evidence = self.universalWatchlistEvidence(for: item)
            else { return }
            do {
                let aliasID = try await self.mediaAliasLedger.resolveOrCreate(
                    profileID: profileID,
                    evidence: evidence,
                    preferredAliasID: item.watchlistAliasID
                )
                if adding {
                    try self.universalWatchlist.add(
                        profileID: profileID,
                        aliasID: aliasID,
                        kind: item.kind,
                        presentation: evidence.presentation
                    )
                } else {
                    try self.universalWatchlist.remove(
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
                self.scheduleCloudPublish()
                guard let target = self.universalMutationTarget(
                    aliasID: aliasID,
                    item: item
                ), let reconciler = self.universalWatchlistReconciler else {
                    return
                }
                try await reconciler.enqueueFanOut(
                    profileID: profileID,
                    desiredState: adding ? .present : .absent,
                    target: target
                )
                let processed = await reconciler.drain(profileID: profileID)
                await self.universalWatchlistRetryScheduler?.reschedule()
                let status = await reconciler.diagnostics(profileID: profileID)
                PlozzLog.app.info(
                    "Watchlist queue depth=\(status.queueDepth) processed=\(processed) retry=\(status.transientFailureCount) auth=\(status.authenticationFailureCount) identity=\(status.unsupportedIdentityCount) permanent=\(status.permanentFailureCount)"
                )
            } catch {
                PlozzLog.app.error("Watchlist local mutation failed")
            }
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
        guard runtimeFeatureFlags.isEnabled(.universalWatchlist),
              let reconciler = universalWatchlistReconciler else { return }
        let profileID = profiles.activeProfileID
        let intents = universalWatchlist.activeSnapshot.intentsByAliasID.values
        Task { [weak self] in
            guard let self else { return }
            var count = 0
            var changes: [WatchlistIdentityEvidenceChange] = []
            for intent in intents {
                guard var record = self.mediaAliasLedger.activeSnapshot.record(
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
                let sources = self.identityIndex.identitySnapshot.sources(
                    forIdentities: identities,
                    kind: record.kind,
                    anchorTitle: record.presentation?.title,
                    anchorYear: record.presentation?.year
                )
                let bindings = sources.compactMap {
                    source -> MediaAliasProviderBindingKey? in
                    guard source.providerKind?.usesMediaBrowserAPI == true else {
                        return nil
                    }
                    return MediaAliasProviderBindingKey(
                        providerKind: source.providerKind!,
                        accountDescriptorID: source.accountID,
                        providerItemID: source.itemID
                    )
                }
                if !bindings.isEmpty,
                   let evidence = MediaAliasEvidence(
                    kind: record.kind,
                    strong: record.strongEvidence,
                    weak: record.weakEvidence.first,
                    presentation: record.presentation,
                    bindingHints: bindings.map {
                        MediaAliasProviderBindingHint(
                            binding: $0,
                            sourceValidation: .observedBySource,
                            observedAt: Date()
                        )
                    },
                    locallyValidatedBindings: Set(bindings)
                   ) {
                    try? await self.mediaAliasLedger.enrich(
                        profileID: profileID,
                        aliasID: intent.aliasID,
                        evidence: evidence
                    )
                    record = self.mediaAliasLedger.activeSnapshot.record(
                        for: intent.aliasID
                    ) ?? record
                }
                guard let target = WatchlistMutationTarget(
                    aliasID: intent.aliasID,
                    aliasRecord: record
                ) else { continue }
                changes.append(.init(
                    desiredState: intent.desiredState,
                    target: target
                ))
                count += 1
            }
            try? await reconciler.identityEvidenceChanged(
                profileID: profileID,
                changes: changes
            )
            _ = await reconciler.drain(profileID: profileID)
            await self.universalWatchlistRetryScheduler?.reschedule()
            if count > 0 {
                PlozzLog.app.info("Watchlist late fan-out count=\(count)")
            }
        }
    }

    func removeUniversalWatchlist(forProfileID profileID: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            try? self.universalWatchlist.removeProfile(profileID)
            if let fileURL = Self.universalWatchlistStorageDirectory()?
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
                await self.universalWatchlistRetryScheduler?.cancel()
                self.universalWatchlistRetryScheduler = nil
                self.universalWatchlistProfileID = nil
                self.universalWatchlistReconciler = nil
                self.universalWatchlistMutationStore = nil
            }
        }
    }

    private func makeUniversalWatchlistReconciler(
        profileID: String
    ) async throws {
        guard universalWatchlistProfileID != profileID else { return }
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
        if let trakt = traktService.watchlistDestination {
            destinations.append(trakt)
        }
        let fileURL = Self.universalWatchlistStorageDirectory()?
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

    private func universalWatchlistEvidence(
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
        return MediaAliasEvidence(
            item: item,
            bindingHints: bindings.map {
                MediaAliasProviderBindingHint(
                    binding: $0,
                    sourceValidation: .observedBySource,
                    observedAt: Date()
                )
            },
            locallyValidatedBindings: Set(bindings)
        )
    }

    private func universalWatchlistLookupEvidence(
        for item: MediaItem
    ) -> MediaAliasEvidence? {
        let bindings = item.sources.compactMap {
            ref -> MediaAliasProviderBindingKey? in
            guard ref.providerKind?.usesMediaBrowserAPI == true else { return nil }
            return MediaAliasProviderBindingKey(
                providerKind: ref.providerKind!,
                accountDescriptorID: ref.accountID,
                providerItemID: ref.itemID
            )
        }
        return MediaAliasEvidence(
            item: item,
            bindingHints: bindings.map {
                MediaAliasProviderBindingHint(binding: $0)
            },
            locallyValidatedBindings: Set(bindings)
        )
    }

    private func universalMutationTarget(
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
    }
}
#endif
