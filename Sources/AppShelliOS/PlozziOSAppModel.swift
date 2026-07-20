#if os(iOS)
import AniListService
import AppRuntime
import CoreModels
import CoreNetworking
import CoreUI
import CrashReporting
import FeatureAuthCore
import FeatureHomeCore
import FeatureProfiles
import Foundation
import MALService
import MediaDownloads
import MediaTransportCore
import Observation
import ProviderShare
import SeerService
import SimklService
import TraktService

@MainActor
@Observable
final class PlozziOSAppModel {
    private struct HeroTrailerCacheEntry {
        let source: HeroTrailerSource?
        let expiresAt: Date
    }

    struct PendingLibrarySelection: Identifiable {
        let id = UUID()
        let accountIDs: [String]
    }

    enum FirstRunStep: String, Identifiable {
        case profiles
        case confirmProfile
        case theme

        var id: Self { self }
    }

    let accountsProviders: AccountsProvidersModel
    let profiles: ProfilesModel
    let authenticatedHTTPResolver: ManagedAuthenticatedHTTPResolver
    let mediaShareRuntime: DefaultMediaShareRuntime
    let shareScanStatus: ShareScanStatusModel
    let seerService: SeerService
    let traktService: TraktService
    let simklService: SimklService
    let anilistService: AniListService
    let malService: MALService
    let trackerScrobbler: PlozziOSTrackerScrobbler
    let crashReporting: CrashReportingSettingsModel
    let crashReportingController: CrashReportingController
    let requiresLaunchProfileSelection: Bool
    private(set) var settings: PlozziOSSettingsModel
    private(set) var seriesTrackStore: SeriesTrackPreferenceStore
    private(set) var versionPreferences: VersionPreferenceStore
    private(set) var downloads: PlozziOSDownloadsModel
    private(set) var pendingLibrarySelection: PendingLibrarySelection?
    private(set) var pendingFirstRunStep: FirstRunStep?
    @ObservationIgnored
    private(set) var plexHomeUsers: PlexHomeUsersModel!
    @ObservationIgnored
    private(set) lazy var mediaItemActionHandler: any MediaItemActionHandling =
        MediaItemActionCoordinator(
            providerResolver: { [unowned self] accountID in
                accountID.flatMap {
                    self.accountsProviders.provider(forAccountID: $0)
                } ?? self.accountsProviders.primaryProvider
            },
            additionalSources: { [weak self] item in
                self?.identityIndex.identitySnapshot.sourceRefs(for: item) ?? []
            },
            primaryAccountID: { [unowned self] in
                self.accountsProviders.primaryActiveAccount?.id
            },
            crossServerWatchSyncEnabled: { [unowned self] in
                self.settings.playback.settings.syncWatchAcrossServers
            },
            enqueueWatchMutation: { [unowned self] mutation in
                self.applyWatchMutation(mutation)
            }
        )

    private let accountStore: AccountPersisting
    private let durableLocalStateStore: DurableLocalStateStore?
    private let mediaShareAccountService: MediaShareAccountService
    private let mediaShareConfigurationService: MediaShareAccountConfigurationService
    private let mediaShareRescanService: MediaShareRescanService
    @ObservationIgnored private var trackerProfileGeneration: UInt64 = 0
    @ObservationIgnored private var plexUserSelectionGeneration: UInt64 = 0
    @ObservationIgnored private var appliesPlexIdentityAfterLibrarySelection = false
    @ObservationIgnored private var beginsFirstRunAfterLibrarySelection = false
    @ObservationIgnored private var isManagedServerPresentationActive = false
    @ObservationIgnored
    private var queuedPlexUserSelection: PlexHomeUsersModel.PendingPlexUserSelection?
    @ObservationIgnored private var queuedLibraryAccountIDs: [String]?
    @ObservationIgnored private var queuedLibrarySelectionBeginsFirstRun = false
    @ObservationIgnored private var postAddPresentationGeneration: UInt64 = 0
    @ObservationIgnored private var watchReconcilers: [String: WatchStateReconciler] = [:]
    @ObservationIgnored private var heroTrailerCache: [String: HeroTrailerCacheEntry] = [:]
    @ObservationIgnored
    private(set) lazy var identityIndex = IdentityIndexModel(
        activeAccounts: { [weak self] in
            self?.accountsProviders.homeAccounts ?? []
        },
        namespace: { [weak self] in
            self?.profiles.activeNamespace
        },
        onPublish: { [weak self] in
            self?.drainWatchOutbox()
        }
    )

    private var watchReconciler: WatchStateReconciler {
        let profileID = profiles.activeProfileID
        if let existing = watchReconcilers[profileID] {
            return existing
        }
        let reconciler = makeWatchReconciler(profileID: profileID)
        watchReconcilers[profileID] = reconciler
        return reconciler
    }

    var accountError: String?

