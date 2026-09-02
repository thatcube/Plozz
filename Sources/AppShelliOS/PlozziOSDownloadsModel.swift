#if os(iOS)
import CoreModels
import Foundation
import MediaDownloads
import MediaTransportCore
import Observation
import UserNotifications

@MainActor
@Observable
final class PlozziOSDownloadsModel {
    struct TransferMetrics: Equatable {
        let bytesPerSecond: Int64
        let estimatedTimeRemaining: TimeInterval?
    }

    struct BatchGroup {
        let season: MediaItem
        let episodes: [MediaItem]
        let provider: any MediaProvider
    }

    private struct RenditionCapability: Codable {
        let isSupported: Bool
        let checkedAt: Date
    }

    private(set) var records: [DownloadedMediaRecord] = [] {
        didSet {
            recordsByKey = Dictionary(
                records.map { ($0.identityKey, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            recordsByIdentityKey = Dictionary(
                grouping: records,
                by: { MediaIdentityKey.string(for: $0.identity) }
            )
            .mapValues { records in
                records.sorted { $0.identityKey < $1.identityKey }
            }
        }
    }
    /// `records` indexed by identity key. `cachedRecord(forSelectedVersionOf:)` is
    /// called from SwiftUI `body` (menus are built as cards render), so the linear
    /// scan it replaces ran per card per frame during a scroll.
    @ObservationIgnored
    private var recordsByKey: [String: DownloadedMediaRecord] = [:]
    @ObservationIgnored
    private var recordsByIdentityKey: [String: [DownloadedMediaRecord]] = [:]
    private(set) var initializationError: String?
    var allowsCellular: Bool {
        didSet {
            policy.allowsExpensiveNetwork = allowsCellular
            persistPolicy(restartActiveManagedDownloads: true)
        }
    }
    var pausesOnLowDataMode: Bool {
        didSet {
            policy.pausesOnConstrainedNetwork = pausesOnLowDataMode
            persistPolicy(restartActiveManagedDownloads: true)
        }
    }
    var downloadQuality: DownloadQuality {
        didSet {
            policy.quality = downloadQuality
            persistPolicy()
        }
    }
    var includesAllAudioTracks: Bool {
        didSet {
            policy.includesAllAudioTracks = includesAllAudioTracks
            persistPolicy()
        }
    }
    var includesTextSubtitleTracks: Bool {
        didSet {
            policy.includesTextSubtitleTracks = includesTextSubtitleTracks
            persistPolicy()
        }
    }
    /// Aggregate offline-download cap expressed in megabits/sec for settings UI.
    /// `nil` means unlimited.
    var maximumDownloadMegabitsPerSecond: Int? {
        didSet {
            policy.maximumBytesPerSecond =
                maximumDownloadMegabitsPerSecond.map {
                    Int64($0) * 1_000_000 / 8
                }
            persistPolicy(restartActiveManagedDownloads: true)
        }
    }
    var cappedBackgroundBehavior: CappedDownloadBackgroundBehavior {
        didSet {
            policy.cappedBackgroundBehavior = cappedBackgroundBehavior
            persistPolicy()
        }
    }
    var asksBeforeDownloading: Bool {
        didSet { persistPreferences() }
    }
    var notifiesOnStandaloneCompletion: Bool {
        didSet { persistPreferences() }
    }
    var notifiesOnBatchCompletion: Bool {
        didSet { persistPreferences() }
    }
    var notifiesOnFailure: Bool {
        didSet { persistPreferences() }
    }
    private(set) var aggregateBytesPerSecond: Int64 = 0
    private(set) var transferMetricsByKey: [String: TransferMetrics] = [:]

    let offlineResolver: (any OfflinePlaybackResolving)?

    private let registry: DownloadedMediaRegistry?
    private let queue: DownloadQueue?
    private let storage: (any DownloadStorageLocating)?
    private let defaults: UserDefaults?
    private let policyKey: String
    private let preferencesKey: String
    private let renditionCapabilitiesKey: String
    private var policy: DownloadNetworkPolicy
    private var renditionCapabilities: [String: RenditionCapability]
    private var renditionCapabilityTasks:
        [String: Task<Bool, any Error>] = [:]
    private var speedSample: (date: Date, bytes: Int64)?
    private var speedSamplesByKey: [String: (date: Date, bytes: Int64)] = [:]
    private var hasLoadedRecords = false
    private var notifiedBatchIDs: Set<String> = []
    private var isUsingUncappedBackgroundPolicy = false
    private let uncappedBackgroundPolicyKey: String
    private var applicationActivityGeneration = 0
    private var applicationIsActive: Bool
    private var acceptsNewWork = true
    private var inFlightEnqueueCount = 0
    private var enqueueDrainWaiters: [CheckedContinuation<Void, Never>] = []
    private let providerKind: @MainActor (String) -> ProviderKind?
    private let preferredAudioLanguages: @MainActor (MediaItem) -> [String]
    @ObservationIgnored
    nonisolated(unsafe) private var eventsTask: Task<Void, Never>?
    @ObservationIgnored
    nonisolated(unsafe) private var networkTask: Task<Void, Never>?
    @ObservationIgnored
    nonisolated(unsafe) private var metricsExpiryTask: Task<Void, Never>?

    init(
        profileID: String,
        durableStore: DurableLocalStateStore,
        networkFileResolver: any MediaTransportNetworkFileResolving,
        providerKind: @escaping @MainActor (String) -> ProviderKind?,
        preferredAudioLanguages:
            @escaping @MainActor (MediaItem) -> [String],
        startsActive: Bool = true,
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
        let preferencesKey = "downloads.preferences.\(profileID)"
        let renditionCapabilitiesKey =
            "downloads.rendition-capabilities.\(profileID)"
        let uncappedBackgroundPolicyKey =
            "downloads.uncapped-background-policy.\(profileID)"
        let preferences = Self.loadPreferences(key: preferencesKey)
        let networkObserver = NWPathDownloadNetworkObserver()
        let engine = RoutingMediaDownloadEngine(
            directShare: TransportCursorDownloadEngine(
                resolver: networkFileResolver
            ),
            managedHTTP: PlozziOSBackgroundHTTPDownloadEngine(
                profileID: profileID,
                registry: registry,
                resolveURL: managedURLResolver
            )
        )
        let queue = DownloadQueue(
            registry: registry,
            storage: storage,
            engine: engine,
            observer: networkObserver,
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
        self.preferencesKey = preferencesKey
        self.renditionCapabilitiesKey = renditionCapabilitiesKey
        self.renditionCapabilities = Self.loadRenditionCapabilities(
            key: renditionCapabilitiesKey
        )
        self.uncappedBackgroundPolicyKey = uncappedBackgroundPolicyKey
        self.policy = policy
        self.providerKind = providerKind
        self.preferredAudioLanguages = preferredAudioLanguages
        self.allowsCellular = policy.allowsExpensiveNetwork
        self.pausesOnLowDataMode = policy.pausesOnConstrainedNetwork
        self.downloadQuality = policy.quality
        self.includesAllAudioTracks = policy.includesAllAudioTracks
        self.includesTextSubtitleTracks = policy.includesTextSubtitleTracks
        self.maximumDownloadMegabitsPerSecond =
            policy.maximumBytesPerSecond.map {
                max(1, Int(($0 * 8) / 1_000_000))
            }
        self.cappedBackgroundBehavior = policy.cappedBackgroundBehavior
        self.isUsingUncappedBackgroundPolicy = UserDefaults.standard.bool(
            forKey: uncappedBackgroundPolicyKey
        )
        self.applicationIsActive = startsActive
        self.asksBeforeDownloading = preferences.asksBeforeDownloading
        self.notifiesOnStandaloneCompletion =
            preferences.notifiesOnStandaloneCompletion
        self.notifiesOnBatchCompletion = preferences.notifiesOnBatchCompletion
        self.notifiesOnFailure = preferences.notifiesOnFailure

        eventsTask = Task { [weak self, registry] in
            await self?.reload()
            let events = await registry.events()
            for await _ in events {
                guard !Task.isCancelled else { return }
                await self?.reload()
            }
        }
        networkTask = Task { [weak self, queue, networkObserver] in
            for await conditions in networkObserver.updates() {
                guard !Task.isCancelled else { return }
                await self?.enforceSpeedLimitPausePolicy()
                guard !Task.isCancelled else { return }
                await queue.networkConditionsDidChange(conditions)
                guard !Task.isCancelled else { return }
                await self?.reload()
            }
        }
        Task { [weak self] in
            await queue.updatePolicy(policy)
            await Self.invalidateLegacyPlexRenditions(in: registry)
            guard let self else { return }
            await self.setApplicationActive(self.applicationIsActive)
        }
    }

    init(initializationError: String) {
        self.initializationError = initializationError
        self.registry = nil
        self.queue = nil
        self.storage = nil
        self.offlineResolver = nil
        self.defaults = nil
        self.policyKey = ""
        self.preferencesKey = ""
        self.renditionCapabilitiesKey = ""
        self.renditionCapabilities = [:]
        self.uncappedBackgroundPolicyKey = ""
        self.policy = .default
        self.applicationIsActive = true
        self.providerKind = { _ in nil }
        self.preferredAudioLanguages = { _ in [] }
        self.allowsCellular = false
        self.pausesOnLowDataMode = true
        self.downloadQuality = .original
        self.includesAllAudioTracks = false
        self.includesTextSubtitleTracks = true
        self.maximumDownloadMegabitsPerSecond = nil
        self.cappedBackgroundBehavior = .pause
        self.asksBeforeDownloading = true
        self.notifiesOnStandaloneCompletion = false
        self.notifiesOnBatchCompletion = false
        self.notifiesOnFailure = false
    }

    deinit {
        eventsTask?.cancel()
        networkTask?.cancel()
        metricsExpiryTask?.cancel()
    }

    func beginProfileTransition() {
        acceptsNewWork = false
        applicationActivityGeneration += 1
        networkTask?.cancel()
    }

    func quiesceForProfileSwitch() async {
        beginProfileTransition()
        guard let queue else { return }
        await queue.suspendScheduling()
        if inFlightEnqueueCount > 0 {
            await withCheckedContinuation { continuation in
                enqueueDrainWaiters.append(continuation)
            }
        }
        while true {
            let active = (await registry?.all() ?? []).filter {
                $0.status.isActive
            }
            guard !active.isEmpty else { return }
            for record in active {
                await queue.pause(
                    identityKey: record.identityKey,
                    reason: .inactiveProfile
                )
            }
        }
    }

    /// Any downloaded copy of this title, regardless of version. For "does this
    /// title exist offline?" questions.
    func record(for item: MediaItem) async -> DownloadedMediaRecord? {
        await registry?.record(for: item)
    }

    /// The downloaded copy of the item's **selected version**, so a download
    /// button reflects the version actually chosen: with 4K selected and only
    /// 1080p on disk this correctly reports "not downloaded" and lets the 4K be
    /// fetched alongside it.
    func record(forSelectedVersionOf item: MediaItem) async -> DownloadedMediaRecord? {
        await registry?.record(for: item, versionID: item.selectedVersionID)
    }

    /// Synchronous in-memory lookup for the item's SELECTED version, for callers
    /// that must answer without awaiting (building a menu as it opens). `records`
    /// is the already-loaded published snapshot, so this needs no actor hop.
    func cachedRecord(forSelectedVersionOf item: MediaItem) -> DownloadedMediaRecord? {
        // An item can carry SEVERAL identities (the same title on more than one
        // server), so match the registry's own resolution rather than assuming a
        // single key — otherwise a download made from one server is invisible to
        // a card resolved through another.
        guard let versionID = item.selectedVersionID, !versionID.isEmpty else {
            return cachedRecord(for: item)
        }

        for identity in MediaItemIdentity.identities(for: item) {
            let key = MediaIdentityKey.string(
                for: identity,
                versionID: versionID
            )
            if let record = recordsByKey[key] { return record }
        }
        if let identity = DownloadMediaIdentity.primary(for: item),
           let record = recordsByKey[
               MediaIdentityKey.string(for: identity, versionID: versionID)
           ] {
            return record
        }
        return records.first {
            $0.versionID == versionID && $0.snapshot.sourceItemID == item.id
        }
    }

    func supportsReducedQuality(for item: MediaItem) -> Bool {
        guard let accountID = item.sourceAccountID,
              let capability = freshRenditionCapability(for: accountID) else {
            return false
        }
        return capability.isSupported
    }

    var customDownloadQuality: DownloadQuality? {
        guard case .constrained = downloadQuality,
              ![
                  DownloadQuality.hd1080,
                  .hd720,
                  .sd480
              ].contains(downloadQuality) else {
            return nil
        }
        return downloadQuality
    }

    var customDownloadQualityTitle: LocalizedStringResource? {
        guard case .constrained(let constraint) = customDownloadQuality else {
            return nil
        }
        let megabits = Double(constraint.maximumVideoBitrateBps) / 1_000_000
        return "Custom • \(constraint.maximumHeight)p • \(megabits.formatted(.number.precision(.fractionLength(1)))) Mbps"
    }

    func refreshReducedQualitySupport(
        for item: MediaItem,
        provider: any MediaProvider
    ) async {
        _ = try? await confirmReducedQualitySupport(
            for: item,
            provider: provider
        )
    }

    /// Synchronous version-agnostic lookup for visual status surfaces. When an
    /// episode row has no explicit version selected, any downloaded copy satisfies
    /// its badge just as the registry's authoritative `record(for:)` lookup does.
    func cachedRecord(for item: MediaItem) -> DownloadedMediaRecord? {
        let identities = MediaItemIdentity.identities(for: item)
        for identity in identities {
            let key = MediaIdentityKey.string(for: identity)
            if let record = recordsByKey[key]
                ?? recordsByIdentityKey[key]?.first {
                return record
            }
        }
        if let identity = DownloadMediaIdentity.primary(for: item) {
            let key = MediaIdentityKey.string(for: identity)
            if let record = recordsByKey[key]
                ?? recordsByIdentityKey[key]?.first {
                return record
            }
        }
        let expectedAccountSource = item.sourceAccountID.map {
            "\(DownloadMediaIdentity.accountSourcePrefix)\($0)"
        }
        let sourceScopedMatches = records.filter {
            guard case .external(let source, let value) = $0.identity,
                  value == item.id else {
                return false
            }
            if let expectedAccountSource {
                return source == expectedAccountSource
            }
            return source.hasPrefix(DownloadMediaIdentity.accountSourcePrefix)
        }
        return sourceScopedMatches.count == 1 ? sourceScopedMatches[0] : nil
    }

    @discardableResult
    func enqueue(
        item: MediaItem,
        provider: any MediaProvider,
        quality: DownloadQuality? = nil
    ) async throws -> DownloadedMediaRecord {
        try beginEnqueue()
        defer { finishEnqueue() }
        let request = try await makeRequest(
            item: item,
            provider: provider,
            groupID: nil,
            requestedQuality: quality
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
        provider: any MediaProvider,
        batchID: String? = nil,
        batchKind: DownloadBatchKind = .season,
        batchTitle: String? = nil,
        batchExpectedCount: Int? = nil,
        quality: DownloadQuality? = nil
    ) async throws -> [DownloadedMediaRecord] {
        try await enqueueBatch(
            groups: [
                BatchGroup(
                    season: season,
                    episodes: episodes,
                    provider: provider
                )
            ],
            batchID: batchID,
            batchKind: batchKind,
            batchTitle: batchTitle ?? season.title,
            batchExpectedCount: batchExpectedCount ?? episodes.count,
            quality: quality
        )
    }

    /// Builds every request before persisting any record, then commits the whole
    /// season/show batch in one registry transaction.
    @discardableResult
    func enqueueBatch(
        groups: [BatchGroup],
        batchID: String? = nil,
        batchKind: DownloadBatchKind,
        batchTitle: String,
        batchExpectedCount: Int,
        quality: DownloadQuality? = nil
    ) async throws -> [DownloadedMediaRecord] {
        try beginEnqueue()
        defer { finishEnqueue() }
        guard let queue else {
            throw PlozziOSDownloadError.unavailable(
                initializationError ?? "Downloads are unavailable."
            )
        }
        let episodeCount = groups.reduce(0) { $0 + $1.episodes.count }
        guard episodeCount > 0 else {
            throw PlozziOSDownloadError.unavailable(
                "This selection has no downloadable episodes."
            )
        }
        let explicitBatchID = batchID ?? UUID().uuidString
        var requests: [DownloadRequest] = []
        requests.reserveCapacity(episodeCount)
        var artworkItems: [MediaItem] = []
        artworkItems.reserveCapacity(episodeCount)
        for group in groups {
            let accountID = group.season.sourceAccountID
                ?? group.episodes.first?.sourceAccountID
                ?? "unknown"
            let groupID = "season:\(accountID):\(group.season.id)"
            for episode in group.episodes {
                requests.append(
                    try await makeRequest(
                        item: episode,
                        provider: group.provider,
                        groupID: groupID,
                        batchID: explicitBatchID,
                        batchKind: batchKind,
                        batchTitle: batchTitle,
                        batchExpectedCount: batchExpectedCount,
                        requestedQuality: quality
                    )
                )
                artworkItems.append(episode)
            }
        }
        let records = try await queue.enqueueGroup(requests)
        await reload()
        for (episode, record) in zip(artworkItems, records) {
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
            runtime: record.snapshot.runtime,
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
        groupID: String?,
        batchID: String? = nil,
        batchKind: DownloadBatchKind? = nil,
        batchTitle: String? = nil,
        batchExpectedCount: Int? = nil,
        requestedQuality: DownloadQuality? = nil
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
        // Scope the download to the version being downloaded so a title's 4K and
        // 1080p copies are separate records — and so playback can tell which one
        // is actually on disk instead of playing whichever exists.
        let versionID = item.selectedVersionID
        let versionLabel = item.versions
            .first { $0.id == versionID }?
            .displayLabel
        let request: DownloadRequest
        let quality = requestedQuality ?? policy.quality
        switch playback.downloadableOriginalSource {
        case .networkFile(let locator):
            guard quality == .original else {
                throw PlozziOSDownloadError.unavailable(
                    "Network shares support Original quality only."
                )
            }
            request = DownloadRequest.directShare(
                identity: identity,
                locator: locator,
                snapshot: PinnedMediaSnapshot(item: item),
                versionID: versionID,
                versionLabel: versionLabel,
                groupID: groupID,
                batchID: batchID,
                batchKind: batchKind,
                batchTitle: batchTitle,
                batchExpectedCount: batchExpectedCount,
                expectedBytes: locator.representation.size,
                quality: .original
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
            if quality != .original {
                _ = try await confirmReducedQualitySupport(
                    for: item,
                    provider: provider
                )
            }
            if quality != .original,
               policy.maximumBytesPerSecond != nil,
               kind != .plex {
                throw PlozziOSDownloadError.unavailable(
                    "Reduced-quality Jellyfin and Emby downloads cannot be speed-limited. Choose Original or set Download Speed to Full Speed."
                )
            }
            if quality != .original,
               policy.includesAllAudioTracks,
               kind == .plex {
                throw PlozziOSDownloadError.unavailable(
                    "Plex reduced-quality downloads support one audio track. Turn off Include All Audio Tracks or choose Original quality."
                )
            }
            let source = ManagedHTTPDownloadSource(
                provider: kind,
                accountID: accountID,
                itemID: item.id,
                mediaSourceID: locator.mediaSourceID ?? item.selectedVersionID,
                quality: quality,
                includesAllAudioTracks: policy.includesAllAudioTracks,
                includesTextSubtitleTracks: policy.includesTextSubtitleTracks,
                preferredAudioLanguages: preferredAudioLanguages(item)
            )
            let fileExtension = playback.sourceFileName.map {
                ($0 as NSString).pathExtension
            }
            request = DownloadRequest.managedHTTP(
                identity: identity,
                source: source,
                snapshot: PinnedMediaSnapshot(item: item),
                versionID: versionID,
                versionLabel: versionLabel,
                groupID: groupID,
                batchID: batchID,
                batchKind: batchKind,
                batchTitle: batchTitle,
                batchExpectedCount: batchExpectedCount,
                expectedBytes: quality == .original
                    ? playback.sourceMetadata?.fileSizeBytes
                    : Self.estimatedRenditionBytes(
                        runtime: item.runtime,
                        quality: quality
                    ),
                fileExtension: quality == .original
                    ? fileExtension
                    : (kind == .plex ? "mp4" : "movpkg"),
                quality: quality
            )
        case .publicURL, .dlnaResource, nil:
            throw PlozziOSDownloadError.unavailable(
                "This playback source cannot be downloaded for offline use."
            )
        }
        return request
    }

    private func confirmReducedQualitySupport(
        for item: MediaItem,
        provider: any MediaProvider
    ) async throws -> Bool {
        guard let accountID = item.sourceAccountID,
              [.plex, .jellyfin, .emby].contains(provider.kind) else {
            throw PlozziOSDownloadError.unavailable(
                "This source supports Original quality only."
            )
        }
        if let capability = freshRenditionCapability(for: accountID) {
            guard capability.isSupported else {
                throw PlozziOSDownloadError.unavailable(
                    "This account cannot create reduced-quality downloads."
                )
            }
            return true
        }
        if let task = renditionCapabilityTasks[accountID] {
            let isSupported = try await task.value
            guard isSupported else {
                throw PlozziOSDownloadError.unavailable(
                    "This account cannot create reduced-quality downloads."
                )
            }
            return true
        }

        let mediaSourceID = item.selectedVersionID
        let task = Task {
            let playback = try await provider.playbackInfo(
                for: item.id,
                mediaSourceID: mediaSourceID,
                forceTranscode: true
            )
            return playback.isTranscoding
                || playback.deliveryMode == .transcode
        }
        renditionCapabilityTasks[accountID] = task
        defer { renditionCapabilityTasks[accountID] = nil }

        do {
            let isSupported = try await task.value
            storeRenditionCapability(
                isSupported,
                accountID: accountID
            )
            guard isSupported else {
                throw PlozziOSDownloadError.unavailable(
                    "This account cannot create reduced-quality downloads."
                )
            }
            return true
        } catch let error as AppError where !error.isTransportFailure {
            storeRenditionCapability(false, accountID: accountID)
            throw PlozziOSDownloadError.unavailable(
                "This account cannot create reduced-quality downloads."
            )
        }
    }

    private func freshRenditionCapability(
        for accountID: String
    ) -> RenditionCapability? {
        guard let capability = renditionCapabilities[accountID] else {
            return nil
        }
        let lifetime: TimeInterval = capability.isSupported
            ? 24 * 60 * 60
            : 5 * 60
        guard Date().timeIntervalSince(capability.checkedAt) < lifetime else {
            return nil
        }
        return capability
    }

    private func storeRenditionCapability(
        _ isSupported: Bool,
        accountID: String
    ) {
        renditionCapabilities[accountID] = RenditionCapability(
            isSupported: isSupported,
            checkedAt: Date()
        )
        if let data = try? JSONEncoder().encode(renditionCapabilities) {
            defaults?.set(data, forKey: renditionCapabilitiesKey)
        }
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
        await resumeWithoutReload(record)
        await reload()
    }

    private func resumeWithoutReload(_ record: DownloadedMediaRecord) async {
        guard acceptsNewWork else { return }
        if mustRemainPausedForSpeedLimit(record) {
            await queue?.pause(
                identityKey: record.identityKey,
                reason: .speedLimitPolicy
            )
            return
        }
        if record.status == .failed,
           requiresFreshRetry(record),
           let request = retryRequest(for: record) {
            do {
                _ = try await queue?.restartFailed(request)
                return
            } catch {
                try? await registry?.setStatus(
                    identityKey: record.identityKey,
                    .failed,
                    failureReason: error.localizedDescription
                )
                return
            }
        }
        await queue?.resume(identityKey: record.identityKey)
    }

    private func requiresFreshRetry(_ record: DownloadedMediaRecord) -> Bool {
        record.quality != .original
            && record.managedHTTPSource?.provider == .plex
    }

    private func retryRequest(
        for record: DownloadedMediaRecord
    ) -> DownloadRequest? {
        var managedSource = record.managedHTTPSource
        if record.sourceKind == .managedHTTP, managedSource == nil {
            guard let accountID = record.snapshot.sourceAccountID,
                  let itemID = record.snapshot.sourceItemID,
                  let kind = providerKind(accountID),
                  kind != .mediaShare else {
                return nil
            }
            managedSource = ManagedHTTPDownloadSource(
                provider: kind,
                accountID: accountID,
                itemID: itemID,
                mediaSourceID: record.versionID,
                quality: record.quality,
                includesAllAudioTracks: policy.includesAllAudioTracks,
                includesTextSubtitleTracks: policy.includesTextSubtitleTracks
            )
        }
        if record.quality != .original,
           let source = managedSource,
           source.provider == .plex {
            managedSource = ManagedHTTPDownloadSource(
                provider: source.provider,
                accountID: source.accountID,
                itemID: source.itemID,
                mediaSourceID: source.mediaSourceID,
                quality: source.quality,
                includesAllAudioTracks: policy.includesAllAudioTracks,
                includesTextSubtitleTracks:
                    policy.includesTextSubtitleTracks,
                preferredAudioLanguages:
                    source.preferredAudioLanguages
            )
        }

        let fileExtension: String?
        if record.quality != .original,
           managedSource?.provider == .plex {
            fileExtension = "mp4"
        } else {
            let pathExtension = (
                record.localFileName as NSString
            ).pathExtension
            fileExtension = pathExtension.isEmpty ? nil : pathExtension
        }
        return DownloadRequest(
            identity: record.identity,
            versionID: record.versionID,
            versionLabel: record.versionLabel,
            groupID: record.groupID,
            batchID: record.batchID,
            batchKind: record.batchKind,
            batchTitle: record.batchTitle,
            batchExpectedCount: record.batchExpectedCount,
            expectedBytes: record.quality == .original
                ? record.totalBytes
                : Self.estimatedRenditionBytes(
                    runtime: record.snapshot.runtime,
                    quality: record.quality
                ),
            sourceKind: record.sourceKind,
            quality: record.quality,
            directShareSource: record.directShareSource,
            managedHTTPSource: managedSource,
            contentType: record.contentType,
            fileExtension: fileExtension,
            snapshot: record.snapshot
        )
    }

    static func estimatedRenditionBytes(
        runtime: TimeInterval?,
        quality: DownloadQuality
    ) -> Int64? {
        guard let runtime, runtime > 0,
              case .constrained(let constraint) = quality else {
            return nil
        }
        let audioAndContainerBitsPerSecond = 256_000.0
        let estimatedBits = runtime
            * (Double(constraint.maximumVideoBitrateBps) + audioAndContainerBitsPerSecond)
        return Int64((estimatedBits / 8).rounded(.up))
    }

    private static func invalidateLegacyPlexRenditions(
        in registry: DownloadedMediaRegistry
    ) async {
        for record in await registry.all()
        where record.status == .completed
            && record.quality != .original
            && record.managedHTTPSource?.provider == .plex
            && record.localFileName.lowercased().hasSuffix(".mkv") {
            try? await registry.setStatus(
                identityKey: record.identityKey,
                .failed,
                failureReason: "This older Plex rendition may be incomplete. Resume to download a verified copy."
            )
        }
    }

    func pause(_ records: [DownloadedMediaRecord]) async {
        for record in records where record.status != .completed {
            await queue?.pause(identityKey: record.identityKey)
        }
        await reload()
    }

    func resume(_ records: [DownloadedMediaRecord]) async {
        for record in records where record.status == .paused || record.status == .failed {
            await resumeWithoutReload(record)
        }
        await reload()
    }

    func pauseBatch(_ batchID: String) async {
        await queue?.pause(batchID: batchID)
        await reload()
    }

    func resumeBatch(_ batchID: String) async {
        for record in records
        where record.batchID == batchID
            && (record.status == .paused || record.status == .failed) {
            await resumeWithoutReload(record)
        }
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
                || $0.status == .preparing
                || $0.status == .paused
        }
    }

    var hasActiveTransfers: Bool { !activeTransfers.isEmpty }

    var remainingActiveBytes: Int64? {
        guard activeTransfers.allSatisfy({ $0.status == .downloading }) else {
            return nil
        }
        let known = activeTransfers.compactMap { record -> Int64? in
            guard let total = record.totalBytes, total > 0 else { return nil }
            return max(0, total - record.bytesDownloaded)
        }
        guard known.count == activeTransfers.count else { return nil }
        return known.reduce(0, +)
    }

    var aggregateETA: TimeInterval? {
        guard aggregateBytesPerSecond > 0,
              let remainingActiveBytes else {
            return nil
        }
        return TimeInterval(remainingActiveBytes)
            / TimeInterval(aggregateBytesPerSecond)
    }

    var activeLimitDescription: LocalizedStringResource {
        if let limit = maximumDownloadMegabitsPerSecond {
            return "\(limit.formatted()) Mbps limit"
        }
        return "No speed limit"
    }

    func transferMetrics(
        for record: DownloadedMediaRecord
    ) -> TransferMetrics? {
        transferMetricsByKey[record.identityKey]
    }

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
        where record.status == .downloading
            || record.status == .preparing
            || record.status == .queued {
            await queue.pause(identityKey: record.identityKey)
        }
        await reload()
    }

    /// Resumes every paused or failed download.
    func resumeAllPaused() async {
        guard queue != nil else { return }
        for record in records
        where record.status == .paused || record.status == .failed {
            await resumeWithoutReload(record)
        }
        await reload()
    }

    func setApplicationActive(_ isActive: Bool) async {
        applicationIsActive = isActive
        guard acceptsNewWork else { return }
        guard let queue else { return }
        applicationActivityGeneration += 1
        let generation = applicationActivityGeneration
        let currentRecords = await registry?.all() ?? records
        guard applicationTransitionIsCurrent(generation) else { return }
        if isActive {
            if isUsingUncappedBackgroundPolicy {
                for record in currentRecords
                where record.sourceKind == .managedHTTP
                    && record.status.isActive {
                    guard applicationTransitionIsCurrent(generation) else {
                        return
                    }
                    await queue.pause(
                        identityKey: record.identityKey,
                        reason: .backgroundPolicy
                    )
                    await queue.discardPersistentWork(
                        identityKey: record.identityKey
                    )
                }
                guard applicationTransitionIsCurrent(generation) else { return }
                await queue.updatePolicy(policy)
                guard applicationTransitionIsCurrent(generation) else { return }
                await enforceSpeedLimitPausePolicy()
                guard applicationTransitionIsCurrent(generation) else { return }
                await queue.resumePaused(reason: .backgroundPolicy)
                guard applicationTransitionIsCurrent(generation) else { return }
                isUsingUncappedBackgroundPolicy = false
                defaults?.set(false, forKey: uncappedBackgroundPolicyKey)
            }
            guard applicationTransitionIsCurrent(generation) else { return }
            await enforceSpeedLimitPausePolicy()
            guard applicationTransitionIsCurrent(generation) else { return }
            if policy.maximumBytesPerSecond == nil {
                await queue.resumePaused(reason: .speedLimitPolicy)
                guard applicationTransitionIsCurrent(generation) else { return }
            }
            await queue.resumeInterrupted()
            guard applicationTransitionIsCurrent(generation) else { return }
            await queue.resumePaused(reason: .inactiveProfile)
            guard applicationTransitionIsCurrent(generation) else { return }
            await queue.resumePaused(reason: .directShareBackground)
            guard applicationTransitionIsCurrent(generation) else { return }
            await queue.resumePaused(reason: .backgroundPolicy)
            guard applicationTransitionIsCurrent(generation) else { return }
            await reload()
            return
        }

        if policy.maximumBytesPerSecond != nil,
           policy.cappedBackgroundBehavior == .continueAtFullSpeed {
            var backgroundPolicy = policy
            backgroundPolicy.maximumBytesPerSecond = nil
            for record in currentRecords
            where record.sourceKind == .managedHTTP
                && record.status.isActive {
                guard applicationTransitionIsCurrent(generation) else {
                    return
                }
                await queue.pause(
                    identityKey: record.identityKey,
                    reason: .backgroundPolicy
                )
                await queue.discardPersistentWork(
                    identityKey: record.identityKey
                )
            }
            guard applicationTransitionIsCurrent(generation) else { return }
            await queue.updatePolicy(backgroundPolicy)
            guard applicationTransitionIsCurrent(generation) else { return }
            await queue.resumePaused(reason: .backgroundPolicy)
            guard applicationTransitionIsCurrent(generation) else { return }
            isUsingUncappedBackgroundPolicy = true
            defaults?.set(true, forKey: uncappedBackgroundPolicyKey)
        }

        for record in currentRecords where record.status.isActive {
            guard applicationTransitionIsCurrent(generation) else { return }
            switch record.sourceKind {
            case .directShare:
                await queue.pause(
                    identityKey: record.identityKey,
                    reason: .directShareBackground
                )
            case .managedHTTP
                where policy.maximumBytesPerSecond != nil
                    && policy.cappedBackgroundBehavior == .pause:
                await queue.pause(
                    identityKey: record.identityKey,
                    reason: .backgroundPolicy
                )
            case .managedHTTP:
                break
            }
        }
        guard applicationTransitionIsCurrent(generation) else { return }
        await reload()
    }

    private func applicationTransitionIsCurrent(_ generation: Int) -> Bool {
        !Task.isCancelled && generation == applicationActivityGeneration
    }

    private func mustRemainPausedForSpeedLimit(
        _ record: DownloadedMediaRecord
    ) -> Bool {
        guard policy.maximumBytesPerSecond != nil,
              record.quality != .original,
              let provider = record.managedHTTPSource?.provider else {
            return false
        }
        return provider == .jellyfin || provider == .emby
    }

    private func enforceSpeedLimitPausePolicy() async {
        guard let queue, policy.maximumBytesPerSecond != nil else { return }
        for record in await registry?.all() ?? []
        where mustRemainPausedForSpeedLimit(record)
            && (record.status.isActive
                || record.pauseReason == .inactiveProfile
                || record.pauseReason == .networkPolicy
                || record.pauseReason == .backgroundPolicy
                || record.pauseReason == .directShareBackground) {
            await queue.pause(
                identityKey: record.identityKey,
                reason: .speedLimitPolicy
            )
        }
    }

    private func beginEnqueue() throws {
        guard acceptsNewWork else {
            throw PlozziOSDownloadError.unavailable(
                "The active profile changed. Try the download again."
            )
        }
        inFlightEnqueueCount += 1
    }

    private func finishEnqueue() {
        precondition(inFlightEnqueueCount > 0)
        inFlightEnqueueCount -= 1
        guard inFlightEnqueueCount == 0 else { return }
        let waiters = enqueueDrainWaiters
        enqueueDrainWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func reload() async {
        let refreshed = (await registry?.all() ?? [])
            .sorted { $0.updatedAt > $1.updatedAt }
        if hasLoadedRecords {
            notifyForTransitions(from: recordsByKey, to: refreshed)
        }
        sampleTransferSpeed(refreshed)
        records = refreshed
        hasLoadedRecords = true
    }

    private func persistPolicy(restartActiveManagedDownloads: Bool = false) {
        guard let queue else { return }
        if let data = try? JSONEncoder().encode(policy) {
            defaults?.set(data, forKey: policyKey)
        }
        Task {
            guard acceptsNewWork else { return }
            let active = restartActiveManagedDownloads
                ? records.filter {
                    $0.sourceKind == .managedHTTP && $0.status.isActive
                }
                : []
            if restartActiveManagedDownloads {
                for record in active {
                    await queue.pause(
                        identityKey: record.identityKey,
                        reason: .backgroundPolicy
                    )
                    await queue.discardPersistentWork(
                        identityKey: record.identityKey
                    )
                }
            }
            guard acceptsNewWork else { return }
            await queue.updatePolicy(policy)
            guard acceptsNewWork else { return }
            await enforceSpeedLimitPausePolicy()
            guard acceptsNewWork else { return }
            if restartActiveManagedDownloads {
                if policy.maximumBytesPerSecond != nil {
                    for record in active where
                        record.quality != .original
                            && record.managedHTTPSource?.provider != .plex {
                        await queue.pause(
                            identityKey: record.identityKey,
                            reason: .speedLimitPolicy
                        )
                    }
                } else {
                    await queue.resumePaused(reason: .speedLimitPolicy)
                }
                await queue.resumePaused(reason: .backgroundPolicy)
                await reload()
            }
        }
    }

    private func persistPreferences() {
        guard let defaults else { return }
        let preferences = PlozziOSDownloadPreferences(
            asksBeforeDownloading: asksBeforeDownloading,
            notifiesOnStandaloneCompletion: notifiesOnStandaloneCompletion,
            notifiesOnBatchCompletion: notifiesOnBatchCompletion,
            notifiesOnFailure: notifiesOnFailure
        )
        if let data = try? JSONEncoder().encode(preferences) {
            defaults.set(data, forKey: preferencesKey)
        }
        if preferences.notificationsEnabled {
            Task {
                _ = try? await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound])
            }
        }
    }

    private func notifyForTransitions(
        from previous: [String: DownloadedMediaRecord],
        to refreshed: [DownloadedMediaRecord]
    ) {
        for record in refreshed {
            let oldStatus = previous[record.identityKey]?.status
            if record.status == .failed,
               oldStatus != .failed,
               notifiesOnFailure {
                scheduleNotification(
                    title: "Download Failed",
                    body: "\(record.snapshot.title) could not be downloaded."
                )
            }
            if record.status == .completed,
               oldStatus != .completed,
               record.batchID == nil,
               notifiesOnStandaloneCompletion {
                scheduleNotification(
                    title: "Download Complete",
                    body: "\(record.snapshot.title) is available offline."
                )
            }
        }

        guard notifiesOnBatchCompletion else { return }
        let batches = Dictionary(
            grouping: refreshed.compactMap { record in
                record.batchID.map { ($0, record) }
            },
            by: \.0
        )
        for (batchID, members) in batches
        where !notifiedBatchIDs.contains(batchID) {
            let records = members.map(\.1)
            guard let expected = records.first?.batchExpectedCount,
                  records.count >= expected,
                  records.allSatisfy({ $0.status == .completed }),
                  records.contains(where: {
                      previous[$0.identityKey]?.status != .completed
                  }) else {
                continue
            }
            notifiedBatchIDs.insert(batchID)
            let body: LocalizedStringResource
            if let title = records.first?.batchTitle {
                body = "\(title) is available offline."
            } else {
                body = "Downloads are available offline."
            }
            scheduleNotification(
                title: "Download Complete",
                body: body
            )
        }
    }

    private func scheduleNotification(
        title: LocalizedStringResource,
        body: LocalizedStringResource
    ) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: title) // l10n:content — notification API requires resolved text
        content.body = String(localized: body) // l10n:content — notification API requires resolved text
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private func sampleTransferSpeed(
        _ refreshed: [DownloadedMediaRecord]
    ) {
        let active = refreshed.filter { $0.status == .downloading }
        guard !active.isEmpty else {
            metricsExpiryTask?.cancel()
            metricsExpiryTask = nil
            speedSample = nil
            speedSamplesByKey = [:]
            transferMetricsByKey = [:]
            aggregateBytesPerSecond = 0
            return
        }
        let now = Date()
        let activeKeys = Set(active.map(\.identityKey))
        speedSamplesByKey = speedSamplesByKey.filter {
            activeKeys.contains($0.key)
        }
        var metrics = transferMetricsByKey.filter {
            activeKeys.contains($0.key)
        }
        for record in active {
            if let sample = speedSamplesByKey[record.identityKey] {
                let interval = now.timeIntervalSince(sample.date)
                if interval >= 0.4 {
                    let speed = max(
                        0,
                        Int64(
                            Double(record.bytesDownloaded - sample.bytes)
                                / interval
                        )
                    )
                    let eta: TimeInterval?
                    if speed > 0,
                       let total = record.totalBytes,
                       total > record.bytesDownloaded {
                        eta = TimeInterval(total - record.bytesDownloaded)
                            / TimeInterval(speed)
                    } else {
                        eta = nil
                    }
                    metrics[record.identityKey] = TransferMetrics(
                        bytesPerSecond: speed,
                        estimatedTimeRemaining: eta
                    )
                    speedSamplesByKey[record.identityKey] = (
                        now,
                        record.bytesDownloaded
                    )
                }
            } else {
                speedSamplesByKey[record.identityKey] = (
                    now,
                    record.bytesDownloaded
                )
            }
        }
        transferMetricsByKey = metrics
        aggregateBytesPerSecond = metrics.values.reduce(0) {
            $0 + $1.bytesPerSecond
        }
        metricsExpiryTask?.cancel()
        metricsExpiryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            self?.transferMetricsByKey = [:]
            self?.aggregateBytesPerSecond = 0
        }

        let bytes = active.reduce(0) { $0 + $1.bytesDownloaded }
        if let speedSample {
            let interval = now.timeIntervalSince(speedSample.date)
            if interval >= 0.4 {
                self.speedSample = (now, bytes)
            }
        } else {
            speedSample = (now, bytes)
        }
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

    private static func loadPreferences(
        key: String
    ) -> PlozziOSDownloadPreferences {
        guard let data = UserDefaults.standard.data(forKey: key),
              let preferences = try? JSONDecoder().decode(
                PlozziOSDownloadPreferences.self,
                from: data
              ) else {
            return .default
        }
        return preferences
    }

    private static func loadRenditionCapabilities(
        key: String
    ) -> [String: RenditionCapability] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let capabilities = try? JSONDecoder().decode(
                  [String: RenditionCapability].self,
                  from: data
              ) else {
            return [:]
        }
        return capabilities
    }
}

private struct PlozziOSDownloadPreferences: Codable {
    var asksBeforeDownloading: Bool
    var notifiesOnStandaloneCompletion: Bool
    var notifiesOnBatchCompletion: Bool
    var notifiesOnFailure: Bool

    static let `default` = PlozziOSDownloadPreferences(
        asksBeforeDownloading: true,
        notifiesOnStandaloneCompletion: false,
        notifiesOnBatchCompletion: false,
        notifiesOnFailure: false
    )

    var notificationsEnabled: Bool {
        notifiesOnStandaloneCompletion
            || notifiesOnBatchCompletion
            || notifiesOnFailure
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
