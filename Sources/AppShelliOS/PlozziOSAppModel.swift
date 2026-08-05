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
import FeatureSettings
import FeatureSyncSetup
import FeatureSyncCloud
import FeatureWatchlistCore
import Foundation
import MALService
import MediaDownloads
import MediaTransportCore
import MetadataKit
import Observation
import ProviderShare
import SeerService
import SimklService
import TraktService
import UIKit

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

    /// Every screen of the post-sign-in first-run sequence, in order.
    ///
    /// One enum drives the whole flow so it can live in a SINGLE presentation:
    /// the Plex-user and library steps used to be their own sheets, so handing
    /// off between them dismissed to Home and re-presented. Outside first run
    /// those two screens still present individually (adding a server later is
    /// not a flow), which is why the model only populates this while first-run
    /// setup is actually running.
    enum FirstRunStep: String, Identifiable, CaseIterable {
        case plexUser
        case libraries
        case confirmProfile
        case seerr
        case theme

        var id: Self { self }

        /// Drives the direction of the in-flow transition.
        var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    }

    let accountsProviders: AccountsProvidersModel
    let profiles: ProfilesModel
    /// Generic durable title identity for Plozz-owned profile state.
    let mediaAliasLedger: MediaAliasLedgerModel
    let transientStatusPresenter = TransientStatusPresenter()
    let universalWatchlist: WatchlistModel
    let runtimeFeatureFlags: RuntimeFeatureFlags
    /// Cross-device Sync & Setup (feature-flagged; OFF by default).
    let syncSetup: SyncSetupService

    /// CloudKit "Stage 1" auto-sync of the NON-SECRET household config across this
    /// Apple ID's devices, multiplexed with the durable media identity/state channel
    /// onto the SAME `CKSyncEngine` (Apple permits exactly one active engine per
    /// private database — see `CloudConfigSyncService`'s multiplexing doc comment).
    /// Lazily built so its config<->apply closures can capture `self`. Gated on
    /// `SyncSetupFeatureFlag`; a no-op until enabled. See
    /// `PlozziOSAppModel+CloudSync`.
    @ObservationIgnored
    private(set) lazy var cloudSync: CloudConfigSyncService? = Self.makeCloudSync(for: self)

    /// Debounces bursts of local config edits into a single cloud publish.
    @ObservationIgnored
    var cloudPublishTask: Task<Void, Never>?

    /// Guards against overlapping same-Apple-ID credential auto-adopt attempts.
    @ObservationIgnored
    var isAutoAdoptingSyncSetup = false

    /// A same-Apple-ID device is asking to be set up; drives a one-tap source-side
    /// confirmation before any credential is pushed (nil = no pending offer).
    var pendingSyncSetupOffer: SyncPairingRendezvous?

    /// Servers synced from other devices that this device isn't signed into yet — shown
    /// so the user can sign in / pair to use them here (parity with tvOS).
    var pendingSyncedServers: [SyncedAccountDescriptor] = []

    /// A newly-synced server from another device, queued for a one-time "set it up
    /// here?" prompt (nil = nothing to prompt). Nudged only once per server; drives the
    /// root alert. Parity with tvOS `cloudSyncUI.pendingServerPrompt`.
    var pendingSyncedServerPrompt: SyncedAccountDescriptor?

    /// Offers the user declined this session, so they aren't re-prompted.
    @ObservationIgnored
    var dismissedSyncSetupOfferKeys: Set<String> = []

    /// Observable CloudKit sync status for the Sync & Setup page.
    let cloudSyncStatus = CloudSyncStatus()

    /// Persist a setup received over pairing: create accounts from the descriptors,
    /// store their transferred tokens in the Keychain, and refresh providers so the
    /// device is immediately signed in (no native sign-in needed).
    ///
    /// - Parameter restrictToAccountID: when set (a per-server "set up with other
    ///   device" request), ONLY that account is applied and no profiles/settings are
    ///   imported — even if the source sent the whole household (e.g. an older source,
    ///   or a manual QR/code pairing that couldn't carry the request). This makes the
    ///   receiver the source of truth for its own intent, so a single-server request
    ///   can never silently sign the device into servers it didn't ask for.
    @discardableResult
    func applyReceivedSetup(
        _ received: SyncSetupService.ReceivedSetup,
        restrictToAccountID: String? = nil
    ) -> SyncSetupService.ApplyOutcome {
        // Captured BEFORE markFirstRunProfileSetupComplete below: whether this
        // receiver had already completed setup (used to guard its own default
        // profile from being clobbered by the incoming default).
        let receiverWasConfigured = profiles.firstRunProfileSetupComplete
        // Per-server request → never import profiles (the user only wanted one server).
        let incomingProfiles = restrictToAccountID == nil ? received.config.profiles.map(\.profile) : []
        if !incomingProfiles.isEmpty {
            profiles.importProfiles(incomingProfiles)
        }
        // Reinstall each transferred profile's per-profile settings under the
        // matching namespace on this device (default profile → nil namespace). Skipped
        // entirely for a per-server request (no profiles come along).
        for snap in (restrictToAccountID == nil ? received.config.profileSettings : []) {
            guard let profile = profiles.profiles.first(where: { $0.id == snap.profileID }) else { continue }
            ProfileSettingsTransfer.apply(
                snap.entries,
                namespace: profile.settingsNamespace(isDefault: profiles.isDefault(profile))
            )
        }
        let descByID = Dictionary(received.config.accounts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let secretByID = Dictionary((received.secrets?.accounts ?? []).map { ($0.accountID, $0) }, uniquingKeysWith: { a, _ in a })
        let shareByID = Dictionary((received.secrets?.shares ?? []).map { ($0.accountID, $0) }, uniquingKeysWith: { a, _ in a })
        // Household-wide, so not gated on any per-account authorization — it rides
        // the bundle the user already approved.
        if let seerr = received.secrets?.seerr {
            Self.installSeerrSecretIfAbsent(seerr)
            // The service cached its config at init; reload so a connection that
            // arrived with this pairing is live now, not after the next launch.
            Task { [seerService] in await seerService.reloadConnection() }
        }
        // Track credentialed accounts we ATTEMPT (expected to sign in without a tap)
        // vs those that actually persisted, so the caller can gate success and
        // surface any that failed. Intentional skips (device-local SSH key, no URL)
        // are NOT counted as expected — they were never going to work here.
        var expected = 0, added = 0
        var failedAccountIDs: [String] = []
        for auth in received.application.authorizedAuthorizations
        where restrictToAccountID == nil || auth.id == restrictToAccountID {
            guard let desc = descByID[auth.id] else { continue }
            if let secret = secretByID[auth.id] {
                expected += 1
                let baseURL = desc.candidateBaseURLs.first ?? URL(string: secret.trustedOrigin) ?? URL(string: "https://localhost")!
                let server = MediaServer(id: desc.serverID, name: desc.serverName, baseURL: baseURL,
                                         provider: desc.provider,
                                         connectionURLs: desc.candidateBaseURLs.isEmpty ? nil : desc.candidateBaseURLs)
                let account = Account(id: desc.id, server: server, userID: desc.userID, userName: desc.userName,
                                      avatarURL: desc.avatarURL, deviceID: secret.deviceID)
                do {
                    try accountStore.add(account, token: secret.token)
                    added += 1
                } catch {
                    failedAccountIDs.append(desc.id)
                    PlozzLog.auth.error("Sync setup: failed to add transferred account \(desc.id): \(error.localizedDescription)")
                }
            } else if let share = shareByID[auth.id] {
                // Media share: rebuild the account + reinstall its credential envelope.
                guard let baseURL = desc.candidateBaseURLs.first else {
                    PlozzLog.auth.error("Sync setup: share \(desc.id) has no reachable URL — skipping (re-add it on this device)")
                    continue
                }
                guard let envelope = try? MediaShareCredentialCodec.decodeVersioned(share.credentialEnvelope) else {
                    PlozzLog.auth.error("Sync setup: share \(desc.id) credential envelope failed to decode — skipping")
                    continue
                }
                if case .generatedKey = envelope.authentication {
                    // Defense in depth: an older sender may still ship a generated-key
                    // envelope whose SSH key never travelled. Don't claim success —
                    // leave it for manual re-add (not counted as an expected success).
                    PlozzLog.auth.error("Sync setup: share \(desc.id) uses a device-local SSH key — skipping (re-add it on this device)")
                    continue
                }
                expected += 1
                let server = MediaServer(id: desc.serverID, name: desc.serverName, baseURL: baseURL,
                                         provider: .mediaShare,
                                         connectionURLs: desc.candidateBaseURLs.isEmpty ? nil : desc.candidateBaseURLs)
                let account = Account(id: desc.id, server: server, userID: desc.userID, userName: desc.userName,
                                      avatarURL: desc.avatarURL, deviceID: accountStore.deviceID())
                do {
                    try accountStore.addMediaShare(account, credential: envelope, generatedPrivateKey: nil)
                    added += 1
                } catch {
                    failedAccountIDs.append(desc.id)
                    PlozzLog.auth.error("Sync setup: failed to add transferred share \(desc.id): \(error.localizedDescription)")
                }
            }
        }
        let outcome = SyncSetupService.ApplyOutcome(
            expectedCredentialed: expected, addedCredentialed: added,
            failedAccountIDs: failedAccountIDs, importedProfiles: incomingProfiles.count
        )
        accountsProviders.reloadAccounts()
        // Transactional gate: if we were meant to sign accounts in but NONE stuck,
        // don't declare setup complete — leave the device in onboarding so the
        // caller can show an error and the user can retry. Profiles already imported
        // are harmless and idempotent on retry.
        if outcome.isTotalCredentialFailure {
            reloadAccountsAndCrashContext()
            PlozzLog.auth.error("Sync setup: all \(expected) credentialed account(s) failed to persist — not completing setup")
            return outcome
        }
        // Apply each transferred profile's explicit server membership (which
        // accounts it watches). Filter to accounts present in this transfer, and
        // don't clobber a configured receiver's own default-profile choice — the
        // same guard importProfiles uses so a "bring my setup here" transfer never
        // rewrites an existing device's default.
        let receivedAccountIDs = Set(received.config.accounts.map(\.id))
        for (pid, ids) in (restrictToAccountID == nil ? received.config.profileMemberships : [:]) {
            guard profiles.profiles.contains(where: { $0.id == pid }) else { continue }
            if pid == ProfileStore.defaultProfileID, receiverWasConfigured { continue }
            let usable = ids.filter { receivedAccountIDs.contains($0) }
            // Storing an EMPTY set would read as "this profile chose to watch
            // nothing" and blank its Home. An empty result here just means the
            // sender's servers didn't all come across, which is not a choice the
            // user made — clear the membership instead, which means "watches
            // whatever the household has".
            if usable.isEmpty, !ids.isEmpty {
                profiles.clearActiveAccountIDs(for: pid)
            } else {
                profiles.setActiveAccountIDs(usable, for: pid)
            }
        }
        // Mirror the tvOS receiver: complete first-run so the app never bounces
        // back to onboarding, refresh providers + identity index, and republish
        // presence.
        profiles.markFirstRunProfileSetupComplete()
        reloadAccountsAndCrashContext()
        identityIndex.warmIdentityIndex()
        // Rebuild the active profile's settings model so freshly-applied
        // preferences take effect immediately.
        selectProfile(profiles.activeProfileID)
        // Pairing is an explicit consent to share this household, so turn on
        // cross-device CloudKit sync (idempotent; a no-op if already on).
        setSyncSetupEnabled(true)
        PlozzLog.auth.info("Sync setup applied: added \(added)/\(expected) account(s), \(incomingProfiles.count) profile(s), \(failedAccountIDs.count) failed")
        return outcome
    }
    let authenticatedHTTPResolver: ManagedAuthenticatedHTTPResolver
    let mediaShareRuntime: DefaultMediaShareRuntime
    /// Household-wide metadata provider roles/order override (mirrors tvOS `AppState`).
    /// App-wide like the enrichment pipeline itself, so created once.
    let metadataProviderSettingsModel = MetadataProviderSettingsModel()
    /// Household-wide metadata/artwork cache byte budgets. Device-level, created once.
    let cacheBudgetSettingsModel = CacheBudgetSettingsModel()
    /// Household-wide optional user-supplied TMDB API key (bring-your-own-key). Stored
    /// in the same `com.plozz.app.household` Keychain service as tvOS so the key matches
    /// across platforms.
    let tmdbUserKeyModel: TMDBUserKeyModel
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
    private var backgroundWorkRevision: UInt64 = 0
    private(set) var seriesTrackStore: SeriesTrackPreferenceStore
    private(set) var versionPreferences: VersionPreferenceStore
    private(set) var downloads: PlozziOSDownloadsModel
    private(set) var pendingLibrarySelection: PendingLibrarySelection?
    private(set) var pendingFirstRunStep: FirstRunStep?
    /// A pairing invite captured from a Sync & Setup universal link
    /// (`https://plozz.app/pair#…`). When set, the root presents the pairing send
    /// flow and auto-sends this device's setup to the device that showed the QR.
    var pendingPairingInvite: String?
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
            providerCapabilityResolver: { [unowned self] accountID in
                let provider = accountID.flatMap { id in
                    self.accountsProviders.homeAccounts.first {
                        $0.account.id == id
                    }?.provider
                } ?? self.accountsProviders.homeAccounts.first?.provider
                guard let provider else { return nil }
                return (
                    provider is WatchStateProviding,
                    provider is WatchlistProviding,
                    provider is MetadataRefreshing
                )
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
            },
            universalWatchlistEnabled: { [unowned self] in
                self.runtimeFeatureFlags.isEnabled(.universalWatchlist)
            },
            watchlistMembership: { [unowned self] item in
                self.universalWatchlistMembership(item)
            },
            watchlistMembershipRevision: { [unowned self] in
                self.universalWatchlistMembershipRevision
            },
            performUniversalWatchlist: { [unowned self] adding, item in
                await self.performUniversalWatchlist(
                    adding: adding,
                    item: item
                )
            },
            presentUniversalWatchlistFeedback: {
                [unowned self] icon, text in
                self.transientStatusPresenter.present(
                    icon: icon,
                    text: text
                )
            },
            beginUniversalWatchlistFanOut: {
                [unowned self] adding, item in
                self.beginUniversalWatchlistFanOut(
                    adding: adding,
                    item: item
                )
            },
            resolveDurableWatchlist: { [unowned self] items in
                self.resolvedUniversalWatchlistItems(candidates: items)
            },
            seedLegacyUniversalWatchlist: { [weak self] _ in
                try? await self?.seedLegacyUniversalWatchlist()
            },
            // Downloads are an iOS/iPadOS capability, so only this shell supplies
            // them; tvOS omits both closures and the catalog offers no download
            // actions there. Reads the registry synchronously (it's already loaded
            // in memory) so the menu can be built without awaiting.
            downloadState: { [unowned self] item in
                .some(self.downloads.cachedRecord(forSelectedVersionOf: item)?.menuState)
            },
            performDownloadAction: { [unowned self] action, item in
                Task { await self.performDownloadMenuAction(action, on: item) }
            }
        )

    /// Internal (not private) so the KeychainSync extension in another file can read
    /// tokens / add accounts for iCloud-Keychain auto-connect.
    let accountStore: AccountPersisting
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
    @ObservationIgnored var universalWatchlistReconciler: WatchlistReconciler?
    @ObservationIgnored var universalWatchlistMutationStore: DurableWatchlistMutationStore?
    @ObservationIgnored var universalWatchlistNativeView: NativeWatchlistView = .empty
    @ObservationIgnored var universalWatchlistNativeViewStore:
        (any NativeWatchlistViewStoring)?
    @ObservationIgnored var universalWatchlistDestinationIDs:
        Set<WatchlistDestinationID> = []
    @ObservationIgnored var universalWatchlistProfileID: String?
    @ObservationIgnored var universalWatchlistRetryScheduler:
        WatchlistRetryScheduler?
    @ObservationIgnored var universalWatchlistShouldResumeAuthentication = false
    @ObservationIgnored var universalWatchlistIdentityUpdateTask:
        Task<Void, Never>?
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
            self?.universalWatchlistIdentityDidUpdate()
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
        // Forced when the profile we'd restore is locked, so its content never
        // renders behind the PIN prompt — the unlock then runs through the
        // ordinary `selectProfile(_:)` gate with the picker behind it.
        let requiresLaunchProfileSelection =
            profiles.activeProfile.isLocked
            || (profiles.askProfileOnStartup && profiles.profiles.count > 1)
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
        let tmdbKeyRuntime = mediaShareRuntime
        self.tmdbUserKeyModel = TMDBUserKeyModel(
            store: TMDBUserKeyStore(secureStore: KeychainStore(service: "com.plozz.app.household")),
            validator: { token in await tmdbKeyRuntime.validateTMDBUserKey(token) },
            onCredentialSuperseded: { token in await tmdbKeyRuntime.invalidateTMDBCredential(forToken: token) }
        )
        self.shareScanStatus = shareScanStatus
        self.durableLocalStateStore = durableLocalStateStore
        let aliasStorageDirectory = Self.isRunningUnitTests
            ? nil
            : Self.mediaAliasStorageDirectory()
        self.mediaAliasLedger = MediaAliasLedgerModel(
            durableStore: aliasStorageDirectory == nil ? nil : durableLocalStateStore,
            storageDirectory: aliasStorageDirectory
        )
        self.runtimeFeatureFlags = .productionDefault
        self.universalWatchlist = WatchlistModel(
            storageDirectory: Self.isRunningUnitTests
                ? nil
                : Self.universalWatchlistStorageDirectory()
        )
        self.seerService = seerService
        // A Kids Profile with no mapped Seerr user would otherwise request as the
        // unrestricted admin. Wired as a live closure so it always reflects the
        // CURRENT profile — see `SeerService.refusesAdminRequests`.
        seerService.refusesAdminRequests = { [weak profiles] in
            guard let profiles else { return false }
            return profiles.activeProfile.isKids && profiles.enforcesKidsRestrictions
        }
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
            ? .confirmProfile
            : nil
        self.mediaShareAccountService = MediaShareAccountService(runtime: mediaShareRuntime)
        self.mediaShareConfigurationService = MediaShareAccountConfigurationService(
            accountStore: accountStore
        )
        self.mediaShareRescanService = MediaShareRescanService(
            accountsProviders: accountsProviders
        )
        self.syncSetup = SyncSetupService(
            deviceID: { accountStore.deviceID() },
            deviceName: {
                // UIDevice.name is a generic model name on iOS 16+ without a special
                // entitlement, so recover the owner-given name from the host name
                // ("Brando's iPad" → host "Brandos-iPad") the same way tvOS does.
                // Non-blocking: never reads ProcessInfo.hostName on the main thread
                // (that reverse-DNS call hangs launch + prompts for local network).
                DeviceDisplayName.current(fallback: UIDevice.current.name)
            },
            isConfigured: { !accountsProviders.accounts.isEmpty },
            configProvider: {
                .init(
                    accounts: accountsProviders.accounts,
                    profiles: profiles.profiles,
                    profileSettings: profiles.profiles.map { p in
                        ProfileSettingsSnapshot(
                            profileID: p.id,
                            entries: ProfileSettingsTransfer.capture(
                                namespace: p.settingsNamespace(isDefault: profiles.isDefault(p))
                            )
                        )
                    },
                    // Carry each profile's EXPLICIT server-membership choice (only
                    // profiles that chose one; a profile that never chose is absent,
                    // preserving the unset/empty/subset tri-state on the receiver).
                    profileMemberships: Dictionary(
                        uniqueKeysWithValues: profiles.profiles.compactMap { p in
                            profiles.storedActiveAccountIDs(for: p.id).map { (p.id, $0) }
                        }
                    )
                )
            },
            secretsProvider: { [accountsProviders, accountStore] in
                PlozziOSAppModel.buildSecretsBundle(accounts: accountsProviders.accounts, accountStore: accountStore)
            }
        )
        // Keep the non-secret presence beacon fresh for same-Apple-ID devices.
        self.syncSetup.publishPresence()
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
        accountsProviders.onAccountsInvalidated = { [weak self] in
            self?.mediaItemActionHandler.invalidateAccountCaches()
            self?.universalWatchlistProfileID = nil
            self?.universalWatchlistRetryScheduler = nil
            self?.universalWatchlistShouldResumeAuthentication = true
            Task { await self?.prepareUniversalWatchlist() }
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
        // Self-heal any stale server names (shared path with tvOS).
        accountsProviders.refreshServerNames()
        if !accountsProviders.accounts.isEmpty,
           !profiles.firstRunProfileSetupComplete {
            pendingFirstRunStep = .confirmProfile
        }
        identityIndex.warmIdentityIndex()
        let scanReporter = shareScanStatus.reporter()
        Task { await mediaShareRuntime.configure(reporter: scanReporter) }
        if !requiresLaunchProfileSelection {
            plexHomeUsers.ensurePlexIdentityForActiveProfile()
        }
        drainWatchOutbox()
        // Ordered: the import reads whatever credentials the trackers hold, so
        // it must not start until they point at THIS profile — otherwise it
        // writes the previous profile's watchlist into this one.
        Task { @MainActor in
            await updateTrackersForActiveProfile()
            await prepareUniversalWatchlist()
        }
        applyCrashReportingPreference()
        Task {
            let namespaces = [nil] + profiles.profiles.map { Optional($0.id) }
            await seerService.migrateLegacyConnectionIfNeeded(namespaces: namespaces)
            await seerService.refreshStatus()
        }

        // Bring up CloudKit config auto-sync (no-op unless the Sync & Setup flag is
        // on) and start observing local config changes to publish them.
        self.traktService.onConnectionAvailable = { [weak self] in
            Task { await self?.resumeUniversalWatchlistAuthentication() }
        }
        prepareMediaAliasLedger()
        startCloudSyncIfEnabled()
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
        heroTrailerCache.removeAll()
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

    func setBackgroundWorkAllowed(_ allowed: Bool) {
        backgroundWorkRevision &+= 1
        let revision = backgroundWorkRevision
        Task { [mediaShareRuntime] in
            await mediaShareRuntime.setBackgroundWorkAllowed(allowed, revision: revision)
        }
    }

    /// Media-share account ids signed in on this device. Scopes the Settings
    /// status header so a removed share's late scanner event can't leave a ghost
    /// row. Deliberately NOT the busy states themselves: the header does that
    /// (high-frequency) lookup in its own body so progress ticks can't invalidate
    /// the whole Settings page.
    var mediaShareAccountIDs: Set<String> {
        Set(
            accountsProviders.accounts
                .filter { $0.server.provider == .mediaShare }
                .map(\.id)
        )
    }

    var deviceID: String {
        accountStore.deviceID()
    }

    /// Handle an incoming URL (custom scheme or universal link). Returns true if it
    /// was a recognized Sync & Setup pairing link and has been captured for
    /// presentation via `pendingPairingInvite`.
    @discardableResult
    func handleIncomingURL(_ url: URL) -> Bool {
        guard SyncPairingInvite.decode(url.absoluteString) != nil else { return false }
        // Following a pairing link sends this household's servers, profiles and
        // credentials to the device that produced it, and that device opens in a
        // grown-up profile — so it's withheld inside an enforced Kids Profile.
        guard !managementRequiresParentalPIN else { return false }
        pendingPairingInvite = url.absoluteString
        return true
    }

    /// Debug-only: clear all accounts + profiles so the app returns to the
    /// first-run / onboarding empty state (used to test Sync & Setup receive).
    func resetToFirstRunForDebugging() {
        // Clear cross-device sync state too, so a debug reset is a truly clean slate
        // for re-testing "new server from another device": pull each account's
        // iCloud-Keychain portable credential (stops auto-connect) and wipe the
        // pending/ignored/prompted bookkeeping for synced servers.
        for account in accountsProviders.accounts { removePortableCredential(account.id) }
        var pendingSynced = PendingSyncedServersStore()
        pendingSynced.removeAll()
        var removedSynced = RemovedAccountsStore()
        removedSynced.removeAll()
        HouseholdDevicesStore().removeAll()
        pendingSyncedServers = []
        pendingSyncedServerPrompt = nil
        try? accountStore.clearAll()
        accountsProviders.reloadAccounts()
        plexHomeUsers.resetAllForDebug()
        profiles.resetToPristineDefaultForDebugging()
        pendingLibrarySelection = nil
        pendingFirstRunStep = nil
        pendingPairingInvite = nil
        // Bypass the lock gate deliberately: this is the debug "reset to first
        // run" path and it has just wiped the profiles back to a pristine default.
        performSelectProfile(profiles.activeProfileID)
    }

    /// Everything guarding entry to a profile, in ONE observable property.
    ///
    /// These four are only ever meaningful together — an error without a pending
    /// switch is nonsense, and "the launch picker is satisfied" is the same
    /// question as "did a gated switch complete" — and this model is already over
    /// the observable-fan-out ceiling, so the feature is one property rather than
    /// four. The read-only accessors below keep the call sites reading plainly.
    private(set) var gate = ProfileGate()

    /// The state guarding entry to a profile. See `gate`.
    struct ProfileGate {
        /// A profile waiting on its PIN before it can be opened, or `nil`.
        var lockedSwitch: ParentalSwitchRequest?
        /// A switch out of a Kids Profile, held until the Parental PIN is entered.
        var parentalSwitch: ParentalSwitchRequest?
        /// The enforced Kids Profile the device was moved OUT of without anyone
        /// asking — a local or synced deletion re-points the active profile on
        /// its own. Held until the Parental PIN clears it; see the tvOS twin.
        var parentalFallThrough: Profile?
        /// Whether the launch picker has been satisfied by a switch that actually
        /// completed. See `performSelectProfile`.
        var didCompleteLaunchSelection = false
    }

    /// `PlozziOSRootView` presents the profile-lock PIN screen off this.
    var lockedSwitch: ParentalSwitchRequest? { gate.lockedSwitch }
    /// `PlozziOSRootView` presents the Parental PIN screen off this.
    var parentalSwitch: ParentalSwitchRequest? { gate.parentalSwitch }
    var parentalFallThrough: Profile? { gate.parentalFallThrough }
    var didCompleteLaunchProfileSelection: Bool { gate.didCompleteLaunchSelection }

    /// Whether profile management (add/edit) must be withheld right now: the
    /// household policy plus the fall-through hold.
    var managementRequiresParentalPIN: Bool {
        profiles.managementRequiresParentalPIN || gate.parentalFallThrough != nil
    }
    /// Message from the last failed unlock attempt.

    /// Profiles unlocked during this app run, so hopping back and forth doesn't
    /// re-ask. In-memory on purpose: a cold launch always re-asks.
    private var unlockedProfileIDs: Set<String> = []

    /// Where a newly created profile is in its setup sequence.
    ///
    /// An explicit sequence rather than a handful of overlapping optionals: the
    /// steps are ordered, only one is ever on screen, and "which comes next" is a
    /// single `switch` instead of an invariant spread across five booleans.
    enum ProfileOnboardingStep: String, Identifiable, CaseIterable {
        /// Which servers this profile uses, and who it watches as on each.
        case libraries
        /// Optional household Seerr connection + this profile's acting user.
        case seerr
        /// Its colour scheme, which is per-profile.
        case theme
        /// Whether to put a PIN on it — offered at creation, like on tvOS, since
        /// that's when someone setting up a household profile is thinking about
        /// who should be able to open it.
        case lockOffer

        var id: Self { self }

        var next: ProfileOnboardingStep? {
            switch self {
            case .libraries: .seerr
            case .seerr: .theme
            case .theme: .lockOffer
            case .lockOffer: nil
            }
        }
    }

    /// Which screen puts the setup sequence on screen.
    ///
    /// A cover can only be presented by a view that isn't itself covered, and the
    /// sequence starts from two very different places: creating (or resuming) a
    /// profile from Settings, which is a sheet — so a cover asked for from the
    /// root would be silently dropped — and resuming an abandoned setup at
    /// launch, when Settings isn't open and the Profiles page isn't on screen to
    /// ask from. Both sites are wired up, and this says which one owns it, so
    /// they can never both try.
    enum ProfileOnboardingOrigin {
        case settings
        case launch
    }

    /// Whether the Settings sheet is on screen. Set by the sheet itself.
    private(set) var isSettingsPresented = false

    func noteSettingsPresented(_ presented: Bool) {
        isSettingsPresented = presented
    }

    /// DERIVED from what's actually on screen rather than recorded when the flow
    /// starts. A stored origin has to be written by whoever begins the sequence,
    /// and the resume path — which can begin it too, from either place — had no
    /// way to know which it was; it guessed `.launch`, so resuming an unfinished
    /// profile from Settings asked the covered root to present and the cover
    /// silently never appeared, with the step left set so nothing retried.
    var profileOnboardingOrigin: ProfileOnboardingOrigin {
        isSettingsPresented ? .settings : .launch
    }

    /// Whether `origin` should present the sequence right now.
    func isPresentingProfileOnboarding(from origin: ProfileOnboardingOrigin) -> Bool {
        profileOnboardingStep != nil && profileOnboardingOrigin == origin
    }

    /// The setup step currently being presented, if any.
    private(set) var profileOnboardingStep: ProfileOnboardingStep?
    /// The profile being set up. Held by ID, not by value: the record changes
    /// underneath us as each step writes to it.
    private(set) var profileOnboardingID: String?
    /// Additional identity being added from this profile's "Watching as" page.
    private var pendingAdditionalUser: (serverKey: String, profileID: String)?

    /// The profile the sequence is currently about, read live.
    var profileBeingOnboarded: Profile? {
        guard let profileOnboardingID else { return nil }
        return profiles.profiles.first { $0.id == profileOnboardingID }
    }

    /// Re-presents setup for a profile that never finished it.
    ///
    /// The gate is PERSISTED, so quitting mid-setup leaves it set — and a profile
    /// stuck behind it never imports a watchlist at all, silently and forever.
    /// Resuming asks the question that was never answered: importing anyway is
    /// the leak the gate exists to prevent, and clearing it without asking is the
    /// same thing by another route.
    func resumeProfileOnboardingIfNeeded() {
        // `profileOnboardingID` — not just the step — because creation claims the
        // id and origin synchronously and only raises the step a runloop turn
        // later (so the editor sheet can close first). Switching into the new
        // profile schedules a resume in that same window; guarding on the step
        // alone let the resume win the race and relabel a `.settings` flow as
        // `.launch`, so the cover was asked for from the root while Settings was
        // still up — and silently never appeared. Exactly what the origin split
        // exists to prevent.
        guard profileOnboardingStep == nil, profileOnboardingID == nil else { return }
        guard profiles.activeProfile.needsSetup else { return }
        profileOnboardingID = profiles.activeProfileID
        profileOnboardingStep = .libraries
    }

    /// Advances to the next setup step, releasing the watchlist import when the
    /// server/identity step is finished.
    func advanceProfileOnboarding() {
        guard let step = profileOnboardingStep, let id = profileOnboardingID else { return }
        if step == .libraries {
            // Only NOW — with this profile's servers and identity settled — is an
            // import meaningful. Until `finishSetup` clears the gate the profile
            // holds every server it inherited, and importing against that pulls
            // the household's aggregate watchlist into it.
            if profiles.finishSetup(for: id) {
                Task { @MainActor in
                    await updateTrackersForActiveProfile()
                    await prepareUniversalWatchlist()
                }
            }
        }
        if let next = step.next {
            profileOnboardingStep = next
        } else {
            profileOnboardingStep = nil
            profileOnboardingID = nil
        }
    }

    /// Ends setup early (the cover was swiped away). The gate still has to be
    /// released, or the profile would never import a watchlist at all.
    func cancelProfileOnboarding() {
        guard let id = profileOnboardingID else { return }
        if profiles.finishSetup(for: id) {
            Task { @MainActor in
                await updateTrackersForActiveProfile()
                await prepareUniversalWatchlist()
            }
        }
        profileOnboardingStep = nil
        profileOnboardingID = nil
    }

    /// The Plex account this profile has just enabled and not yet picked a user
    /// on. The Libraries screen presents the picker from this.
    ///
    /// Read from the PROFILE, not from memory: the question has to outlive a
    /// relaunch, because the enabled-but-unidentified server does. See
    /// `Profile.accountsAwaitingIdentity`.
    var pendingIdentityAccount: Account? {
        guard let id = profiles.actionableIdentityAccountIDs(
            forProfile: profiles.activeProfileID,
            importAccountIDs: ProfileServerIdentityPolicy
                .importPlexAccountIDs(
                    in: NativeWatchlistAccounts.resolve(
                        profiles: profiles,
                        accountsProviders: accountsProviders
                    )
                )
        ).first else { return nil }
        return accounts.first { $0.id == id }
    }

    private func noteServerAwaitingIdentity(_ accountID: String, profileID: String) {
        guard let account = accounts.first(where: { $0.id == accountID }),
              var profile = profiles.profiles.first(where: { $0.id == profileID }),
              ProfileServerIdentityPolicy.shouldAsk(
                  provider: account.server.provider,
                  hasExistingBinding: profile.homeUserBinding(forPlexAccount: accountID) != nil
              ),
              profile.noteAccountAwaitingIdentity(accountID)
        else { return }
        profiles.update(profile)
    }

    /// Closes whichever question is on screen (the sheet was swiped away, or
    /// Done was tapped).
    func resolveIdentityPromptForPending() {
        guard let account = pendingIdentityAccount else { return }
        concludeIdentityPrompt(for: account.id)
    }

    /// Closes the question according to what the person actually did.
    ///
    /// The iOS sheet has no separate decline button — picking a user writes the
    /// binding, and Done or a swipe closes it either way. So the binding is the
    /// answer: with one, the question is answered; without one, nobody said who
    /// this profile is, and reading the server as its OWNER is the outcome the
    /// question exists to prevent. Closing used to mean the latter silently.
    func concludeIdentityPrompt(for accountID: String) {
        let hasBinding = profiles.activeProfile
            .homeUserBinding(forPlexAccount: accountID) != nil
        if hasBinding {
            resolveIdentityPrompt(for: accountID)
        } else {
            declineIdentityPrompt(for: accountID)
        }
    }

    /// Clears the question once a user is chosen.
    func resolveIdentityPrompt(for accountID: String) {
        applyIdentityAnswer(for: accountID) {
            $0.resolveAccountAwaitingIdentity(accountID)
        }
    }

    /// Records that nobody said who this profile is on this server, so its own
    /// watchlist is left alone. See `Profile.watchlistDeclinedAccountIDs`.
    func declineIdentityPrompt(for accountID: String) {
        applyIdentityAnswer(for: accountID) {
            $0.declineAccountWatchlist(accountID)
        }
    }

    private func applyIdentityAnswer(
        for accountID: String,
        _ apply: (inout Profile) -> Bool
    ) {
        let profileID = profiles.activeProfileID
        guard var profile = profiles.profiles.first(where: { $0.id == profileID }),
              apply(&profile)
        else { return }
        profiles.update(profile)
        // The import was deferred while this was outstanding; with the answer in
        // it can finally run, against the identity that was just chosen.
        guard !profile.needsSetup, profiles.actionableIdentityAccountIDs(
            forProfile: profile.id,
            importAccountIDs: ProfileServerIdentityPolicy
                .importPlexAccountIDs(
                    in: NativeWatchlistAccounts.resolve(
                        profiles: profiles,
                        accountsProviders: accountsProviders
                    )
                )
        ).isEmpty else { return }
        Task { @MainActor in
            await updateTrackersForActiveProfile()
            await prepareUniversalWatchlist()
        }
    }

    /// Whether the profile that is already active is locked and unproven — the
    /// backstop for paths that make a profile active without going through
    /// `selectProfile(_:)` (a synced deletion re-pointing at `profiles.first`).
    var activeProfileNeedsUnlock: Bool {
        let active = profiles.activeProfile
        return active.isLocked && !unlockedProfileIDs.contains(active.id)
    }

    /// Switches to `id`, unless it's locked and unproven this run — in which case
    /// the PIN prompt is raised and nothing is re-scoped until it's satisfied.
    ///
    /// The lock rides the synced profile record, so a profile locked on the Apple
    /// TV arrives here locked too; without this gate it would open with one tap
    /// and the lock would be worthless.
    func selectProfile(_ id: String) {
        guard let target = profiles.profiles.first(where: { $0.id == id }) else {
            performSelectProfile(id)
            return
        }
        // May you leave? Walking out of a Kids Profile needs the household
        // Parental PIN, and is checked before the target's own lock — same order
        // as tvOS, from the same shared policy on `ProfilesModel`.
        // The hold wins over `activeProfile`: after an involuntary fall-through
        // the active profile is already the grown-up one, so asking it whether we
        // may leave a Kids Profile answers "there is no Kids Profile here".
        if profiles.requiresParentalPIN(
            switchingFrom: gate.parentalFallThrough ?? profiles.activeProfile,
            to: target
        ) {
            gate.parentalSwitch = ParentalSwitchRequest(target: target)
            return
        }
        continueSelect(target)
    }

    /// The switch past the parental gate, still subject to the target's own lock.
    private func continueSelect(_ target: Profile) {
        if target.isLocked, !unlockedProfileIDs.contains(target.id) {
            gate.lockedSwitch = ParentalSwitchRequest(target: target)
            return
        }
        performSelectProfile(target.id)
    }

    /// Checks `pin` against the household Parental PIN and lets the held switch
    /// continue. Deliberately not remembered for the run — see the tvOS twin.
    @discardableResult
    func submitParentalPIN(_ pin: String) -> Bool {
        guard let target = gate.parentalSwitch?.target else { return false }
        guard profiles.matchesParentalPIN(pin) else {
            gate.parentalSwitch?.error = ProfileLockCopy.incorrectPIN
            return false
        }
        gate.parentalSwitch = nil
        continueSelect(target)
        return true
    }

    /// Abandons a held switch, leaving the child where they were.
    func cancelParentalSwitch() {
        // Deliberately does NOT clear `parentalFallThrough`: cancelling a switch
        // the child never asked for must not hand them the profile they were
        // dropped into.
        gate.parentalSwitch = nil
    }

    /// Checks `pin` against the pending profile's lock, completing the held-back
    /// switch on a match.
    @discardableResult
    func submitProfileLockPIN(_ pin: String) -> Bool {
        guard let profile = gate.lockedSwitch?.target, let lock = profile.lock else { return false }
        guard lock.matches(pin: pin) else {
            gate.lockedSwitch?.error = ProfileLockCopy.incorrectPIN
            return false
        }
        unlockedProfileIDs.insert(profile.id)
        gate.lockedSwitch = nil
        if lock.matchesPlexPIN {
            plexHomeUsers.prefillPlexPIN(pin, forProfile: profile.id)
        }
        performSelectProfile(profile.id)
        return true
    }

    /// Abandons a pending unlock, leaving the active profile untouched.
    func cancelProfileLockPrompt() {
        gate.lockedSwitch = nil
    }

    /// Sets or clears a profile's PIN gate, dropping any unlock credit the
    /// previous PIN granted.
    func setLock(_ lock: ProfileLock?, forProfile id: String) {
        guard var profile = profiles.profiles.first(where: { $0.id == id }) else { return }
        profile.replaceLock(with: lock)
        profiles.update(profile)
        // Drop any unlock the OLD PIN granted, then re-grant it when a new PIN
        // was just chosen: whoever typed it demonstrably knows it.
        unlockedProfileIDs.remove(id)
        if lock != nil { unlockedProfileIDs.insert(id) }
    }

    /// Whether a profile's PIN has been proved this run, so a locked profile's
    /// settings stay sealed until someone enters it.
    func isUnlockedThisRun(_ id: String) -> Bool {
        unlockedProfileIDs.contains(id)
    }

    /// Records that a profile's PIN was proved outside `submitProfileLockPIN` —
    /// e.g. to edit it. Knowing the PIN is knowing the PIN.
    func noteUnlocked(_ id: String) {
        unlockedProfileIDs.insert(id)
    }

    /// Marks a profile as restricted, or lifts the restriction.
    func setKidsProfile(_ isKids: Bool, forProfile id: String) {
        guard var profile = profiles.profiles.first(where: { $0.id == id }) else { return }
        profile.isKids = isKids
        profiles.update(profile)
    }

    /// Forces the profile picker with no way past it.
    ///
    /// The iOS counterpart of tvOS's non-cancelable `isChoosingProfile`. The PIN
    /// cover alone isn't a gate: it has a Cancel button, and cancelling it while
    /// a locked profile is already active simply reveals that profile. The picker
    /// behind it is what makes cancelling harmless — there's nothing to cancel
    /// *into*.
    private(set) var mustChooseProfile = false

    /// Raises the PIN gate if the profile that just became active is locked and
    /// unproven this run.
    ///
    /// `selectProfile(_:)` gates the deliberate route, but the store also
    /// re-points `activeProfileID` on its own — deleting the active profile falls
    /// through to whichever is left, and a deletion arriving over sync does the
    /// same with no user action at all. Landing that way skipped the gate
    /// entirely, so deleting a profile could drop you straight inside a locked
    /// one. The prompt has no "cancel into the profile" path: dismissing it
    /// returns to the picker.
    /// - Returns: `true` when the gate was raised, meaning the caller must NOT
    ///   go on to scope this profile in — applying its Plex identity or importing
    ///   its watchlist before anyone has proved the PIN is most of what the lock
    ///   is supposed to withhold.
    /// - Parameter leaving: the profile that was active before the fall-through,
    ///   when the caller knows it. A deleted Kids Profile drops the device into
    ///   whatever profile is left — a route out of the child's profile that never
    ///   passes `selectProfile`'s parental gate. The lock check below can't catch
    ///   it, because the whole point of the Parental PIN is that grown-up
    ///   profiles no longer need individual locks.
    @discardableResult
    func enforceActiveProfileLock(leaving outgoing: Profile? = nil) -> Bool {
        if let outgoing,
           profiles.requiresParentalPIN(switchingFrom: outgoing, to: profiles.activeProfile) {
            // Held for the whole episode, not just this call: `activeProfile` is
            // already the grown-up, so every predicate derived from it would
            // stand aside — including the picker's Add/Edit gate.
            gate.parentalFallThrough = outgoing
            mustChooseProfile = true
            gate.parentalSwitch = ParentalSwitchRequest(target: profiles.activeProfile)
            return true
        }
        guard activeProfileNeedsUnlock else { return false }
        mustChooseProfile = true
        gate.lockedSwitch = ParentalSwitchRequest(target: profiles.activeProfile)
        return true
    }

    func performSelectProfile(_ id: String) {
        universalWatchlistRetryScheduler = nil
        profiles.select(id)
        // `select` NO-OPS for an id this device doesn't have — a peer can delete
        // a profile between the picker rendering and the tap, which is exactly
        // the fall-through case. Releasing the hold and lifting the forced picker
        // on a switch that never happened would leave the child in the grown-up
        // profile the gate exists to withhold, so everything below is conditional
        // on the switch having actually landed.
        guard profiles.activeProfileID == id else { return }
        // Past both gates, so the hold has done its job. Released here rather
        // than on PIN success so that switching into another Kids Profile (which
        // needs no PIN) also releases it.
        gate.parentalFallThrough = nil
        // The launch picker is satisfied by an ACTUAL switch, never by the tap
        // that merely asked for one: tapping a locked profile only raises its
        // PIN, so marking completion at the tap let a cancel fall straight
        // through into the profile the lock was protecting.
        gate.didCompleteLaunchSelection = true
        // Reached only past the lock gate, so this is where the forced picker
        // lifts: a profile has been chosen and proved.
        mustChooseProfile = false
        // Switching INTO a profile that never finished setup — abandoned here, or
        // created on another device and synced across — asks the question again
        // rather than leaving it permanently unable to import. Deferred by a
        // runloop turn for the same reason creation is: this can run from inside
        // a sheet that has to close first.
        Task { @MainActor in
            await Task.yield()
            resumeProfileOnboardingIfNeeded()
        }
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
        drainWatchOutbox()
        // Ordered: the import reads whatever credentials the trackers hold, so
        // it must not start until they point at THIS profile — otherwise it
        // writes the previous profile's watchlist into this one.
        Task { @MainActor in
            await updateTrackersForActiveProfile()
            await prepareUniversalWatchlist()
        }
        Task { await seerService.setActiveProfile(namespace: profiles.activeNamespace) }
    }

    /// Re-points every tracker at the active profile's namespace.
    ///
    /// `async` rather than fire-and-forget: each `setActiveProfile` suspends, so
    /// a detached Task flipped the namespaces one at a time with real suspension
    /// points between them — long enough for the watchlist import to read a
    /// tracker still pointing at the previous profile and write its watchlist
    /// into the new one. See the matching note in `AppState`.
    /// The namespace every tracker is currently pointed at, once scoped.
    /// `.some(nil)` is a real value — the default profile uses a `nil` namespace.
    private var trackerScopedNamespace: String??

    /// See `UniversalWatchlistHost.ensureTrackersScopedToActiveProfile()`.
    func ensureTrackersScopedToActiveProfile() async {
        let ns = profiles.activeNamespace
        if let scoped = trackerScopedNamespace, scoped == ns { return }
        await updateTrackersForActiveProfile()
    }

    private func updateTrackersForActiveProfile() async {
        let namespace = profiles.activeNamespace
        trackerProfileGeneration &+= 1
        let generation = trackerProfileGeneration
        guard generation == trackerProfileGeneration else { return }
        await traktService.setActiveProfile(namespace: namespace)
        guard generation == trackerProfileGeneration else { return }
        await simklService.setActiveProfile(namespace: namespace)
        guard generation == trackerProfileGeneration else { return }
        await anilistService.setActiveProfile(namespace: namespace)
        guard generation == trackerProfileGeneration else { return }
        await malService.setActiveProfile(namespace: namespace)
        guard generation == trackerProfileGeneration else { return }
        trackerScopedNamespace = .some(namespace)
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
            additionalSources: identityIndex.identitySourcesProvider(item),
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
            // The eager identity index's known servers for this title. Without
            // it the fan-out only covers the item's own `sources`, so a title
            // reached from a Home row that only one server populated never gets
            // marked played on the OTHER servers that also have it — silent,
            // invisible data loss. tvOS has always passed this.
            additionalSources: identityIndex.identitySourcesProvider(item),
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
    /// - Parameter isKids: whether a NEWLY created profile is a Kids Profile.
    ///   Ignored when editing, where the flag is owned by the profile's own
    ///   settings page. Matches the tvOS picker, which has always been able to
    ///   create one directly.
    func saveProfile(_ draft: ProfileDraft, isKids: Bool = false) {
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
            // Created AWAITING SETUP, exactly as on tvOS. A new profile inherits
            // every server, so importing a watchlist before the user has said
            // which servers it uses — and who it watches as on them — drops the
            // household's aggregate watchlist into it. `addAwaitingSetup` gates
            // the import until `advanceProfileOnboarding` releases it.
            let created = profiles.addAwaitingSetup(
                draft,
                isKids: isKids,
                activeAccountIDs: accounts.map(\.id)
            )
            // Claimed BEFORE the switch: `performSelectProfile` schedules a
            // deferred resume, and this new profile does need setup, so without
            // the claim already in place that resume would take the flow over and
            // present it from the wrong place. See `resumeProfileOnboardingIfNeeded`.
            profileOnboardingID = created.id
            performSelectProfile(created.id)
            // Yielded, not set inline: this runs from inside the Add Profile
            // sheet, and SwiftUI drops a presentation requested while another is
            // still dismissing. One runloop turn lets the editor close first —
            // the same reason `scheduleFirstRunStep` yields.
            Task { @MainActor in
                await Task.yield()
                profileOnboardingStep = .libraries
            }
        }
    }

    func removeProfile(_ id: String) {
        universalWatchlistRetryScheduler = nil
        let previousActiveProfileID = profiles.activeProfileID
        let outgoingProfile = profiles.activeProfile
        removeMediaAliases(forProfileID: id)
        profiles.remove(id)
        watchReconcilers[id] = nil
        if profiles.activeProfileID != previousActiveProfileID {
            // Deleting the active profile falls the selection through to whatever
            // is left, which can be a LOCKED profile — a route into it that never
            // passes `selectProfile`'s gate. Stop here if so: re-scoping,
            // re-pointing the Plex identity and importing that profile's
            // watchlist is most of what the lock is meant to withhold, and doing
            // it first would mean the PIN only hid a profile that was already
            // open behind it.
            if enforceActiveProfileLock(leaving: outgoingProfile) {
                reloadAccountsAndCrashContext()
                return
            }
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
        drainWatchOutbox()
        // Ordered: the import reads whatever credentials the trackers hold, so
        // it must not start until they point at THIS profile — otherwise it
        // writes the previous profile's watchlist into this one.
        Task { @MainActor in
            await updateTrackersForActiveProfile()
            await prepareUniversalWatchlist()
        }
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
        if profiles.activeProfileID == profileID {
            return accountsProviders.activeAccountIDs
        }
        return Set(
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
        // Noted BEFORE the reload below, which schedules a watchlist import: the
        // whole point is that the import waits for the answer, and a note taken
        // after it has already been scheduled is too late.
        if enabled {
            noteServerAwaitingIdentity(accountID, profileID: profileID)
        } else {
            // Switched back off — there's nothing left to be anyone on, and an
            // unanswerable question would gate the import forever.
            resolveIdentityPrompt(for: accountID)
        }
        if profiles.activeProfileID == profileID {
            // The account set drives what's on screen, so this stays synchronous.
            reloadAccountsAndCrashContext()
            // Everything else is bookkeeping, and it was running in the same
            // turn as the toggle — blocking the main actor long enough that the
            // switch's own animation dropped frames and the expanding card
            // appeared to jump. Yield first so the UI settles, then catch up.
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self else { return }
                self.identityIndex.reset()
                self.identityIndex.warmIdentityIndex()
                self.drainWatchOutbox()
            }
        }
    }

    func persist(_ sessions: [UserSession]) {
        do {
            let existingIDs = Set(accountsProviders.accounts.map(\.id))
            let isFirstRun = existingIDs.isEmpty
                && !profiles.firstRunProfileSetupComplete
            var addedAccounts: [Account] = []
            for session in sessions {
                let account = Account(id: Account.stableID(for: session), from: session)
                try accountStore.add(account, token: session.accessToken)
                // A (re)added server clears any household-removal tombstone for it.
                clearRemovalTombstone(for: account.id)
                if !existingIDs.contains(account.id) {
                    addedAccounts.append(account)
                }
            }
            let completesAdditionalIdentity = pendingAdditionalUser.map { pending in
                addedAccounts.contains {
                    $0.server.provider.usesMediaBrowserAPI
                        && $0.server.identityKey == pending.serverKey
                }
            } ?? false
            accountError = nil
            reloadAccountsAndCrashContext()
            selectNewlyAddedUserIfNeeded(from: addedAccounts)
            identityIndex.warmIdentityIndex()
            if isFirstRun,
               let session = sessions.first(where: {
                   let account = Account(id: Account.stableID(for: $0), from: $0)
                   return addedAccounts.contains(where: { $0.id == account.id })
               }) {
                profiles.seedDefaultProfileIdentity(
                    name: session.userName,
                    avatarImageURL: session.avatarURL?.absoluteString
                )
            }
            if !completesAdditionalIdentity {
                preparePostSignInOnboarding(
                    for: addedAccounts,
                    beginsFirstRun: isFirstRun && !addedAccounts.isEmpty
                )
            }
        } catch {
            accountError = error.localizedDescription
        }
    }

    func beginAddingUser(on server: MediaServer) {
        pendingAdditionalUser = (
            serverKey: server.identityKey,
            profileID: profiles.activeProfileID
        )
        beginManagedServerPresentation()
    }

    private func selectNewlyAddedUserIfNeeded(from addedAccounts: [Account]) {
        guard let pendingAdditionalUser,
              let account = addedAccounts.last(where: {
                  $0.server.identityKey == pendingAdditionalUser.serverKey
              })
        else { return }

        var selected = activeAccountIDs(for: pendingAdditionalUser.profileID)
        for existing in accountsProviders.accounts
        where existing.server.identityKey == pendingAdditionalUser.serverKey {
            selected.remove(existing.id)
        }
        selected.insert(account.id)
        profiles.setActiveAccountIDs(
            Array(selected),
            for: pendingAdditionalUser.profileID
        )
        watchReconcilers[pendingAdditionalUser.profileID] = nil
        reloadAccountsAndCrashContext()
        self.pendingAdditionalUser = nil
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
            // Mirrors schedulePlexUserSelection: this drain path bypasses it,
            // so it has to enter the flow itself or the step would present as a
            // bare sheet outside the cover.
            if selection.isFirstRun { pendingFirstRunStep = .plexUser }
        } else if let accountIDs = queuedLibraryAccountIDs {
            let beginsFirstRun = queuedLibrarySelectionBeginsFirstRun
            queuedLibraryAccountIDs = nil
            queuedLibrarySelectionBeginsFirstRun = false
            scheduleLibrarySelection(
                accountIDs: accountIDs,
                beginsFirstRun: beginsFirstRun
            )
        }
        // A dismissed add-user sheet must not make a later unrelated sign-in
        // auto-select itself for this profile.
        pendingAdditionalUser = nil
    }

    func completeLibrarySelection() {
        pendingLibrarySelection = nil
        if beginsFirstRunAfterLibrarySelection {
            beginsFirstRunAfterLibrarySelection = false
            // Already inside the flow cover, so advance in place. Going through
            // scheduleFirstRunStep would yield a runloop turn to let a sheet
            // dismiss first — which is exactly the gap that flashed Home.
            advanceFirstRunStep(to: .confirmProfile)
        } else if appliesPlexIdentityAfterLibrarySelection {
            appliesPlexIdentityAfterLibrarySelection = false
            plexHomeUsers.ensurePlexIdentityForActiveProfile()
        }
    }

    func confirmFirstRunProfile() {
        advanceFirstRunStep(to: .seerr)
    }

    func completeFirstRunSeerrSetup() {
        advanceFirstRunStep(to: .theme)
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
            // The "who are you here?" question is persisted and gates the
            // watchlist import. With the account gone nothing can ask it, so an
            // entry left behind would defer every future import forever. Cleared
            // BEFORE the reload, which is what re-triggers preparation. See
            // `withdrawIdentityQuestions(forAccount:)`.
            profiles.withdrawIdentityQuestions(forAccount: id)
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
            // Drop this device's iCloud-Keychain portable credential for the account,
            // so a deleted server doesn't silently auto-reconnect on the next launch
            // (and isn't re-offered to the user's other devices). Without this, sync's
            // auto-connect immediately re-adds the account the user just removed.
            removePortableCredential(id)
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
            let wasFirstRun = beginsFirstRunAfterLibrarySelection
            beginsFirstRunAfterLibrarySelection = false
            appliesPlexIdentityAfterLibrarySelection = false
            // Nothing to choose from. Previously this just meant no sheet
            // appeared; now the flow is already on screen, so it has to be moved
            // on or it would sit on a step that can never complete.
            if wasFirstRun { advanceFirstRunStep(to: .confirmProfile) }
            return
        }
        pendingLibrarySelection = PendingLibrarySelection(accountIDs: available)
        if beginsFirstRunAfterLibrarySelection { pendingFirstRunStep = .libraries }
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

    /// Move to `step` within the already-presented flow. Unlike
    /// `scheduleFirstRunStep` this never yields, because nothing has to be
    /// dismissed first — the cover is already on screen.
    private func advanceFirstRunStep(to step: FirstRunStep) {
        guard !profiles.firstRunProfileSetupComplete else { return }
        pendingFirstRunStep = step
    }

    private func scheduleFirstRunStep(_ step: FirstRunStep) {
        // Don't start (or re-start) first-run onboarding if the household is already
        // set up — e.g. profiles arrived via sync on a fresh device. Guards against a
        // "use profiles?"/theme prompt when the user already has profiles.
        guard !profiles.firstRunProfileSetupComplete else { return }
        Task {
            await Task.yield()
            pendingFirstRunStep = step
        }
    }

    /// Dismiss any queued first-run onboarding step once the household is known to be
    /// already set up (e.g. profiles arrived via sync after a race queued the step).
    /// Lives here (not the CloudSync extension) so it can touch `private(set)` state.
    func clearFirstRunStepIfHouseholdSetUp() {
        if pendingFirstRunStep != nil, profiles.firstRunProfileSetupComplete {
            pendingFirstRunStep = nil
        }
    }

    private func schedulePlexUserSelection(
        _ selection: PlexHomeUsersModel.PendingPlexUserSelection
    ) {
        if isManagedServerPresentationActive {
            queuedPlexUserSelection = selection
        } else {
            plexHomeUsers.presentUserSelection(selection)
            // First run renders this step inside the flow cover; the standalone
            // sheet stays for the later add-a-server case.
            if selection.isFirstRun { pendingFirstRunStep = .plexUser }
        }
    }

    private func scheduleLibrarySelection(
        accountIDs: [String],
        beginsFirstRun: Bool = false
    ) {
        guard !accountIDs.isEmpty else {
            // Same dead-end guard as presentLibrarySelection: don't strand a
            // presented flow on a step with nothing in it.
            if beginsFirstRun { advanceFirstRunStep(to: .confirmProfile) }
            return
        }
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