    init() {
        let authenticatedHTTPResolver = ManagedAuthenticatedHTTPResolver()
        let accountStore: AccountStore
        var launchErrors: [String] = []
        do {
            accountStore = try DefaultAccountStoreFactory.make()
        } catch {
            accountStore = DefaultAccountStoreFactory.makeCredentialOnlyFallback()
            launchErrors.append(
                "Network-share credential storage is unavailable: \(error.localizedDescription)"
            )
        }
        let mediaShareRuntime = DefaultMediaShareRuntime.make(
            accountStore: accountStore,
            artworkCacheLifecycle: PlozziOSMediaShareArtworkCacheLifecycle()
        )
        ArtworkImageCache.shared.configure(
            networkFileService: mediaShareRuntime.artworkNetworkFileService
        )
        let registry = ManagedProviderRegistry.make()
        let durableLocalStateStore: DurableLocalStateStore?
        do {
            durableLocalStateStore = try DurableLocalStateStoreFactory.userIndependent()
        } catch {
            durableLocalStateStore = nil
            launchErrors.append(
                "Local network-share library storage is unavailable: \(error.localizedDescription)"
            )
        }
        mediaShareRuntime.registerProvider(
            into: registry,
            durableLocalStateStore: durableLocalStateStore
        )
        let profiles = ProfilesModel(
            store: ProfileStore(
                secureStore: KeychainStore(service: "com.plozz.app.household")
            ),
            defaultActiveAccountIDs: accountStore.activeAccountIDs()
        )
        let requiresLaunchProfileSelection =
            profiles.askProfileOnStartup && profiles.profiles.count > 1
        let accountsProviders = AccountsProvidersModel(
            accountStore: accountStore,
            registry: registry,
            profilesModel: profiles
        )
        let shareScanStatus = ShareScanStatusModel()
        let seerService = SeerServiceFactory.make(
            connectionStore: HouseholdSeerConnectionStore(
                secureStore: KeychainStore(service: "com.plozz.app.household")
            )
        )
        let trackerNamespace = profiles.activeNamespace
        let traktService = TraktServiceFactory.make(namespace: trackerNamespace)
        let simklService = SimklServiceFactory.make(namespace: trackerNamespace)
        let anilistService = AniListServiceFactory.make(namespace: trackerNamespace)
        let malService = MALServiceFactory.make(namespace: trackerNamespace)
        self.accountStore = accountStore
        self.profiles = profiles
        self.accountsProviders = accountsProviders
        self.authenticatedHTTPResolver = authenticatedHTTPResolver
        self.mediaShareRuntime = mediaShareRuntime
        self.shareScanStatus = shareScanStatus
        self.durableLocalStateStore = durableLocalStateStore
        self.seerService = seerService
        self.traktService = traktService
        self.simklService = simklService
        self.anilistService = anilistService
        self.malService = malService
        self.trackerScrobbler = PlozziOSTrackerScrobbler(
            trakt: traktService.scrobbler,
            simkl: simklService.scrobbler,
            anilist: anilistService.scrobbler,
            mal: malService.scrobbler
        )
        self.crashReporting = CrashReportingSettingsModel()
        self.crashReportingController = CrashReportingController()
        self.requiresLaunchProfileSelection = requiresLaunchProfileSelection
        self.settings = PlozziOSSettingsModel(
            namespace: profiles.activeNamespace
        )
        self.seriesTrackStore = SeriesTrackPreferenceStore(
            namespace: profiles.activeNamespace
        )
        self.versionPreferences = VersionPreferenceStore(
            namespace: profiles.activeNamespace
        )
        self.downloads = Self.makeDownloadsModel(
            namespace: profiles.activeProfileID,
            durableStore: durableLocalStateStore,
            mediaShareRuntime: mediaShareRuntime,
            accountsProviders: accountsProviders,
            authenticatedHTTPResolver: authenticatedHTTPResolver
        )
        self.pendingLibrarySelection = nil
        self.pendingFirstRunStep =
            !accountsProviders.accounts.isEmpty
                && !profiles.firstRunProfileSetupComplete
            ? .profiles
            : nil
        self.mediaShareAccountService = MediaShareAccountService(runtime: mediaShareRuntime)
        self.mediaShareConfigurationService = MediaShareAccountConfigurationService(
            accountStore: accountStore
        )
        self.mediaShareRescanService = MediaShareRescanService(
            accountsProviders: accountsProviders
        )
        self.plexHomeUsers = PlexHomeUsersModel(
            accountsProviders: accountsProviders,
            profilesModel: profiles,
            switchProfile: { [weak self] profileID in
                self?.selectProfile(profileID)
            }
        )
        accountsProviders.tokenResolver = { [weak self] accountID in
            self?.plexHomeUsers.resolvedToken(for: accountID)
                ?? accountStore.token(for: accountID)
        }
        accountsProviders.credentialRevision = { [weak self] account in
            self?.plexHomeUsers.effectiveCredentialRevision(for: account)
                ?? account.credentialRevision
        }
        authenticatedHTTPResolver.configure { [weak accountsProviders] locator in
            guard let accountsProviders,
                  let account = accountsProviders.accounts.first(where: {
                      $0.id == locator.accountID
                  }),
                  account.server.provider == locator.provider,
                  accountsProviders.credentialRevision(account) == locator.credentialRevision,
                  let token = accountsProviders.tokenResolver(account.id),
                  !token.isEmpty else {
                throw MediaTransportError.authentication(
                    reason: "inactive authenticated HTTP identity"
                )
            }
            let baseURL: URL
            if account.server.provider == .plex {
                let provider = try accountsProviders.registry.provider(
                    for: accountsProviders.providerResolutionContext(
                        for: account,
                        token: token
                    )
                )
                guard let originProvider = provider as? AuthenticatedHTTPOriginProviding else {
                    throw MediaTransportError.unsupportedCapability(
                        "dynamic authenticated HTTP origin"
                    )
                }
                baseURL = originProvider.authenticatedHTTPOrigin
            } else {
                baseURL = account.server.baseURL
            }
            return ManagedAuthenticatedHTTPResolver.Context(
                provider: account.server.provider,
                accountID: account.id,
                credentialRevision: accountsProviders.credentialRevision(account),
                baseURL: baseURL,
                token: token
            )
        }
        do {
            try accountStore.recoverCredentialMutations()
        } catch {
            PlozzLog.auth.error(
                "Credential recovery failed; incomplete shares remain hidden"
            )
            launchErrors.append(
                "An interrupted network-share update could not be recovered."
            )
        }
        accountError = launchErrors.isEmpty ? nil : launchErrors.joined(separator: "\n")
        accountsProviders.reloadAccounts()
        if !accountsProviders.accounts.isEmpty,
           !profiles.firstRunProfileSetupComplete {
            pendingFirstRunStep = .profiles
        }
        identityIndex.warmIdentityIndex()
        let scanReporter = shareScanStatus.reporter()
        Task { await mediaShareRuntime.configure(reporter: scanReporter) }
        if !requiresLaunchProfileSelection {
            plexHomeUsers.ensurePlexIdentityForActiveProfile()
        }
        updateTrackersForActiveProfile()
        drainWatchOutbox()
        applyCrashReportingPreference()
        Task {
            let namespaces = [nil] + profiles.profiles.map { Optional($0.id) }
            await seerService.migrateLegacyConnectionIfNeeded(namespaces: namespaces)
            await seerService.refreshStatus()
        }
    }

