#if os(iOS)
import CoreModels
import Foundation
import MediaDownloads
import MediaTransportCore
import Observation

@MainActor
@Observable
final class PlozziOSDownloadsModel {
    private(set) var records: [DownloadedMediaRecord] = []
    private(set) var initializationError: String?
    var allowsCellular: Bool {
        didSet { updatePolicy() }
    }
    var pausesOnLowDataMode: Bool {
        didSet { updatePolicy() }
    }

    let offlineResolver: (any OfflinePlaybackResolving)?

    private let registry: DownloadedMediaRegistry?
    private let queue: DownloadQueue?
    private let defaults: UserDefaults?
    private let policyKey: String
    private let providerKind: @MainActor (String) -> ProviderKind?
    @ObservationIgnored
    nonisolated(unsafe) private var eventsTask: Task<Void, Never>?

    init(
        profileID: String,
        durableStore: DurableLocalStateStore,
        networkFileResolver: any MediaTransportNetworkFileResolving,
        providerKind: @escaping @MainActor (String) -> ProviderKind?,
        managedURLResolver:
            @escaping PlozziOSBackgroundHTTPDownloadEngine.URLResolver
    ) throws {
        let store = try DurableDownloadedMediaStore(
            store: durableStore,
            profileID: profileID
        )
        let registry = DownloadedMediaRegistry(store: store)
        let storage = PlatformDownloadStorageLocator(
            subdirectory: "PlozzDownloads/\(profileID)"
        )
        let policyKey = "downloads.policy.\(profileID)"
        let policy = Self.loadPolicy(key: policyKey)
        let engine = RoutingMediaDownloadEngine(
            directShare: TransportCursorDownloadEngine(
                resolver: networkFileResolver
            ),
            managedHTTP: PlozziOSBackgroundHTTPDownloadEngine(
                profileID: profileID,
                resolveURL: managedURLResolver
            )
        )
        let queue = DownloadQueue(
            registry: registry,
            storage: storage,
            engine: engine,
            observer: NWPathDownloadNetworkObserver(),
            policy: policy
        )

        self.registry = registry
        self.queue = queue
        self.offlineResolver = RegistryOfflinePlaybackResolver(
            registry: registry,
            storage: storage
        )
        self.defaults = .standard
        self.policyKey = policyKey
        self.providerKind = providerKind
        self.allowsCellular = policy.allowsExpensiveNetwork
        self.pausesOnLowDataMode = policy.pausesOnConstrainedNetwork

        eventsTask = Task { [weak self, registry] in
            await self?.reload()
            let events = await registry.events()
            for await _ in events {
                guard !Task.isCancelled else { return }
                await self?.reload()
            }
        }
        Task { await queue.resumeInterrupted() }
    }

    init(initializationError: String) {
        self.initializationError = initializationError
        self.registry = nil
        self.queue = nil
        self.offlineResolver = nil
        self.defaults = nil
        self.policyKey = ""
        self.providerKind = { _ in nil }
        self.allowsCellular = false
        self.pausesOnLowDataMode = true
    }

    deinit {
        eventsTask?.cancel()
    }

    func record(for item: MediaItem) async -> DownloadedMediaRecord? {
        await registry?.record(for: item)
    }

    @discardableResult
    func enqueue(
        item: MediaItem,
        provider: any MediaProvider
    ) async throws -> DownloadedMediaRecord {
        guard let queue else {
            throw PlozziOSDownloadError.unavailable(
                initializationError ?? "Downloads are unavailable."
            )
        }
        guard let identity = DownloadMediaIdentity.primary(for: item) else {
            throw PlozziOSDownloadError.unavailable(
                "This item does not have a stable offline identity."
            )
        }
        let playback = try await provider.playbackInfo(
            for: item.id,
            mediaSourceID: item.selectedVersionID,
            forceTranscode: false
        )
        let request: DownloadRequest
        switch playback.playbackSource {
        case .networkFile(let locator):
            request = DownloadRequest.directShare(
                identity: identity,
                locator: locator,
                snapshot: PinnedMediaSnapshot(item: item)
            )
        case .authenticatedHTTP(let locator):
            guard locator.deliveryMode == .directFile,
                  let accountID = item.sourceAccountID,
                  let kind = providerKind(accountID),
                  kind != .mediaShare else {
                throw PlozziOSDownloadError.unavailable(
                    "This server did not provide a downloadable original file."
                )
            }
            let source = ManagedHTTPDownloadSource(
                provider: kind,
                accountID: accountID,
                itemID: item.id,
                mediaSourceID: item.selectedVersionID
            )
            let fileExtension = playback.sourceFileName.map {
                ($0 as NSString).pathExtension
            }
            request = DownloadRequest.managedHTTP(
                identity: identity,
                source: source,
                snapshot: PinnedMediaSnapshot(item: item),
                fileExtension: fileExtension
            )
        case .publicURL, .dlnaResource, nil:
            throw PlozziOSDownloadError.unavailable(
                "This playback source cannot be downloaded for offline use."
            )
        }
        let record = try await queue.enqueue(request)
        await reload()
        return record
    }

    func pause(_ record: DownloadedMediaRecord) async {
        await queue?.pause(identityKey: record.identityKey)
        await reload()
    }

    func resume(_ record: DownloadedMediaRecord) async {
        await queue?.resume(identityKey: record.identityKey)
        await reload()
    }

    func remove(_ record: DownloadedMediaRecord) async {
        try? await queue?.cancelAndRemove(identityKey: record.identityKey)
        await reload()
    }

    private func reload() async {
        records = (await registry?.all() ?? [])
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private func updatePolicy() {
        guard let queue else { return }
        let policy = DownloadNetworkPolicy(
            allowsExpensiveNetwork: allowsCellular,
            pausesOnConstrainedNetwork: pausesOnLowDataMode
        )
        if let data = try? JSONEncoder().encode(policy) {
            defaults?.set(data, forKey: policyKey)
        }
        Task { await queue.updatePolicy(policy) }
    }

    private static func loadPolicy(key: String) -> DownloadNetworkPolicy {
        guard let data = UserDefaults.standard.data(forKey: key),
              let policy = try? JSONDecoder().decode(
                  DownloadNetworkPolicy.self,
                  from: data
              ) else {
            return .default
        }
        return policy
    }
}

private enum PlozziOSDownloadError: LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message): message
        }
    }
}
#endif
