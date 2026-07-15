import Foundation
import CoreModels

public enum SearchIndexPausedReason: String, Sendable {
    case background
    case playback
    case shareScan
    case interactive
}

public struct SearchIndexLibrarySource: Sendable {
    public let libraryID: String
    public let kinds: [MediaItemKind]

    public init(libraryID: String, kinds: [MediaItemKind]) {
        self.libraryID = libraryID
        self.kinds = kinds
    }
}

public struct SearchIndexSource: Sendable {
    public let accountID: String
    public let providerUserKey: String
    public let provider: any SearchCatalogProviding
    public let libraries: [SearchIndexLibrarySource]

    public init(
        accountID: String,
        providerUserKey: String,
        provider: any SearchCatalogProviding,
        libraries: [SearchIndexLibrarySource]
    ) {
        self.accountID = accountID
        self.providerUserKey = providerUserKey
        self.provider = provider
        self.libraries = libraries
    }
}

public struct SearchIndexStatus: Equatable, Sendable {
    public let documentCount: Int
    public let databaseBytes: UInt64
    public let isBuilding: Bool
    public let queuedScopes: Int
    public let pausedReason: SearchIndexPausedReason?

    public init(
        documentCount: Int = 0,
        databaseBytes: UInt64 = 0,
        isBuilding: Bool = false,
        queuedScopes: Int = 0,
        pausedReason: SearchIndexPausedReason? = nil
    ) {
        self.documentCount = documentCount
        self.databaseBytes = databaseBytes
        self.isBuilding = isBuilding
        self.queuedScopes = queuedScopes
        self.pausedReason = pausedReason
    }
}