    var accounts: [Account] {
        accountsProviders.accounts
    }

    var crashReportContext: CrashReportContext {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "Unknown"
        let build = info?["CFBundleVersion"] as? String ?? "Unknown"
        let providers = Set(accounts.map(\.server.provider.displayName)).sorted()
        return CrashReportContext.make(
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "com.thatcube.Plozz",
            version: version,
            build: build,
            providers: providers
        )
    }

    func applyCrashReportingPreference() {
        crashReportingController.apply(
            enabled: crashReporting.settings.isEnabled,
            context: crashReportContext
        )
    }

    private func reloadAccountsAndCrashContext() {
        accountsProviders.reloadAccounts()
        applyCrashReportingPreference()
    }

    func provider(for item: MediaItem) -> (any MediaProvider)? {
        if let accountID = item.sourceAccountID {
            return accountsProviders.provider(forAccountID: accountID)
        }
        return accountsProviders.primaryProvider
    }

    func heroTrailerResolver() -> HeroTrailerResolving {
        { [weak self] item in
            await self?.resolveHeroTrailer(for: item)
        }
    }

    private func resolveHeroTrailer(for item: MediaItem) async -> HeroTrailerSource? {
        let cacheKey = "\(item.sourceAccountID ?? "_"):\(item.id)"
        let now = Date()
        if let cached = heroTrailerCache[cacheKey], cached.expiresAt > now {
            return cached.source
        }

        let source = await FastHeroTrailerResolver.resolve(
            item: item,
            identitySources: identityIndex.identitySourcesProvider(item),
            providerForAccountID: {
                accountsProviders.provider(forAccountID: $0)
            },
            authenticatedHTTPResolver: authenticatedHTTPResolver
        )
        guard !Task.isCancelled else { return nil }

        // Signed playback URLs can expire, so positive entries stay short-lived.
        // Negative entries use an even shorter TTL so a newly-added trailer appears
        // without requiring an app restart.
        let ttl: TimeInterval = source == nil ? 120 : 600
        heroTrailerCache[cacheKey] = HeroTrailerCacheEntry(
            source: source,
            expiresAt: now.addingTimeInterval(ttl)
        )
        if heroTrailerCache.count > 64 {
            heroTrailerCache = heroTrailerCache.filter { $0.value.expiresAt > now }
            if heroTrailerCache.count > 64,
               let oldest = heroTrailerCache.min(by: {
                   $0.value.expiresAt < $1.value.expiresAt
               })?.key {
                heroTrailerCache[oldest] = nil
            }
        }
        return source
    }

    func rescanShare(accountID: String) {
        mediaShareRescanService.rescan(accountID: accountID)
    }

    var deviceID: String {
        accountStore.deviceID()
    }

    func selectProfile(_ id: String) {
        profiles.select(id)
        settings = PlozziOSSettingsModel(namespace: profiles.activeNamespace)
        seriesTrackStore = SeriesTrackPreferenceStore(
            namespace: profiles.activeNamespace
        )
        versionPreferences = VersionPreferenceStore(
            namespace: profiles.activeNamespace
        )
        downloads = Self.makeDownloadsModel(
            namespace: profiles.activeProfileID,
            durableStore: durableLocalStateStore,
            mediaShareRuntime: mediaShareRuntime,
            accountsProviders: accountsProviders,
            authenticatedHTTPResolver: authenticatedHTTPResolver
        )
        plexHomeUsers.ensurePlexIdentityForActiveProfile()
        reloadAccountsAndCrashContext()
        identityIndex.reset()
        identityIndex.warmIdentityIndex()
        updateTrackersForActiveProfile()
        drainWatchOutbox()
        Task { await seerService.setActiveProfile(namespace: profiles.activeNamespace) }
    }

