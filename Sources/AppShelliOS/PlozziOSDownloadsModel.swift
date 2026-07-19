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
    @ObservationIgnored
    nonisolated(unsafe) private var eventsTask: Task<Void, Never>?

    init(
        profileID: String,
        durableStore: DurableLocalStateStore,
        networkFileResolver: any MediaTransportNetworkFileResolving
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
        let queue = DownloadQueue(
            registry: registry,
            storage: storage,
            engine: TransportCursorDownloadEngine(resolver: networkFileResolver),
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
        guard case .networkFile(let locator) = playback.playbackSource else {
            throw PlozziOSDownloadError.unavailable(
                "Managed-server background downloads are not available in this build yet."
            )
        }
        let request = DownloadRequest.directShare(
            identity: identity,
            locator: locator,
            snapshot: PinnedMediaSnapshot(item: item)
        )
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
