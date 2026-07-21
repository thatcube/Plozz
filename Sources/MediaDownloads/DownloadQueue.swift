import CoreModels
import Foundation

/// The transport-agnostic download orchestrator: turns ``DownloadRequest``s into
/// durable, resumable downloads, draining them with bounded concurrency while
/// honoring the network/data-saver policy.
///
/// It composes the pieces and owns none of their internals: the ``DownloadedMediaRegistry``
/// owns state, a ``MediaDownloadEngine`` moves bytes, ``DownloadStorageLocating``
/// owns paths, and ``DownloadNetworkObserving`` + ``DownloadNetworkPolicy`` gate
/// progress. Groups (seasons) are just many requests sharing a `groupID`.
public actor DownloadQueue {
    private let registry: DownloadedMediaRegistry
    private let storage: any DownloadStorageLocating
    private let engine: any MediaDownloadEngine
    private let observer: any DownloadNetworkObserving
    private let fileManager: FileManager
    private var policy: DownloadNetworkPolicy
    private let limiter: ConcurrencyLimiter

    /// Max retry attempts for a transient (non-cancellation) error before failing.
    private let maxAttempts: Int
    private let backoff: @Sendable (Int) async -> Void

    private var running: [String: Task<Void, Never>] = [:]

    public init(
        registry: DownloadedMediaRegistry,
        storage: any DownloadStorageLocating,
        engine: any MediaDownloadEngine,
        observer: any DownloadNetworkObserving = StaticDownloadNetworkObserver(),
        policy: DownloadNetworkPolicy = .default,
        fileManager: FileManager = .default,
        maxAttempts: Int = 3,
        backoff: @escaping @Sendable (Int) async -> Void = { attempt in
            let seconds = min(30, pow(2.0, Double(attempt)))
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    ) {
        self.registry = registry
        self.storage = storage
        self.engine = engine
        self.observer = observer
        self.policy = policy
        self.fileManager = fileManager
        self.maxAttempts = max(1, maxAttempts)
        self.backoff = backoff
        self.limiter = ConcurrencyLimiter(limit: policy.maxConcurrentDownloads)
        (engine as? any DownloadPolicyApplying)?.applyDownloadPolicy(policy)
    }

    /// Updates the active policy (e.g. the user toggled Wi‑Fi‑only). Applies to
    /// the next scheduling decision; the concurrency cap is fixed at init.
    public func updatePolicy(_ policy: DownloadNetworkPolicy) {
        self.policy = policy
        (engine as? any DownloadPolicyApplying)?.applyDownloadPolicy(policy)
    }

    // MARK: - Enqueue

    /// Enqueues a single download. Idempotent: re-enqueuing an in-flight or
    /// completed identity is a no-op beyond refreshing reopen info.
    @discardableResult
    public func enqueue(_ request: DownloadRequest) async throws -> DownloadedMediaRecord {
        let record = makeRecord(for: request)
        // Idempotency: the `.downloading`/`.queued` marker is persisted BEFORE any
        // byte is fetched, so a kill leaves a recoverable record.
        let stored = try await registry.beginDownload(record)
        if stored.status != .completed {
            schedule(stored.identityKey)
        }
        return stored
    }

    /// Enqueues a whole group (e.g. a season) under one `groupID`.
    @discardableResult
    public func enqueueGroup(_ requests: [DownloadRequest]) async throws -> [DownloadedMediaRecord] {
        let stored = try await registry.beginDownloads(
            requests.map(makeRecord(for:))
        )
        for record in stored where record.status != .completed {
            schedule(record.identityKey)
        }
        return stored
    }

    private func makeRecord(
        for request: DownloadRequest
    ) -> DownloadedMediaRecord {
        DownloadedMediaRecord(
            identity: request.identity,
            groupID: request.groupID,
            sourceKind: request.sourceKind,
            quality: request.quality,
            status: .queued,
            directShareSource: request.directShareSource,
            managedHTTPSource: request.managedHTTPSource,
            localFileName: request.makeLocalFileName(),
            contentType: request.contentType,
            snapshot: request.snapshot
        )
    }

    // MARK: - Controls

    public func pause(identityKey: String) async {
        running[identityKey]?.cancel()
    }

    public func resume(identityKey: String) async {
        guard let record = await registry.record(forKey: identityKey),
              record.status != .completed else { return }
        if record.status == .failed {
            try? await registry.setStatus(identityKey: identityKey, .queued)
        }
        schedule(identityKey)
    }

    public func cancelAndRemove(identityKey: String) async throws {
        running[identityKey]?.cancel()
        running[identityKey] = nil
        if let folder = try? storage.pinnedFolderURL(forKey: identityKey) {
            try? fileManager.removeItem(at: folder)
        }
        try await registry.remove(identityKey: identityKey)
    }

    /// Restarts every resumable (queued/paused/downloading) record that isn't
    /// already running — call on launch or when the network returns.
    public func resumeInterrupted() async {
        for record in await registry.all() where record.status.isActive {
            schedule(record.identityKey)
        }
    }

    // MARK: - Draining

    private func schedule(_ identityKey: String) {
        guard running[identityKey] == nil else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.limiterRun(identityKey)
        }
        running[identityKey] = task
    }

    private func limiterRun(_ identityKey: String) async {
        await limiter.run { [weak self] in
            await self?.performDownload(identityKey)
        }
        running[identityKey] = nil
    }

    private func performDownload(_ identityKey: String) async {
        guard let record = await registry.record(forKey: identityKey),
              record.status.isActive else { return }

        // Network / data-saver gate.
        let conditions = await observer.currentConditions()
        guard policy.allows(conditions) else {
            try? await registry.setStatus(
                identityKey: identityKey, .paused,
                failureReason: "Waiting for an allowed network"
            )
            return
        }

        // Storage budget: block NEW downloads over the soft cap (never evict).
        if let budget = policy.storageBudgetBytes, await usedBytes() >= budget {
            try? await registry.setStatus(
                identityKey: identityKey, .failed,
                failureReason: "Storage budget reached"
            )
            return
        }

        guard let destination = try? storage.pinnedFileURL(for: record) else {
            try? await registry.setStatus(
                identityKey: identityKey, .failed,
                failureReason: "Download location unavailable"
            )
            return
        }

        var attempt = 0
        while true {
            do {
                try? await registry.setStatus(identityKey: identityKey, .downloading)
                let registry = self.registry
                let total = try await engine.download(
                    record: record,
                    to: destination
                ) { bytes, total in
                    try? await registry.updateProgress(
                        identityKey: identityKey,
                        bytesDownloaded: bytes,
                        totalBytes: total
                    )
                }
                try? await registry.markCompleted(identityKey: identityKey, totalBytes: total)
                return
            } catch is CancellationError {
                try? await registry.setStatus(
                    identityKey: identityKey, .paused,
                    failureReason: "Paused"
                )
                return
            } catch {
                attempt += 1
                if attempt >= maxAttempts {
                    try? await registry.setStatus(
                        identityKey: identityKey, .failed,
                        failureReason: String(describing: error)
                    )
                    return
                }
                await backoff(attempt)
                if Task.isCancelled {
                    try? await registry.setStatus(
                        identityKey: identityKey, .paused,
                        failureReason: "Paused"
                    )
                    return
                }
            }
        }
    }

    private func usedBytes() async -> Int64 {
        await registry.all().reduce(Int64(0)) { $0 + $1.bytesDownloaded }
    }

    #if DEBUG
    /// Test hook: awaits every in-flight drain task so tests can assert terminal
    /// state deterministically. Not for production use.
    func drainForTesting() async {
        let tasks = Array(running.values)
        for task in tasks { await task.value }
    }
    #endif
}