    private func updateTrackersForActiveProfile() {
        let namespace = profiles.activeNamespace
        trackerProfileGeneration &+= 1
        let generation = trackerProfileGeneration
        Task {
            guard generation == trackerProfileGeneration else { return }
            await traktService.setActiveProfile(namespace: namespace)
            guard generation == trackerProfileGeneration else { return }
            await simklService.setActiveProfile(namespace: namespace)
            guard generation == trackerProfileGeneration else { return }
            await anilistService.setActiveProfile(namespace: namespace)
            guard generation == trackerProfileGeneration else { return }
            await malService.setActiveProfile(namespace: namespace)
        }
    }

    private func applyWatchMutation(_ mutation: WatchMutation) {
        let reconciler = watchReconciler
        Task {
            await reconciler.enqueue(mutation)
            await reconciler.drain()
        }
    }

    func beginPlayback(for item: MediaItem) {
        guard let accountID = item.sourceAccountID
            ?? accountsProviders.primaryActiveAccount?.id else {
            return
        }
        let reconciler = watchReconciler
        Task {
            await reconciler.beginLiveSession(
                accountID: accountID,
                itemID: item.id
            )
        }
    }

    func checkpointPlayback(
        for item: MediaItem,
        position: TimeInterval,
        watchedPercent: Double
    ) {
        guard let mutation = WatchMutationFactory.playbackStop(
            item: item,
            position: position,
            watchedPercent: watchedPercent,
            primaryAccountID: accountsProviders.primaryActiveAccount?.id,
            crossServerSync: settings.playback.settings.syncWatchAcrossServers
        ) else {
            return
        }
        let reconciler = watchReconciler
        Task {
            await reconciler.enqueue(mutation)
            await reconciler.drain()
        }
    }

    func finishPlayback(
        for item: MediaItem,
        position: TimeInterval,
        watchedPercent: Double
    ) {
        let accountID = item.sourceAccountID
            ?? accountsProviders.primaryActiveAccount?.id
        let mutation = WatchMutationFactory.playbackStop(
            item: item,
            position: position,
            watchedPercent: watchedPercent,
            primaryAccountID: accountsProviders.primaryActiveAccount?.id,
            crossServerSync: settings.playback.settings.syncWatchAcrossServers
        )
        publishPlaybackMutation(
            mutation,
            itemID: item.id,
            watchedPercent: watchedPercent
        )
        let reconciler = watchReconciler
        Task {
            if let accountID {
                await reconciler.endLiveSession(
                    accountID: accountID,
                    itemID: item.id
                )
            }
            if let mutation {
                await reconciler.enqueue(mutation)
            }
            await reconciler.drain()
        }
    }

    private func publishPlaybackMutation(
        _ mutation: WatchMutation?,
        itemID: String,
        watchedPercent: Double
    ) {
        guard let mutation else { return }
        var itemIDs = Set(mutation.optimisticTargets.map(\.itemID))
        itemIDs.insert(itemID)
        MediaItemMutation(
            itemIDs: itemIDs,
            scopedItemIDs: Set(mutation.optimisticTargets.map(\.id)),
            played: mutation.played,
            resumePosition: mutation.resumePosition,
            playedPercentage: mutation.played == true
                ? 1
                : max(0, min(1, watchedPercent / 100))
        ).post()
    }

    private func drainWatchOutbox() {
        let reconciler = watchReconciler
        Task { await reconciler.drain() }
    }

    func pendingWatchMutations() async -> [WatchMutation] {
        await watchReconciler.snapshot().pending
    }

    func appliedWatchRecency() async -> [String: AppliedResumeRecord] {
        await watchReconciler.snapshot().appliedRecency
    }

    private func makeWatchReconciler(profileID: String) -> WatchStateReconciler {
        let profile = profiles.profiles.first { $0.id == profileID } ?? profiles.activeProfile
        let namespace = profile.settingsNamespace(isDefault: profiles.isDefault(profile))
        let trakt = TraktServiceFactory.make(namespace: namespace).scrobbler
        let simkl = SimklServiceFactory.make(namespace: namespace).scrobbler
        let anilist = AniListServiceFactory.make(namespace: namespace).scrobbler
        let mal = MALServiceFactory.make(namespace: namespace).scrobbler
        let store: any WatchMutationStoring
        if let durableLocalStateStore {
            do {
                store = try DurableWatchMutationStore(
                    store: durableLocalStateStore,
                    profileID: profileID,
                    onLoadFailure: {
                        PlozzLog.app.error(
                            "iOS durable watch outbox unavailable; preserving corrupt state"
                        )
                    }
                )
            } catch {
                PlozzLog.app.error(
                    "iOS durable watch outbox address invalid; using memory only"
                )
                store = InMemoryWatchMutationStore()
            }
        } else {
            store = InMemoryWatchMutationStore()
        }
        let applier = AppShellWatchMutationApplier(
            isActive: { [weak self] in
                await MainActor.run { self?.profiles.activeProfileID == profileID }
            },
            resolveProvider: { [weak self] accountID in
                await MainActor.run {
                    guard self?.profiles.activeProfileID == profileID else { return nil }
                    return self?.accountsProviders.provider(forAccountID: accountID)
                }
            },
            applyTrakt: { intent in
                try await trakt.scrobbleResult(
                    item: intent.makeScrobbleItem(),
                    progress: intent.progress,
                    event: .stop
                )
            },
            applySimkl: { intent in
                try await simkl.scrobbleResult(
                    item: intent.makeScrobbleItem(),
                    progress: intent.progress,
                    event: .stop
                )
            },
            applyAniList: { intent in
                try await anilist.scrobbleResult(
                    item: intent.makeScrobbleItem(),
                    progress: intent.progress,
                    event: .stop
                )
            },
            applyMAL: { intent in
                try await mal.scrobbleResult(
                    item: intent.makeScrobbleItem(),
                    progress: intent.progress,
                    event: .stop
                )
            },
            allAccountIDs: { [weak self] in
                await MainActor.run {
                    self?.accountsProviders.homeAccounts.map(\.account.id) ?? []
                }
            },
            indexedSeriesSources: {
                [identitySnapshotStore = identityIndex.identitySnapshotStore]
                originSeries in
                identitySnapshotStore.current.sources(for: originSeries)
                    .filter { $0.kind == .series }
            },
            indexedSources: {
                [identitySnapshotStore = identityIndex.identitySnapshotStore]
                identities, kind, anchorTitle, anchorYear in
                identitySnapshotStore.current.sources(
                    forIdentities: identities,
                    kind: kind,
                    anchorTitle: anchorTitle,
                    anchorYear: anchorYear
                )
            },
            indexedAccountIDs: {
                [identitySnapshotStore = identityIndex.identitySnapshotStore] in
                identitySnapshotStore.current.indexedAccountIDs
            }
        )
        return WatchStateReconciler(
            store: store,
            applier: applier,
            onPersistenceFailure: {
                PlozzLog.app.error("iOS durable watch outbox write failed")
            }
        )
    }