public actor SearchIndexAdmissionController: SearchIndexResourceAdmitting {
    private var isForeground = true
    private var interactiveUntil = Date.distantPast
    private(set) var pausedReason: SearchIndexPausedReason?

    public init() {}

    public func setForeground(_ value: Bool) {
        isForeground = value
    }

    public func noteInteractiveActivity(cooldown: TimeInterval = 1.5) {
        interactiveUntil = Date().addingTimeInterval(cooldown)
    }

    public func waitForSearchIndexing() async throws {
        while true {
            try Task.checkCancellation()
            let reason = currentPauseReason()
            pausedReason = reason
            guard reason != nil else { return }
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    private func currentPauseReason() -> SearchIndexPausedReason? {
        guard isForeground else { return .background }
        if PlaybackActivity.isActive { return .playback }
        let share = ShareBackgroundActivity.snapshot()
        if share.scans > 0 || share.enrichPasses > 0 || share.activeListers > 0 {
            return .shareScan
        }
        if Date() < interactiveUntil { return .interactive }
        return nil
    }
}

public actor SearchIndexCoordinator {
    private let indexFactory: @Sendable (String) -> LocalSearchIndex
    private let embeddingProvider: any SentenceEmbeddingProviding
    private let languageDetector: any SearchLanguageDetecting
    private let admission: SearchIndexAdmissionController
    private let policy: SearchCatalogIndexingPolicy
    private let tuning: SearchRankingTuning

    private var profileKey = "default"
    private var index: LocalSearchIndex
    private var scanTask: Task<Void, Never>?
    private var isBuilding = false
    private var queuedScopes = 0
    private var lastSources: [SearchIndexSource] = []
    private var lastRetainingAccountIDs: Set<String> = []
    private var reconcileGeneration = 0

    public init(
        indexFactory: @escaping @Sendable (String) -> LocalSearchIndex = {
            LocalSearchIndex(scopeKey: $0)
        },
        embeddingProvider: any SentenceEmbeddingProviding = AppleSentenceEmbeddingProvider(),
        languageDetector: any SearchLanguageDetecting = AppleSearchLanguageDetector(),
        admission: SearchIndexAdmissionController = SearchIndexAdmissionController(),
        policy: SearchCatalogIndexingPolicy = SearchCatalogIndexingPolicy(),
        tuning: SearchRankingTuning = .default
    ) {
        self.indexFactory = indexFactory
        self.embeddingProvider = embeddingProvider
        self.languageDetector = languageDetector
        self.admission = admission
        self.policy = policy
        self.tuning = tuning
        index = indexFactory("default")
    }

    deinit {
        scanTask?.cancel()
    }

    public func activate(profileNamespace: String?) async {
        let nextKey = profileNamespace ?? "default"
        guard nextKey != profileKey else { return }
        await cancelScan()
        await index.releaseVectorCache()
        profileKey = nextKey
        index = indexFactory(nextKey)
    }

    public func reconcile(
        profileNamespace: String?,
        sources: [SearchIndexSource],
        retainingAccountIDs: Set<String>,
        providerUserKeysByAccount: [String: String]
    ) async {
        reconcileGeneration &+= 1
        let generation = reconcileGeneration
        await activate(profileNamespace: profileNamespace)
        guard generation == reconcileGeneration else { return }
        await cancelScan()
        guard generation == reconcileGeneration else { return }
        lastSources = sources
        lastRetainingAccountIDs = retainingAccountIDs
        let reconciledAccountIDs = Set(sources.map(\.accountID))
        let activeLibraryKeys = Set(sources.flatMap { source in
            source.libraries.map { "\(source.accountID):\($0.libraryID)" }
        })
        try? await index.retainOnly(
            accountIDs: retainingAccountIDs,
            reconciledAccountIDs: reconciledAccountIDs,
            libraryKeys: activeLibraryKeys,
            providerUserKeysByAccount: providerUserKeysByAccount
        )
        guard generation == reconcileGeneration else { return }
        let index = self.index
        let admission = self.admission
        let embeddingProvider = self.embeddingProvider
        let languageDetector = self.languageDetector
        let policy = self.policy
        let allScopes = sources.flatMap { source in
            source.libraries.flatMap { library in
                library.kinds.map { kind in
                    (
                        source.provider,
                        SearchScanScope(
                            accountID: source.accountID,
                            providerUserKey: source.providerUserKey,
                            libraryID: library.libraryID,
                            kind: kind
                        )
                    )
                }
            }
        }
        var scopes: [(any SearchCatalogProviding, SearchScanScope)] = []
        for (provider, scope) in allScopes {
            if (try? await index.needsFullScan(
                scope: scope,
                refreshInterval: policy.fullRefreshInterval
            )) != false {
                scopes.append((provider, scope))
            }
        }
        guard generation == reconcileGeneration else { return }
        queuedScopes = scopes.count
        isBuilding = !scopes.isEmpty
        scanTask?.cancel()
        scanTask = Task(priority: .utility) { [weak self] in
            if let descriptor = await embeddingProvider.descriptor(for: .english) {
                _ = try? await index.warm(descriptor: descriptor)
            }
            guard !Task.isCancelled,
                  let writeToken = await self?.activateWriteGeneration(
                      for: generation,
                      index: index
                  ) else {
                return
            }
            for (provider, scope) in scopes {
                guard !Task.isCancelled else { break }
                let indexer = SearchCatalogIndexer(
                    provider: provider,
                    index: index,
                    embeddingProvider: embeddingProvider,
                    languageDetector: languageDetector,
                    admission: admission,
                    policy: policy
                )
                do {
                    _ = try await indexer.index(scope: scope, writeToken: writeToken)
                } catch is CancellationError {
                    break
                } catch {
                    // A changing provider total or temporary outage leaves the
                    // checkpoint intact for the next foreground reconciliation.
                }
                await self?.scopeFinished(generation: generation)
            }
            await self?.scanFinished(generation: generation)
        }
    }

    private func activateWriteGeneration(
        for generation: Int,
        index: LocalSearchIndex
    ) async -> UUID? {
        guard generation == reconcileGeneration, !Task.isCancelled else {
            return nil
        }
        let token = await index.activateWriteGeneration()
        guard generation == reconcileGeneration, !Task.isCancelled else {
            return nil
        }
        return token
    }

    public func semanticSearch(
        query: String,
        excludedLibraryKeys: Set<String>,
        limit: Int = 40,
        minimumScore: Float? = nil
    ) async -> [MediaItem] {
        await admission.noteInteractiveActivity()
        guard let language = await languageDetector
            .hypotheses(for: query, maximumCount: 1).first,
              let descriptor = await embeddingProvider.descriptor(for: language),
              let vector = await embeddingProvider.vector(
                for: query,
                using: descriptor
              ) else {
            return []
        }
        let intent = LocalSearchIntentParser().parse(query)
        let matches = try? await index.search(LocalSearchRequest(
            queryText: query,
            queryVector: vector,
            descriptor: descriptor,
            intent: intent,
            excludedLibraryKeys: excludedLibraryKeys,
            limit: limit,
            minimumSemanticScore: minimumScore ?? tuning.minimumSemanticScore,
            rankingWeights: tuning.weights
        ))
        return matches?.map(\.item) ?? []
    }

    public func setForeground(_ value: Bool) async {
        await admission.setForeground(value)
        if !value {
            await index.releaseVectorCache()
        }
    }

    public func handleMemoryPressure() async {
        await index.releaseVectorCache()
    }

    public func purge(accountID: String) async {
        await cancelScan()
        try? await index.remove(accountID: accountID)
    }

    public func purgeAll() async {
        await cancelScan()
        try? await index.removeAll()
    }

    public func removeProfile(profileNamespace: String?) async {
        let key = profileNamespace ?? "default"
        if key == profileKey {
            reconcileGeneration &+= 1
            await cancelScan()
            try? await index.deleteCacheFiles()
            profileKey = "__removed__"
            index = indexFactory("__removed__")
        } else {
            let retired = indexFactory(key)
            try? await retired.deleteCacheFiles()
        }
    }

    public func rebuild() async {
        await cancelScan()
        try? await index.removeAll()
        let namespace = profileKey == "default" ? nil : profileKey
        await reconcile(
            profileNamespace: namespace,
            sources: lastSources,
            retainingAccountIDs: lastRetainingAccountIDs,
            providerUserKeysByAccount: Dictionary(
                lastSources.map { ($0.accountID, $0.providerUserKey) },
                uniquingKeysWith: { _, latest in latest }
            )
        )
    }

    public func status() async -> SearchIndexStatus {
        let count = (try? await index.documentCount()) ?? 0
        let size = [
            index.databaseURL.path,
            index.databaseURL.path + "-wal",
            index.databaseURL.path + "-shm"
        ].reduce(UInt64(0)) { total, path in
            let value = (try? FileManager.default.attributesOfItem(
                atPath: path
            )[.size] as? NSNumber)?.uint64Value ?? 0
            return total + value
        }

        return SearchIndexStatus(
            documentCount: count,
            databaseBytes: size,
            isBuilding: isBuilding,
            queuedScopes: queuedScopes,
            pausedReason: await admission.pausedReason
        )
    }

    public func building() -> Bool {
        isBuilding
    }

    public func waitForIdle() async {
        await scanTask?.value
    }

    private func cancelScan() async {
        scanTask?.cancel()
        await index.invalidateWriteGeneration()
        scanTask = nil
        isBuilding = false
        queuedScopes = 0
    }

    private func scopeFinished(generation: Int) {
        guard generation == reconcileGeneration else { return }
        queuedScopes = max(0, queuedScopes - 1)
    }

    private func scanFinished(generation: Int) {
        guard generation == reconcileGeneration else { return }
        scanTask = nil
        isBuilding = false
        queuedScopes = 0
    }
}
