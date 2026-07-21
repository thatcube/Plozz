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
    private let storage: (any DownloadStorageLocating)?
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
        self.storage = storage
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
        self.storage = nil
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
        let request = try await makeRequest(
            item: item,
            provider: provider,
            groupID: nil
        )
        guard let queue else {
            throw PlozziOSDownloadError.unavailable(
                initializationError ?? "Downloads are unavailable."
            )
        }
        let record = try await queue.enqueue(request)
        await reload()
        pinArtworkIfAvailable(for: item, record: record)
        return record
    }

    @discardableResult
    func enqueueSeason(
        season: MediaItem,
        episodes: [MediaItem],
        provider: any MediaProvider
    ) async throws -> [DownloadedMediaRecord] {
        guard let queue else {
            throw PlozziOSDownloadError.unavailable(
                initializationError ?? "Downloads are unavailable."
            )
        }
        guard !episodes.isEmpty else {
            throw PlozziOSDownloadError.unavailable(
                "This season has no downloadable episodes."
            )
        }
        let accountID = season.sourceAccountID
            ?? episodes.first?.sourceAccountID
            ?? "unknown"
        let groupID = "season:\(accountID):\(season.id)"
        var requests: [DownloadRequest] = []
        requests.reserveCapacity(episodes.count)
        for episode in episodes {
            requests.append(
                try await makeRequest(
                    item: episode,
                    provider: provider,
                    groupID: groupID
                )
            )
        }
        let records = try await queue.enqueueGroup(requests)
        await reload()
        for (episode, record) in zip(episodes, records) {
            pinArtworkIfAvailable(for: episode, record: record)
        }
        return records
    }

    func artworkURL(for record: DownloadedMediaRecord) -> URL? {
        guard let storage,
              let fileName = record.snapshot.artworkFileName,
              fileName == URL(fileURLWithPath: fileName).lastPathComponent,
              let folder = try? storage.pinnedFolderURL(
                forKey: record.identityKey
              ) else {
            return nil
        }
        let url = folder.appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func detailItem(for record: DownloadedMediaRecord) -> MediaItem? {
        let accountID = record.snapshot.sourceAccountID
            ?? record.managedHTTPSource?.accountID
            ?? record.directShareSource?.accountID
        let itemID = record.snapshot.sourceItemID
            ?? record.managedHTTPSource?.itemID
            ?? accountScopedItemID(from: record.identity)
        guard let accountID, let itemID else { return nil }
        return MediaItem(
            id: itemID,
            title: record.snapshot.title,
            kind: record.snapshot.kind,
            productionYear: record.snapshot.year,
            sourceAccountID: accountID
        )
    }

    /// A playback-ready item reconstructed from a downloaded record, enriched
    /// with the series/season/episode context captured at download time so the
    /// offline player can order episodes and show "S1 · E5"-style metadata. The
    /// reconstructed identity (`id` + account) matches what the offline resolver
    /// keys the pinned file by, so it plays straight from disk.
    func playbackItem(for record: DownloadedMediaRecord) -> MediaItem? {
        guard var item = detailItem(for: record) else { return nil }
        item.parentTitle = record.snapshot.seriesTitle
        item.seriesID = record.snapshot.seriesID
        item.seasonNumber = record.snapshot.seasonNumber
        item.episodeNumber = record.snapshot.episodeNumber
        item.providerIDs = record.snapshot.providerIDs
        return item
    }

    /// Finds the downloaded record that a live/reconstructed item refers to,
    /// matching on the portable source id + account captured in the snapshot.
    func downloadedRecord(matching item: MediaItem) -> DownloadedMediaRecord? {
        records.first { record in
            guard let sourceItemID = record.snapshot.sourceItemID,
                  sourceItemID == item.id else {
                return false
            }
            guard let account = item.sourceAccountID else { return true }
            return record.snapshot.sourceAccountID == nil
                || record.snapshot.sourceAccountID == account
        }
    }

    /// Previous/next **completed** downloaded episodes of the same show as
    /// `item`, in season/episode order — the basis for fully offline
    /// "watch the whole show" autoplay. Returns `nil` when `item` isn't a
    /// downloaded episode, so online playback keeps its provider-based neighbors.
    func offlineNeighborItems(
        for item: MediaItem
    ) -> (previous: MediaItem?, next: MediaItem?)? {
        guard let record = downloadedRecord(matching: item),
              record.snapshot.kind == .episode else {
            return nil
        }
        let ordered = orderedSeriesEpisodes(containing: record)
        guard ordered.count > 1,
              let index = ordered.firstIndex(where: {
                  $0.identityKey == record.identityKey
              }) else {
            return (nil, nil)
        }
        let previous = index > 0
            ? playbackItem(for: ordered[index - 1])
            : nil
        let next = index < ordered.count - 1
            ? playbackItem(for: ordered[index + 1])
            : nil
        return (previous, next)
    }

    /// The completed, playable episodes of the show that `record` belongs to,
    /// ordered by season then episode (reusing the grouped library ordering).
    private func orderedSeriesEpisodes(
        containing record: DownloadedMediaRecord
    ) -> [DownloadedMediaRecord] {
        guard let show = library.shows.first(where: { show in
            show.records.contains { $0.identityKey == record.identityKey }
        }) else {
            return []
        }
        return show.records.filter { $0.status == .completed }
    }

    private func makeRequest(
        item: MediaItem,
        provider: any MediaProvider,
        groupID: String?
    ) async throws -> DownloadRequest {
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
        switch playback.downloadableOriginalSource {
        case .networkFile(let locator):
            request = DownloadRequest.directShare(
                identity: identity,
                locator: locator,
                snapshot: PinnedMediaSnapshot(item: item),
                groupID: groupID
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
                mediaSourceID: locator.mediaSourceID ?? item.selectedVersionID
            )
            let fileExtension = playback.sourceFileName.map {
                ($0 as NSString).pathExtension
            }
            request = DownloadRequest.managedHTTP(
                identity: identity,
                source: source,
                snapshot: PinnedMediaSnapshot(item: item),
                groupID: groupID,
                fileExtension: fileExtension
            )
        case .publicURL, .dlnaResource, nil:
            throw PlozziOSDownloadError.unavailable(
                "This playback source cannot be downloaded for offline use."
            )
        }
        return request
    }

    private func pinArtworkIfAvailable(
        for item: MediaItem,
        record: DownloadedMediaRecord
    ) {
        guard record.snapshot.artworkFileName == nil,
              let sourceURL = artworkSourceURL(for: item) else {
            return
        }
        Task { [weak self] in
            await self?.pinArtwork(
                sourceURL: sourceURL,
                identityKey: record.identityKey
            )
        }
    }

    private func pinArtwork(
        sourceURL: URL,
        identityKey: String
    ) async {
        guard let storage, let registry else { return }
        do {
            let (data, response) = try await URLSession.shared.data(from: sourceURL)
            guard let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode),
                  !data.isEmpty,
                  data.count <= 15_000_000 else {
                return
            }
            guard await registry.record(forKey: identityKey) != nil else {
                return
            }
            let folder = try storage.pinnedFolderURL(forKey: identityKey)
            try FileManager.default.createDirectory(
                at: folder,
                withIntermediateDirectories: true
            )
            let fileName = "artwork.img"
            let artworkURL = folder.appendingPathComponent(fileName)
            try data.write(
                to: artworkURL,
                options: .atomic
            )
            let attached = try await registry.setArtworkFileName(
                identityKey: identityKey,
                fileName: fileName
            )
            if !attached {
                try? FileManager.default.removeItem(at: folder)
                return
            }
            await reload()
        } catch {
            // Artwork is optional; media download success remains authoritative.
        }
    }

    private func artworkSourceURL(for item: MediaItem) -> URL? {
        item.backdropURL
            ?? item.fallbackArtworkURL
            ?? item.posterURL
            ?? item.seriesPosterURL
    }

    private func accountScopedItemID(
        from identity: MediaIdentity
    ) -> String? {
        guard case let .external(source, value) = identity,
              source.hasPrefix(DownloadMediaIdentity.accountSourcePrefix) else {
            return nil
        }
        return value
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

    /// A grouped, browsable projection of the current downloads: standalone
    /// movies plus shows collapsed into seasons/episodes.
    var library: PlozziOSDownloadLibrary {
        PlozziOSDownloadLibrary.make(from: records)
    }

    /// Total bytes stored across completed and in-flight downloads.
    var totalBytesDownloaded: Int64 {
        records.reduce(0) { $0 + $1.bytesDownloaded }
    }

    /// Records with a transfer still in progress, queued, or paused.
    var activeTransfers: [DownloadedMediaRecord] {
        records.filter {
            $0.status == .downloading
                || $0.status == .queued
                || $0.status == .paused
        }
    }

    var hasActiveTransfers: Bool { !activeTransfers.isEmpty }

    /// Removes many records as a single unit (a whole season, a whole show, or
    /// everything), cancelling any in-flight transfer, then reloads once.
    func remove(_ toRemove: [DownloadedMediaRecord]) async {
        guard let queue, !toRemove.isEmpty else { return }
        for record in toRemove {
            try? await queue.cancelAndRemove(identityKey: record.identityKey)
        }
        await reload()
    }

    /// Cancels and deletes every download for this profile.
    func removeAll() async {
        await remove(records)
    }

    /// Cancels every in-flight/queued/paused transfer, leaving completed
    /// downloads in place.
    func cancelActiveTransfers() async {
        await remove(activeTransfers)
    }

    /// Pauses every actively transferring or queued download.
    func pauseAllActive() async {
        guard let queue else { return }
        for record in records
        where record.status == .downloading || record.status == .queued {
            await queue.pause(identityKey: record.identityKey)
        }
        await reload()
    }

    /// Resumes every paused or failed download.
    func resumeAllPaused() async {
        guard let queue else { return }
        for record in records
        where record.status == .paused || record.status == .failed {
            await queue.resume(identityKey: record.identityKey)
        }
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