    private static func makeDownloadsModel(
        namespace: String,
        durableStore: DurableLocalStateStore?,
        mediaShareRuntime: DefaultMediaShareRuntime,
        accountsProviders: AccountsProvidersModel,
        authenticatedHTTPResolver: ManagedAuthenticatedHTTPResolver
    ) -> PlozziOSDownloadsModel {
        guard let durableStore else {
            return PlozziOSDownloadsModel(
                initializationError: "Durable download storage is unavailable."
            )
        }
        do {
            return try PlozziOSDownloadsModel(
                profileID: namespace,
                durableStore: durableStore,
                networkFileResolver: mediaShareRuntime.networkFileResolver,
                providerKind: { accountID in
                    accountsProviders.accounts.first {
                        $0.id == accountID
                    }?.server.provider
                },
                managedURLResolver: { source in
                    let provider: (any MediaProvider)? = await MainActor.run {
                        guard accountsProviders.accounts.first(where: {
                            $0.id == source.accountID
                        })?.server.provider == source.provider else {
                            return nil
                        }
                        return accountsProviders.provider(
                            forAccountID: source.accountID
                        )
                    }
                    guard let provider else {
                        throw MediaTransportError.authentication(
                            reason: "inactive managed download account"
                        )
                    }
                    let playback = try await provider.playbackInfo(
                        for: source.itemID,
                        mediaSourceID: source.mediaSourceID,
                        forceTranscode: false
                    )
                    guard case .authenticatedHTTP(let locator) =
                            playback.downloadableOriginalSource,
                          locator.deliveryMode == .directFile else {
                        throw MediaTransportError.unsupportedCapability(
                            "managed background download requires a direct file"
                        )
                    }
                    return try await authenticatedHTTPResolver.resolve(locator)
                }
            )
        } catch {
            return PlozziOSDownloadsModel(
                initializationError: error.localizedDescription
            )
        }
    }

    /// Creates or updates a profile from a shared `ProfileEditorView` draft —
    /// the single draft-based persistence path shared with tvOS. Cosmetic fields
    /// (name, avatar symbol/emoji/photo, colours) are written through; every
    /// non-cosmetic field (linked account, Plex Home bindings, Seerr identity,
    /// active-account subset) is preserved. A new profile is seeded with the
    /// current household accounts, selected, and handed to the first-run theme
    /// step — mirroring the previous `addProfile` behaviour.
    func saveProfile(_ draft: ProfileDraft) {
        let trimmed = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if let id = draft.id {
            guard var profile = profiles.profiles.first(where: { $0.id == id }) else {
                return
            }
            // Cosmetics from the editor…
            profile.name = trimmed
            profile.avatarSymbol = draft.avatarSymbol
            profile.colorIndex = draft.colorIndex
            profile.avatarImageURL = draft.avatarImageURL
            profile.avatarEmoji = draft.avatarEmoji
            profile.avatarEmojiColorIndex = draft.avatarEmojiColorIndex
            // …plus the preserved non-cosmetic fields the draft carried through
            // unchanged, so an edit never wipes Plex Home bindings / linked
            // accounts. Membership (`activeAccountIDs`) is intentionally NOT
            // touched here — the editor sends it empty to mean "leave alone."
            profile.linkedAccountID = draft.linkedAccountID
            profile.plexHomeUserID = draft.plexHomeUserID
            profile.plexHomeUserName = draft.plexHomeUserName
            profile.plexHomeUserAccountID = draft.plexHomeUserAccountID
            profile.plexHomeUserRequiresPIN = draft.plexHomeUserRequiresPIN
            profile.plexHomeUserAvatarURL = draft.plexHomeUserAvatarURL
            profile.plexHomeUserBindings = draft.plexHomeUserBindings
            profiles.update(profile)
        } else {
            let created = profiles.add(
                name: trimmed,
                avatarSymbol: draft.avatarSymbol,
                colorIndex: draft.colorIndex,
                linkedAccountID: draft.linkedAccountID,
                activeAccountIDs: accounts.map(\.id),
                plexHomeUserID: draft.plexHomeUserID,
                plexHomeUserName: draft.plexHomeUserName,
                plexHomeUserAccountID: draft.plexHomeUserAccountID,
                plexHomeUserRequiresPIN: draft.plexHomeUserRequiresPIN,
                plexHomeUserAvatarURL: draft.plexHomeUserAvatarURL,
                plexHomeUserBindings: draft.plexHomeUserBindings,
                avatarImageURL: draft.avatarImageURL,
                avatarEmoji: draft.avatarEmoji,
                avatarEmojiColorIndex: draft.avatarEmojiColorIndex
            )
            selectProfile(created.id)
            scheduleFirstRunStep(.theme)
        }
    }

