import Foundation
import CoreModels
import FeatureAuthCore
import MediaTransportCore
import ProviderShare

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
public final class DefaultMediaShareRuntime: MediaShareRuntime {
    private let coordinator: ShareCatalogCoordinator
    private let composition: MediaShareTransportComposition
    private let artworkCacheLifecycle: any ShareLocalArtworkCacheLifecycle
    public let networkFileResolver: any MediaTransportNetworkFileResolving
    private let streamProber: (any NetworkFileStreamProbing)?

    private init(
        coordinator: ShareCatalogCoordinator,
        composition: MediaShareTransportComposition,
        artworkCacheLifecycle: any ShareLocalArtworkCacheLifecycle,
        networkFileResolver: any MediaTransportNetworkFileResolving,
        streamProber: (any NetworkFileStreamProbing)?
    ) {
        self.coordinator = coordinator
        self.composition = composition
        self.artworkCacheLifecycle = artworkCacheLifecycle
        self.networkFileResolver = networkFileResolver
        self.streamProber = streamProber
    }

    /// The one default construction path: a fresh coordinator, the media-share
    /// transport composition, and a network-file resolver whose playback lease
    /// comes from that same coordinator and whose session key comes from that
    /// same composition. Nothing outside this method assembles the three pieces.
    public static func make(
        accountStore: any AccountPersisting,
        artworkCacheLifecycle: any ShareLocalArtworkCacheLifecycle =
            NoopShareLocalArtworkCacheLifecycle(),
        streamProberFactory: @Sendable (
            any MediaTransportNetworkFileResolving
        ) -> (any NetworkFileStreamProbing)? = { _ in nil }
    ) -> DefaultMediaShareRuntime {
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
        return DefaultMediaShareRuntime(
            coordinator: coordinator,
            composition: composition,
            artworkCacheLifecycle: artworkCacheLifecycle,
            networkFileResolver: resolver,
            streamProber: streamProberFactory(resolver)
        )
    }

    public var artworkNetworkFileService: ArtworkNetworkFileService {
        ArtworkNetworkFileService(
            loader: MediaShareArtworkLoader(
                resolver: networkFileResolver,
                catalogCoordinator: coordinator
            ),
            failureReporter: self
        )
    }

    public func registerProvider(
        into registry: ProviderRegistry,
        durableLocalStateStore: DurableLocalStateStore?
    ) {
        let composition = self.composition
        let coordinator = self.coordinator
        let streamProber = self.streamProber
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
                streamProber: streamProber
            )
        }
    }

    public func configure(reporter: ShareScanReporter) async {
        await coordinator.configure(reporter: reporter)
    }

    public func invalidate(accountKey: String) async {
        await coordinator.invalidate(accountKey: accountKey)
        await artworkCacheLifecycle.purge(accountID: accountKey)
    }

    public func retire(accountID: String, credentialRevision: CredentialRevision) async {
        await composition.resolverRegistry.retire(
            accountID: accountID,
            credentialRevision: credentialRevision
        )
        await artworkCacheLifecycle.purge(
            accountID: accountID,
            credentialRevision: credentialRevision
        )
    }

    public func setPreferredAccountKeys(_ accountKeys: Set<String>, revision: UInt64) async {
        await coordinator.setPreferredAccountKeys(accountKeys, revision: revision)
    }
}

extension DefaultMediaShareRuntime: ArtworkNetworkFileFailureReporting {
    public func reportArtworkFailure(
        _ failure: ArtworkNetworkFileFailure,
        for reference: NetworkArtworkReference
    ) async {
        switch failure {
        case .empty, .tooLarge, .malformed, .unsupported, .unsafeDimensions:
            await coordinator.rejectArtwork(
                accountKey: reference.accountID,
                reference: reference
            )
        case .unavailable, .cancelled:
            break
        }
    }
}
