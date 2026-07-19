import Foundation
import CoreModels
import CoreUI
import FeatureAuth
import MediaTransportCore
import ProviderShare
import EnginePlozzigen

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
}

/// The single production `MediaShareRuntime`. Construct it only through
/// ``make(accountStore:)`` — that is the one default construction path the
/// Batch 11 gate requires.
final class DefaultMediaShareRuntime: MediaShareRuntime {
    private let coordinator: ShareCatalogCoordinator
    private let composition: MediaShareTransportComposition
    private let artworkCacheLifecycle: any ShareLocalArtworkCacheLifecycle
    let networkFileResolver: any MediaTransportNetworkFileResolving

    private init(
        coordinator: ShareCatalogCoordinator,
        composition: MediaShareTransportComposition,
        artworkCacheLifecycle: any ShareLocalArtworkCacheLifecycle,
        networkFileResolver: any MediaTransportNetworkFileResolving
    ) {
        self.coordinator = coordinator
        self.composition = composition
        self.artworkCacheLifecycle = artworkCacheLifecycle
        self.networkFileResolver = networkFileResolver
    }

    /// The one default construction path: a fresh coordinator, the media-share
    /// transport composition, and a network-file resolver whose playback lease
    /// comes from that same coordinator and whose session key comes from that
    /// same composition. Nothing outside this method assembles the three pieces.
    static func make(accountStore: any AccountPersisting) -> DefaultMediaShareRuntime {
        let artworkCacheLifecycle = MediaShareLocalArtworkCacheLifecycle()
        let coordinator = ShareCatalogCoordinator(
            artworkCacheLifecycle: artworkCacheLifecycle
        )
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
            networkFileResolver: resolver
        )
        // AppShell is the only layer that sees both the transport resolver and
        // CoreUI. Configure the narrow artwork boundary here; CoreUI never imports
        // MediaTransportCore and remote URLs remain on ArtworkSession.
        ArtworkImageCache.shared.configure(
            networkFileService: ArtworkNetworkFileService(
                loader: MediaShareArtworkLoader(resolver: resolver),
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