    func removeProfile(_ id: String) {
        let previousActiveProfileID = profiles.activeProfileID
        profiles.remove(id)
        watchReconcilers[id] = nil
        if profiles.activeProfileID != previousActiveProfileID {
            settings = PlozziOSSettingsModel(namespace: profiles.activeNamespace)
            seriesTrackStore = SeriesTrackPreferenceStore(
                namespace: profiles.activeNamespace
            )
            versionPreferences = VersionPreferenceStore(
                namespace: profiles.activeNamespace
            )
            downloads = Self.makeDownloadsModel(
                namespace: profiles.activeProfileID,
                durableStore: durableLocalStateStore,
                mediaShareRuntime: mediaShareRuntime,
                accountsProviders: accountsProviders,
                authenticatedHTTPResolver: authenticatedHTTPResolver
            )
            plexHomeUsers.ensurePlexIdentityForActiveProfile()
        }
        reloadAccountsAndCrashContext()
        identityIndex.reset()
        identityIndex.warmIdentityIndex()
        updateTrackersForActiveProfile()
        drainWatchOutbox()
        Task { await seerService.setActiveProfile(namespace: profiles.activeNamespace) }
    }

    var activeSeerrUserID: Int? {
        profiles.activeProfile.seerrUserID
    }

    var activeSeerrUserName: String? {
        profiles.activeProfile.seerrUserName
    }

    func setSeerrUser(_ user: SeerUser?, for profileID: String) {
        guard var profile = profiles.profiles.first(where: { $0.id == profileID }) else {
            return
        }
        profile.seerrUserID = user?.id
        profile.seerrUserName = user?.name
        profile.seerrUserAvatarURL = user?.avatarURL?.absoluteString
        profiles.update(profile)
    }

    func disconnectSeerr() {
        seerService.disconnect()
        for var profile in profiles.profiles where profile.seerrUserID != nil {
            profile.seerrUserID = nil
            profile.seerrUserName = nil
            profile.seerrUserAvatarURL = nil
            profiles.update(profile)
        }
    }

    func activeAccountIDs(for profileID: String) -> Set<String> {
        Set(
            profiles.activeAccountIDs(
                for: profileID,
                fallback: accountStore.activeAccountIDs()
            )
        )
    }

    func setAccount(_ accountID: String, enabled: Bool, for profileID: String) {
        var ids = activeAccountIDs(for: profileID)
        if enabled {
            ids.insert(accountID)
        } else {
            ids.remove(accountID)
        }
        profiles.setActiveAccountIDs(Array(ids), for: profileID)
        watchReconcilers[profileID] = nil
        if profiles.activeProfileID == profileID {
            reloadAccountsAndCrashContext()
            identityIndex.reset()
            identityIndex.warmIdentityIndex()
            drainWatchOutbox()
        }
    }

    func persist(_ sessions: [UserSession]) {
        do {
            let existingIDs = Set(accountsProviders.accounts.map(\.id))
            let isFirstRun = existingIDs.isEmpty
                && !profiles.firstRunProfileSetupComplete
            var addedAccounts: [Account] = []
            for session in sessions {
                let account = Account(from: session)
                try accountStore.add(account, token: session.accessToken)
                if !existingIDs.contains(account.id) {
                    addedAccounts.append(account)
                }
            }
            accountError = nil
            reloadAccountsAndCrashContext()
            identityIndex.warmIdentityIndex()
            if isFirstRun,
               let session = sessions.first(where: {
                   let account = Account(from: $0)
                   return addedAccounts.contains(where: { $0.id == account.id })
               }) {
                profiles.seedDefaultProfileIdentity(
                    name: session.userName,
                    avatarImageURL: session.avatarURL?.absoluteString
                )
            }
            preparePostSignInOnboarding(
                for: addedAccounts,
                beginsFirstRun: isFirstRun && !addedAccounts.isEmpty
            )
        } catch {
            accountError = error.localizedDescription
        }
    }

    func selectPlexUserDuringOnboarding(_ user: PlexHomeUser) {
        guard let pending = plexHomeUsers.pendingPlexUserSelection else { return }
        let binding = PlexHomeUserBinding(
            homeUserID: user.id,
            name: user.name,
            avatarURL: user.avatarURL?.absoluteString,
            requiresPIN: user.requiresPIN
        )
        var profile = profiles.activeProfile
        for accountID in pending.applyToAccountIDs {
            profile = profile.settingHomeUserBinding(
                binding,
                forPlexAccount: accountID
            )
        }

        profiles.update(profile)
        if pending.isFirstRun {
            profiles.seedDefaultProfileIdentity(
                name: user.name,
                avatarImageURL: user.avatarURL?.absoluteString
            )
        }
        appliesPlexIdentityAfterLibrarySelection = true
        plexHomeUsers.clearUserSelection()
        scheduleLibrarySelection(
            accountIDs: pending.applyToAccountIDs,
            beginsFirstRun: pending.isFirstRun
        )
    }

