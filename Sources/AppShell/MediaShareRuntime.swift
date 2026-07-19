import Foundation
import CoreModels
import CoreUI
import FeatureAuth
import MediaTransportCore
import MetadataKit
import ProviderShare
import EnginePlozzigen

final class MetadataEnrichmentConfigCache: @unchecked Sendable {
    private let baseline: MetadataEnrichmentConfig
    private let settingsStore: any MetadataProviderSettingsStoring
    private let center: NotificationCenter
    private let lock = NSLock()
    private var cached: MetadataEnrichmentConfig
    private var observer: NSObjectProtocol?

    init(
        baseline: MetadataEnrichmentConfig,
        settingsStore: any MetadataProviderSettingsStoring,
        center: NotificationCenter = .default
    ) {
        self.baseline = baseline
        self.settingsStore = settingsStore
        self.center = center
        self.cached = baseline.merged(withUserOverrides: settingsStore.load())
        self.observer = center.addObserver(
            forName: .metadataProviderSettingsDidChange,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.reload()
        }
    }

    deinit {
        if let observer {
            center.removeObserver(observer)
        }
    }

    func value() -> MetadataEnrichmentConfig {
        lock.lock()
        defer { lock.unlock() }
        return cached
    }

    private func reload() {
        let updated = baseline.merged(withUserOverrides: settingsStore.load())
        lock.lock()
        cached = updated
        lock.unlock()
    }
}

/// The atomic, app-wide ownership bundle for one media-share runtime
/// generation. It ties together the single share catalog coordinator used by
/// both catalog providers and playback leases, the transport composition
/// (adapters + resolver registry), and the network-file resolver — so no caller
/// can pair a coordinator from one generation with a resolver/registry from
/// another (the split-brain E3 targets).
///
/// `AppState` owns exactly one of these and forwards every media-share concern
/// (provider registration, scan reporter wiring, playback lease, credential
/// retirement, account invalidation, preferred-account priority) to it, rather
/// than storing the pieces independently. Tests inject one complete fake runtime
/// instead of assembling registry A + resolver B + coordinator C by hand.
public protocol MediaShareRuntime: Sendable {
    /// The network-file resolver used for direct-file playback of share media.
    var networkFileResolver: any MediaTransportNetworkFileResolving { get }

    /// Registers the `.mediaShare` provider factory into the supplied registry,
    /// wiring each resolved provider to this runtime's coordinator, transport
    /// composition, and network-file resolver.
    func registerProvider(
        into registry: ProviderRegistry,
        durableLocalStateStore: DurableLocalStateStore?
    )

    /// Wires the scan/enrich progress reporter into the coordinator's scanners
    /// and enrichers.
    func configure(reporter: ShareScanReporter) async

    /// Invalidates all cached catalog/scan/playback state for one account key
    /// (used when the account is removed).
    func invalidate(accountKey: String) async

    /// Retires the transport sessions bound to one account's credential
    /// revision (used on credential rotation and account removal).
    func retire(accountID: String, credentialRevision: CredentialRevision) async

    /// Updates the active profile's preferred media-share account keys so their
    /// passive backlog drains before work retained for other profiles.
    func setPreferredAccountKeys(_ accountKeys: Set<String>, revision: UInt64) async

    /// A point-in-time snapshot of the metadata enrichment subsystem for the Step 6
    /// Settings "Diagnostics" section (per-source counts, cache bytes, breaker state,
    /// scan/queue status). Default: an empty snapshot (test fakes need not implement).
    func metadataDiagnosticsSnapshot() async -> MetadataEnrichmentDiagnosticsSnapshot

    /// Applies the user's cache budgets to the metadata + derived-artwork caches,
    /// evicting immediately (Step 6). Default: no-op.
    func applyCacheBudgets(_ settings: CacheBudgetSettings) async

    /// Clears the resolved-URL metadata cache and the derived-artwork cache
    /// (Step 6 "Clear cache now"). Default: no-op.
    func clearMetadataCaches() async

    /// Verifies a user's TMDB BYOK token against TMDb over the resilient HTTP path
    /// (Step 9), recording the outcome into that key's circuit breaker. Default:
    /// `.unreachable` (test fakes need not implement).
    func validateTMDBUserKey(_ token: String) async -> TMDBKeyValidationResult

    /// Clears the shared cache + breaker state for a superseded TMDB key (Step 9),
    /// invoked when a user replaces or removes their key. Default: no-op.
    func invalidateTMDBCredential(forToken token: String) async
}

public extension MediaShareRuntime {
    func metadataDiagnosticsSnapshot() async -> MetadataEnrichmentDiagnosticsSnapshot {
        MetadataEnrichmentDiagnosticsSnapshot()
    }
    func applyCacheBudgets(_ settings: CacheBudgetSettings) async {}
    func clearMetadataCaches() async {}
    func validateTMDBUserKey(_ token: String) async -> TMDBKeyValidationResult { .unreachable }
    func invalidateTMDBCredential(forToken token: String) async {}
}

