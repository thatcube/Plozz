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
    public func updatePolicy(_ policy: DownloadNetworkPolicy) async {
        self.policy = policy
        (engine as? any DownloadPolicyApplying)?.applyDownloadPolicy(policy)
        await networkConditionsDidChange(
            await observer.currentConditions()
        )
    }

    public func networkConditionsDidChange(
        _ conditions: DownloadNetworkConditions
    ) async {
        if policy.allows(conditions) {
            await resumePaused(reason: .networkPolicy)
            return
        }
        for identityKey in Array(running.keys) {
            await pause(identityKey: identityKey, reason: .networkPolicy)
        }
    }

    // MARK: - Enqueue

    /// Enqueues a single download. Idempotent: re-enqueuing an in-flight or
    /// completed identity is a no-op beyond refreshing reopen info.
    @discardableResult
    public func enqueue(_ request: DownloadRequest) async throws -> DownloadedMediaRecord {
        let record = makeRecord(for: request)
        if let existing = await registry.record(forKey: record.identityKey),
           existing.quality != record.quality {
            try await prepareQualityReplacement(
                existing: existing,
                replacement: record
            )
        }
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
        let records = requests.map(makeRecord(for:))
        for record in records {
            if let existing = await registry.record(forKey: record.identityKey),
               existing.quality != record.quality {
                try await prepareQualityReplacement(
                    existing: existing,
                    replacement: record
                )
            }
        }
        let stored = try await registry.beginDownloads(records)
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
            versionID: request.versionID,
            versionLabel: request.versionLabel,
            groupID: request.groupID,
            batchID: request.batchID,
            batchKind: request.batchKind,
            batchTitle: request.batchTitle,
            batchExpectedCount: request.batchExpectedCount,
            sourceKind: request.sourceKind,
            quality: request.quality,
            status: .queued,
            directShareSource: request.directShareSource,
            managedHTTPSource: request.managedHTTPSource,
            localFileName: request.makeLocalFileName(),
            totalBytes: request.expectedBytes,
            contentType: request.contentType,
            snapshot: request.snapshot
        )
    }

    // MARK: - Controls

    public func pause(
        identityKey: String,
        reason: DownloadPauseReason = .manual
    ) async {
        guard let record = await registry.record(forKey: identityKey),
              record.status != .completed else {
            return
        }
        try? await registry.setStatus(
            identityKey: identityKey,
            .paused,
            failureReason: pauseDescription(reason),
            pauseReason: reason
        )
        let task = running[identityKey]
        task?.cancel()
        await task?.value
    }

    public func resume(identityKey: String) async {
        guard let record = await registry.record(forKey: identityKey),
              record.status != .completed else { return }
        try? await registry.setStatus(identityKey: identityKey, .queued)
        schedule(identityKey)
    }

    /// Rebuilds a failed transfer from fresh secret-free source metadata. Unlike
    /// resume, this deliberately discards stale background work and partial bytes.
    @discardableResult
    public func restartFailed(
        _ request: DownloadRequest
    ) async throws -> DownloadedMediaRecord {
        let replacement = makeRecord(for: request)
        guard let existing = await registry.record(
            forKey: replacement.identityKey
        ), existing.status == .failed else {
            return try await enqueue(request)
        }

        if let persistentEngine = engine as? any DownloadPersistentWorkCancelling {
            await persistentEngine.discardPersistentWork(
                identityKey: existing.identityKey
            )
        }
        let task = running[existing.identityKey]
        task?.cancel()
        await task?.value
        running[existing.identityKey] = nil

        let folder = try storage.pinnedFolderURL(
            forKey: existing.identityKey
        )
        for fileName in Set([
            existing.localFileName,
            replacement.localFileName
        ]) {
            let file = folder.appendingPathComponent(fileName)
            try? fileManager.removeItem(at: file)
            try? fileManager.removeItem(
                at: file.appendingPathExtension("source")
            )
            try? fileManager.removeItem(
                at: file.appendingPathExtension("resume")
            )
        }

        let stored = try await registry.beginQualityReplacement(replacement)
        schedule(stored.identityKey)
        return stored
    }

    public func pause(batchID: String, reason: DownloadPauseReason = .manual) async {
        for record in await registry.records(inBatch: batchID)
        where record.status.isActive {
            await pause(identityKey: record.identityKey, reason: reason)
        }
    }

    public func resume(batchID: String) async {
        for record in await registry.records(inBatch: batchID)
        where record.status == .paused || record.status == .failed {
            await resume(identityKey: record.identityKey)
        }
    }

    public func resumePaused(reason: DownloadPauseReason) async {
        for record in await registry.all()
        where record.status == .paused && record.pauseReason == reason {
            await resume(identityKey: record.identityKey)
        }
    }

    public func cancelAndRemove(identityKey: String) async throws {
        if let persistentEngine = engine as? any DownloadPersistentWorkCancelling {
            await persistentEngine.discardPersistentWork(identityKey: identityKey)
        }
        let task = running[identityKey]
        task?.cancel()
        await task?.value
        running[identityKey] = nil
        if let folder = try? storage.pinnedFolderURL(forKey: identityKey) {
            try? fileManager.removeItem(at: folder)
        }
        if let backup = try? storage.replacementBackupFolderURL(
            forKey: identityKey
        ) {
            try? fileManager.removeItem(at: backup)
        }
        try await registry.remove(identityKey: identityKey)
    }

    public func discardPersistentWork(identityKey: String) async {
        guard let persistentEngine = engine as? any DownloadPersistentWorkCancelling else {
            return
        }
        await persistentEngine.discardPersistentWork(identityKey: identityKey)
    }

    /// Restarts work interrupted by process termination. Explicitly paused records
    /// stay paused until the corresponding user/policy action resumes them.
    public func resumeInterrupted() async {
        for record in await registry.all() where record.status.isActive {
            if record.status != .queued {
                try? await registry.setStatus(
                    identityKey: record.identityKey,
                    .queued
                )
            }
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
        _ = await limiter.runUnlessCancelled { [weak self] in
            guard !Task.isCancelled else { return }
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
                failureReason: "Waiting for an allowed network",
                pauseReason: .networkPolicy
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
        try? fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if let totalBytes = record.totalBytes,
           let freeBytes = try? destination.deletingLastPathComponent()
            .resourceValues(forKeys: [
                .volumeAvailableCapacityKey
            ])
            .volumeAvailableCapacity,
           max(0, totalBytes - record.bytesDownloaded) > Int64(freeBytes) {
            try? await registry.setStatus(
                identityKey: identityKey,
                .failed,
                failureReason: "Not enough device storage"
            )
            return
        }

        var attempt = 0
        while true {
            do {
                guard let currentRecord = await registry.record(
                    forKey: identityKey
                ) else {
                    return
                }
                try? await registry.setStatus(
                    identityKey: identityKey,
                    currentRecord.quality == .original
                        ? .downloading
                        : .preparing
                )
                let registry = self.registry
                let total = try await engine.download(
                    record: currentRecord,
                    to: destination
                ) { bytes, total in
                    if bytes > 0,
                       await registry.record(forKey: identityKey)?.status == .preparing {
                        try? await registry.setStatus(
                            identityKey: identityKey,
                            .downloading
                        )
                    }
                    try? await registry.updateProgress(
                        identityKey: identityKey,
                        bytesDownloaded: bytes,
                        totalBytes: total > 0 ? total : nil
                    )
                }
                try? await registry.markCompleted(identityKey: identityKey, totalBytes: total)
                if let backup = try? storage.replacementBackupFolderURL(
                    forKey: identityKey
                ) {
                    try? fileManager.removeItem(at: backup)
                }
                return
            } catch is CancellationError {
                if await registry.record(forKey: identityKey)?.status != .paused {
                    try? await registry.setStatus(
                        identityKey: identityKey,
                        .paused,
                        failureReason: "Paused",
                        pauseReason: .manual
                    )
                }
                return
            } catch {
                attempt += 1
                if attempt >= maxAttempts {
                    try? await registry.setStatus(
                        identityKey: identityKey, .failed,
                        failureReason: error.localizedDescription
                    )
                    return
                }
                await backoff(attempt)
                if Task.isCancelled {
                    if await registry.record(forKey: identityKey)?.status != .paused {
                        try? await registry.setStatus(
                            identityKey: identityKey,
                            .paused,
                            failureReason: "Paused",
                            pauseReason: .manual
                        )
                    }
                    return
                }
            }
        }
    }

    private func prepareQualityReplacement(
        existing: DownloadedMediaRecord,
        replacement: DownloadedMediaRecord
    ) async throws {
        if let persistentEngine = engine as? any DownloadPersistentWorkCancelling {
            await persistentEngine.discardPersistentWork(
                identityKey: existing.identityKey
            )
        }
        let task = running[existing.identityKey]
        task?.cancel()
        await task?.value
        running[existing.identityKey] = nil

        let folder = try storage.pinnedFolderURL(forKey: existing.identityKey)
        let backup = try storage.replacementBackupFolderURL(
            forKey: existing.identityKey
        )
        if existing.status == .completed {
            let hasFolder = fileManager.fileExists(atPath: folder.path)
            let hasBackup = fileManager.fileExists(atPath: backup.path)
            if hasFolder {
                if hasBackup {
                    try fileManager.removeItem(at: backup)
                }
                let recordURL = folder.appendingPathComponent(
                    ".record.json",
                    isDirectory: false
                )
                try JSONEncoder().encode(existing).write(
                    to: recordURL,
                    options: .atomic
                )
                try fileManager.moveItem(at: folder, to: backup)
            }
        } else {
            try? fileManager.removeItem(at: folder)
        }

        do {
            _ = try await registry.beginQualityReplacement(replacement)
        } catch {
            if existing.status == .completed,
               fileManager.fileExists(atPath: backup.path) {
                try? fileManager.moveItem(at: backup, to: folder)
            }
            throw error
        }

        if let artworkFileName = replacement.snapshot.artworkFileName {
            let backupArtwork = backup.appendingPathComponent(artworkFileName)
            if fileManager.fileExists(atPath: backupArtwork.path) {
                try fileManager.createDirectory(
                    at: folder,
                    withIntermediateDirectories: true
                )
                try? fileManager.copyItem(
                    at: backupArtwork,
                    to: folder.appendingPathComponent(artworkFileName)
                )
            }
        }
    }

    private func usedBytes() async -> Int64 {
        await registry.all().reduce(Int64(0)) { $0 + $1.bytesDownloaded }
    }

    private func pauseDescription(_ reason: DownloadPauseReason) -> String {
        switch reason {
        case .manual:
            "Paused"
        case .networkPolicy:
            "Waiting for an allowed network"
        case .backgroundPolicy:
            "Paused while Plozz is in the background"
        case .directShareBackground:
            "This server connection resumes when Plozz is open"
        }
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