    func cancelPlexUserSelectionDuringOnboarding() {
        guard let pending = plexHomeUsers.pendingPlexUserSelection else { return }
        plexHomeUsers.clearUserSelection()
        scheduleLibrarySelection(
            accountIDs: pending.applyToAccountIDs,
            beginsFirstRun: pending.isFirstRun
        )
    }

    func beginManagedServerPresentation() {
        postAddPresentationGeneration &+= 1
        plexUserSelectionGeneration &+= 1
        queuedPlexUserSelection = nil
        queuedLibraryAccountIDs = nil
        queuedLibrarySelectionBeginsFirstRun = false
        isManagedServerPresentationActive = true
    }

    func finishManagedServerPresentation() {
        isManagedServerPresentationActive = false
        if let selection = queuedPlexUserSelection {
            queuedPlexUserSelection = nil
            plexHomeUsers.presentUserSelection(selection)
        } else if let accountIDs = queuedLibraryAccountIDs {
            let beginsFirstRun = queuedLibrarySelectionBeginsFirstRun
            queuedLibraryAccountIDs = nil
            queuedLibrarySelectionBeginsFirstRun = false
            scheduleLibrarySelection(
                accountIDs: accountIDs,
                beginsFirstRun: beginsFirstRun
            )
        }
    }

    func completeLibrarySelection() {
        pendingLibrarySelection = nil
        if beginsFirstRunAfterLibrarySelection {
            beginsFirstRunAfterLibrarySelection = false
            scheduleFirstRunStep(.profiles)
        } else if appliesPlexIdentityAfterLibrarySelection {
            appliesPlexIdentityAfterLibrarySelection = false
            plexHomeUsers.ensurePlexIdentityForActiveProfile()
        }
    }

    func enableProfilesForFirstRun() {
        profiles.enableProfiles()
        pendingFirstRunStep = .confirmProfile
    }

    func declineProfilesForFirstRun() {
        profiles.disableProfiles()
        pendingFirstRunStep = .theme
    }

    func confirmFirstRunProfile() {
        pendingFirstRunStep = .theme
    }

    func finishFirstRunThemeSelection() {
        profiles.markFirstRunProfileSetupComplete()
        pendingFirstRunStep = nil
        if appliesPlexIdentityAfterLibrarySelection {
            appliesPlexIdentityAfterLibrarySelection = false
            plexHomeUsers.ensurePlexIdentityForActiveProfile()
        }
    }

    private func preparePostSignInOnboarding(
        for accounts: [Account],
        beginsFirstRun: Bool
    ) {
        plexUserSelectionGeneration &+= 1
        let generation = plexUserSelectionGeneration
        guard let account = accounts.first(where: {
            $0.server.provider == .plex
                && profiles.activeProfile.homeUserBinding(
                    forPlexAccount: $0.id
                ) == nil
        }) else {
            scheduleLibrarySelection(
                accountIDs: accounts.map(\.id),
                beginsFirstRun: beginsFirstRun
            )
            return
        }
        Task {
            let users = await plexHomeUsers.plexHomeUsers(
                forAccountID: account.id
            )
            guard generation == plexUserSelectionGeneration else { return }
            guard users.count >= 2,
                  accountsProviders.accounts.contains(where: {
                      $0.id == account.id
                  }) else {
                scheduleLibrarySelection(
                    accountIDs: accounts.map(\.id),
                    beginsFirstRun: beginsFirstRun
                )
                return
            }
            schedulePlexUserSelection(
                PlexHomeUsersModel.PendingPlexUserSelection(
                    accountID: account.id,
                    serverName: account.server.name,
                    users: users,
                    isFirstRun: beginsFirstRun,
                    applyToAccountIDs: accounts.map(\.id)
                )
            )
        }
    }

    func removeAccount(id: String) {
        let removedAccount = accountsProviders.accounts.first { $0.id == id }
        let shareAccountKey = mediaShareAccountService.mediaShareAccountKey(
            for: removedAccount
        )
        do {
            try accountStore.remove(id: id)
            plexHomeUsers.forgetAccount(id)
            reloadAccountsAndCrashContext()
            identityIndex.reset()
            identityIndex.warmIdentityIndex()
            guard !accountsProviders.accounts.contains(where: { $0.id == id }) else {
                return
            }
            if let removedAccount {
                mediaShareAccountService.retireCredential(for: removedAccount)
            }
            if let shareAccountKey {
                mediaShareAccountService.invalidate(shareAccountKey: shareAccountKey)
            }
            accountError = nil
        } catch {
            accountError = error.localizedDescription
        }
    }