/// The single production `MediaShareRuntime`. Construct it only through
/// ``make(accountStore:)`` — that is the one default construction path the
/// Batch 11 gate requires.
final class DefaultMediaShareRuntime: MediaShareRuntime {
    private let coordinator: ShareCatalogCoordinator
    private let composition: MediaShareTransportComposition
    private let artworkCacheLifecycle: any ShareLocalArtworkCacheLifecycle
    /// The shared provider runtime (result cache + per-source breakers) the pipeline
    /// runs on, retained so diagnostics can sample it (Step 6).
    private let providerRuntime: MetadataProviderRuntime
    /// The same per-build TMDb access resolver the pipeline uses (Step 9), so diagnostics
    /// can report the breaker for the *active* credential (a user's BYOK key) rather than
    /// the unused built-in one.
    private let providerConfig: @Sendable () -> MetadataProviderConfig
    let networkFileResolver: any MediaTransportNetworkFileResolving

    private init(
        coordinator: ShareCatalogCoordinator,
        composition: MediaShareTransportComposition,
        artworkCacheLifecycle: any ShareLocalArtworkCacheLifecycle,
        providerRuntime: MetadataProviderRuntime,
        providerConfig: @escaping @Sendable () -> MetadataProviderConfig,
        networkFileResolver: any MediaTransportNetworkFileResolving
    ) {
        self.coordinator = coordinator
        self.composition = composition
        self.artworkCacheLifecycle = artworkCacheLifecycle
        self.providerRuntime = providerRuntime
        self.providerConfig = providerConfig
        self.networkFileResolver = networkFileResolver
    }

    /// The one default construction path: a fresh coordinator, the media-share
    /// transport composition, and a network-file resolver whose playback lease
    /// comes from that same coordinator and whose session key comes from that
    /// same composition. Nothing outside this method assembles the three pieces.
    static func make(accountStore: any AccountPersisting) -> DefaultMediaShareRuntime {
        let artworkCacheLifecycle = MediaShareLocalArtworkCacheLifecycle()
        // Step 6: build the pipeline with a user-override enrichment config (layered
        // on the Info.plist baseline) and a shared provider runtime so Settings can
        // read diagnostics + apply cache budgets. Empty overrides => Step 5 config.
        let providerRuntime = MetadataProviderRuntime.makeDefault()
        let providerSettingsStore = MetadataProviderSettingsStore()
        let enrichmentConfigCache = MetadataEnrichmentConfigCache(
            baseline: MetadataEnrichmentConfig.resolved(),
            settingsStore: providerSettingsStore
        )
        let enrichmentConfig: @Sendable () -> MetadataEnrichmentConfig = {
            enrichmentConfigCache.value()
        }
        // Step 9: the household-global TMDB BYOK key. Read per pipeline build (like the
        // enrichment override) so entering/removing a key applies on the next share
        // refresh. Absent key => `.withUserToken(nil)` is a no-op, so the built-in
        // (proxy/maintainer-token/disabled) TMDb path is byte-identical to pre-Step-9.
        let tmdbKeyStore = TMDBUserKeyStore(
            secureStore: KeychainStore(service: "com.plozz.app.household")
        )
        let providerConfig: @Sendable () -> MetadataProviderConfig = {
            MetadataProviderConfig.resolved().withUserToken(tmdbKeyStore.load())
        }
        let coordinator = ShareCatalogCoordinator(
            artworkCacheLifecycle: artworkCacheLifecycle,
            metadataComposition: ShareMetadataComposition(
                enrichmentConfig: enrichmentConfig,
                providerConfig: providerConfig,
                providerRuntime: providerRuntime
            )
        )
        // Apply persisted cache budgets to the live caches at startup (eviction runs
        // immediately if a budget was lowered since last launch).
        let cacheBudgets = CacheBudgetSettingsStore().load()
        Task {
            await MetadataDiskCache.shared.setMaxBytes(cacheBudgets.metadataCacheBytes)
            await ArtworkImageCache.shared.setDerivedArtworkCacheByteCap(cacheBudgets.artworkCacheBytes)
        }
        let composition = MediaShareTransportComposition.make(accountStore: accountStore)
        let resolver = MediaTransportNetworkFileResolver(
            registry: composition.resolverRegistry,
            playbackLeaseProvider: { locator in
                try await coordinator.acquirePlayback(accountKey: locator.accountID)
            }
        ) { locator in
            guard locator.sourceID == locator.accountID,
                  let account = accountStore.loadAccounts().first(where: {
                      $0.id == locator.accountID
                  }),
                  account.server.provider == .mediaShare,
                  account.credentialRevision == locator.credentialRevision else {
                throw MediaTransportError.authentication(reason: "inactive network-file identity")
            }
            return try MediaShareTransportComposition.mediaShareSessionKey(
                for: account,
                role: .playback,
                accountStore: accountStore
            )
        }
        let runtime = DefaultMediaShareRuntime(
            coordinator: coordinator,
            composition: composition,
            artworkCacheLifecycle: artworkCacheLifecycle,
            providerRuntime: providerRuntime,
            providerConfig: providerConfig,
            networkFileResolver: resolver
        )
        // AppShell is the only layer that sees both the transport resolver and
        // CoreUI. Configure the narrow artwork boundary here; CoreUI never imports
        // MediaTransportCore and remote URLs remain on ArtworkSession.
        ArtworkImageCache.shared.configure(
            networkFileService: ArtworkNetworkFileService(
                loader: MediaShareArtworkLoader(
                    resolver: resolver,
                    catalogCoordinator: coordinator
                ),
                failureReporter: MediaShareArtworkFailureReporter(coordinator: coordinator)
            )
        )
        return runtime
    }