    @discardableResult
    func addNFSShare(
        host: String,
        port: Int?,
        exportPath: String,
        displayName: String
    ) -> Bool {
        do {
            let prepared = try mediaShareConfigurationService.saveNFS(
                host: host,
                port: port,
                exportPath: exportPath,
                displayName: displayName
            )
            reloadAccountsAndCrashContext()
            identityIndex.warmIdentityIndex()
            preparePostShareOnboarding(prepared)
            accountError = nil
            return true
        } catch {
            accountError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func addSMBShare(
        host: String,
        port: Int?,
        share: String,
        username: String,
        password: String,
        displayName: String
    ) -> Bool {
        do {
            let prepared = try mediaShareConfigurationService.saveSMB(
                host: host,
                port: port,
                share: share,
                username: username,
                password: password,
                displayName: displayName
            )
            reloadAccountsAndCrashContext()
            identityIndex.warmIdentityIndex()
            preparePostShareOnboarding(prepared)
            accountError = nil
            return true
        } catch {
            accountError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func addWebDAVShare(
        baseURL: URL,
        auth: MediaShareWebDAVAuth,
        trustPin: SHA256Fingerprint?,
        displayName: String
    ) -> Bool {
        do {
            let prepared = try mediaShareConfigurationService.saveWebDAV(
                baseURL: baseURL,
                auth: auth,
                trustPin: trustPin,
                displayName: displayName
            )
            reloadAccountsAndCrashContext()
            identityIndex.warmIdentityIndex()
            preparePostShareOnboarding(prepared)
            accountError = nil
            return true
        } catch {
            accountError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func addSFTPShare(
        host: String,
        port: Int?,
        path: String,
        username: String,
        password: String,
        hostKeyPin: SHA256Fingerprint,
        displayName: String
    ) -> Bool {
        do {
            let prepared = try mediaShareConfigurationService.saveSFTP(
                host: host,
                port: port,
                path: path,
                username: username,
                password: password,
                hostKeyPin: hostKeyPin,
                displayName: displayName
            )
            reloadAccountsAndCrashContext()
            identityIndex.warmIdentityIndex()
            preparePostShareOnboarding(prepared)
            accountError = nil
            return true
        } catch {
            accountError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func addFTPShare(
        baseURL: URL,
        auth: MediaShareFTPAuth,
        displayName: String
    ) -> Bool {
        do {
            let prepared = try mediaShareConfigurationService.saveFTP(
                baseURL: baseURL,
                auth: auth,
                displayName: displayName
            )
            reloadAccountsAndCrashContext()
            identityIndex.warmIdentityIndex()
            preparePostShareOnboarding(prepared)
            accountError = nil
            return true
        } catch {
            accountError = error.localizedDescription
            return false
        }
    }

    private func presentLibrarySelection(accountIDs: [String]) {
        let activeIDs = Set(accountsProviders.accounts.map(\.id))
        let available = accountIDs.filter(activeIDs.contains)
        guard !available.isEmpty else {
            beginsFirstRunAfterLibrarySelection = false
            appliesPlexIdentityAfterLibrarySelection = false
            return
        }
        pendingLibrarySelection = PendingLibrarySelection(accountIDs: available)
    }

    private func preparePostShareOnboarding(
        _ prepared: PreparedMediaShareAccount
    ) {
        guard prepared.previousAccount == nil else { return }
        let beginsFirstRun = accountsProviders.accounts.count == 1
            && !profiles.firstRunProfileSetupComplete
        if beginsFirstRun {
            profiles.seedDefaultProfileIdentity(
                name: prepared.session.userName,
                avatarImageURL: prepared.session.avatarURL?.absoluteString
            )
        }

        scheduleLibrarySelection(
            accountIDs: [prepared.account.id],
            beginsFirstRun: beginsFirstRun
        )
    }

    private func scheduleFirstRunStep(_ step: FirstRunStep) {
        Task {
            await Task.yield()
            pendingFirstRunStep = step
        }
    }

    private func schedulePlexUserSelection(
        _ selection: PlexHomeUsersModel.PendingPlexUserSelection
    ) {
        if isManagedServerPresentationActive {
            queuedPlexUserSelection = selection
        } else {
            plexHomeUsers.presentUserSelection(selection)
        }
    }

    private func scheduleLibrarySelection(
        accountIDs: [String],
        beginsFirstRun: Bool = false
    ) {
        guard !accountIDs.isEmpty else { return }
        beginsFirstRunAfterLibrarySelection = beginsFirstRun
        postAddPresentationGeneration &+= 1
        let generation = postAddPresentationGeneration
        if isManagedServerPresentationActive {
            queuedLibraryAccountIDs = accountIDs
            queuedLibrarySelectionBeginsFirstRun = beginsFirstRun
            return
        }
        Task {
            await Task.yield()
            guard generation == postAddPresentationGeneration else { return }
            presentLibrarySelection(accountIDs: accountIDs)
        }
    }
}

private struct PlozziOSMediaShareArtworkCacheLifecycle:
    ShareLocalArtworkCacheLifecycle
{
    func setPreferredAccountKeys(_ accountKeys: Set<String>, revision: UInt64) async {
        await ArtworkImageCache.shared.setPreferredNetworkArtworkAccounts(
            accountKeys,
            revision: revision
        )
    }

    func purge(accountID: String) async {
        await ArtworkImageCache.shared.purgeNetworkArtwork(accountID: accountID)
    }

    func purge(accountID: String, credentialRevision: CredentialRevision) async {
        await ArtworkImageCache.shared.purgeNetworkArtwork(
            accountID: accountID,
            credentialRevision: credentialRevision
        )
    }
}
#endif