    func registerProvider(
        into registry: ProviderRegistry,
        durableLocalStateStore: DurableLocalStateStore?
    ) {
        let composition = self.composition
        let coordinator = self.coordinator
        let networkFileResolver = self.networkFileResolver
        registry.register(.mediaShare) { context in
            guard let localMediaContext = context.localMediaContext else {
                throw ProviderResolutionError.localMediaContextRequired(.mediaShare)
            }
            let sessionFactory = try composition.makeSessionFactory(
                server: context.session.server,
                accountID: context.accountID,
                credentialRevision: context.credentialRevision
            )
            return ShareProvider(
                session: context.session,
                localMediaContext: localMediaContext,
                credentialRevision: context.credentialRevision,
                sessionFactory: sessionFactory,
                catalogCoordinator: coordinator,
                durableLocalStateStore: durableLocalStateStore,
                streamProber: PlozzigenNetworkFileStreamProber(
                    resolver: networkFileResolver
                )
            )
        }
    }

    func configure(reporter: ShareScanReporter) async {
        await coordinator.configure(reporter: reporter)
    }

    func invalidate(accountKey: String) async {
        await coordinator.invalidate(accountKey: accountKey)
        await artworkCacheLifecycle.purge(accountID: accountKey)
    }

    func retire(accountID: String, credentialRevision: CredentialRevision) async {
        await composition.resolverRegistry.retire(
            accountID: accountID,
            credentialRevision: credentialRevision
        )
        await artworkCacheLifecycle.purge(
            accountID: accountID,
            credentialRevision: credentialRevision
        )
    }

    func setPreferredAccountKeys(_ accountKeys: Set<String>, revision: UInt64) async {
        await coordinator.setPreferredAccountKeys(accountKeys, revision: revision)
    }

    func metadataDiagnosticsSnapshot() async -> MetadataEnrichmentDiagnosticsSnapshot {
        // Point-in-time, cross-actor: capture the timestamp first, then gather each
        // field from its own actor. The parts may be a few ms apart by design.
        let capturedAt = Date()
        let counts = await coordinator.metadataCountPerSource()
        let work = await coordinator.metadataWorkStatus()
        let artworkBytes = await ArtworkImageCache.shared.derivedArtworkCacheByteSize()
        let metadataBytes = await MetadataDiskCache.shared.currentByteSize()
        let breakers = await providerRuntime.breakerStates(
            tmdbCredentialID: providerConfig().tmdb.credentialID
        )
        let resultCount = await providerRuntime.resultCacheEntryCount()
        return MetadataEnrichmentDiagnosticsSnapshot(
            capturedAt: capturedAt,
            metadataCountPerSource: counts,
            artworkCacheBytes: artworkBytes,
            metadataCacheBytes: metadataBytes,
            resultCacheEntryCount: resultCount,
            providerBreakers: breakers,
            work: work
        )
    }

    func applyCacheBudgets(_ settings: CacheBudgetSettings) async {
        await MetadataDiskCache.shared.setMaxBytes(settings.metadataCacheBytes)
        await ArtworkImageCache.shared.setDerivedArtworkCacheByteCap(settings.artworkCacheBytes)
    }

    func clearMetadataCaches() async {
        await MetadataDiskCache.shared.clear()
        await ArtworkImageCache.shared.clearDerivedArtworkCache()
    }

    func validateTMDBUserKey(_ token: String) async -> TMDBKeyValidationResult {
        await TMDBKeyValidator().validate(token)
    }

    func invalidateTMDBCredential(forToken token: String) async {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let credentialID = TMDbAccess.userToken(trimmed).credentialID else { return }
        await providerRuntime.invalidateCredential(credentialID)
    }
}

private struct MediaShareLocalArtworkCacheLifecycle: ShareLocalArtworkCacheLifecycle {
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
