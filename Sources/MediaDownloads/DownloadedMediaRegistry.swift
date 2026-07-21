import CoreModels
import Foundation

/// The single source of truth for what is downloaded / downloading, backed by a
/// durable, non-evictable store and keyed by cross-server ``MediaIdentity``.
///
/// Idempotency guarantee: ``beginDownload(_:)`` persists a `.downloading` (or
/// `.queued`) record **before** any byte is fetched, so a hard kill always leaves
/// a recoverable, resumable record. All mutations are serialized on the actor and
/// flushed to the store synchronously.
public actor DownloadedMediaRegistry {
    private let store: any DownloadedMediaStoring
    private var state: DownloadedMediaRegistryState

    private var continuations: [UUID: AsyncStream<DownloadProgressEvent>.Continuation] = [:]

    public init(store: any DownloadedMediaStoring) {
        self.store = store
        self.state = store.load()
    }

    // MARK: - Observation

    /// A live stream of progress/status events. Each subscriber gets its own
    /// stream; the caller keeps it alive for as long as it wants updates.
    public func events() -> AsyncStream<DownloadProgressEvent> {
        AsyncStream { continuation in
            let id = UUID()
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }

    private func emit(_ event: DownloadProgressEvent) {
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

    // MARK: - Reads

    public func all() -> [DownloadedMediaRecord] {
        Array(state.records.values)
    }

    public func record(forKey identityKey: String) -> DownloadedMediaRecord? {
        state.records[identityKey]
    }

    /// The record satisfying any of an item's cross-server identities, if present.
    public func record(for item: MediaItem) -> DownloadedMediaRecord? {
        for identity in MediaItemIdentity.identities(for: item) {
            if let record = state.records[MediaIdentityKey.string(for: identity)] {
                return record
            }
        }
        if let identity = DownloadMediaIdentity.primary(for: item) {
            if let record = state.records[MediaIdentityKey.string(for: identity)] {
                return record
            }
        }
        let expectedAccountSource = item.sourceAccountID.map {
            "\(DownloadMediaIdentity.accountSourcePrefix)\($0)"
        }
        let sourceScopedMatches = state.records.values.filter {
            guard case .external(let source, let value) = $0.identity else {
                return false
            }
            guard value == item.id else { return false }
            if let expectedAccountSource {
                return source == expectedAccountSource
            }
            return source.hasPrefix(DownloadMediaIdentity.accountSourcePrefix)
        }
        return sourceScopedMatches.count == 1 ? sourceScopedMatches[0] : nil
    }

    /// The records belonging to a download group (e.g. a season).
    public func records(inGroup groupID: String) -> [DownloadedMediaRecord] {
        state.records.values.filter { $0.groupID == groupID }
    }

    // MARK: - Writes

    /// Persists the initial (or refreshed) record for a download BEFORE fetching
    /// bytes. Idempotent: re-calling for an already-tracked identity preserves its
    /// existing byte progress and pinned file, only refreshing reopen info/status.
    @discardableResult
    public func beginDownload(_ record: DownloadedMediaRecord) throws -> DownloadedMediaRecord {
        var toStore = mergedRecord(
            record,
            existing: state.records[record.identityKey]
        )
        if toStore.status == .completed,
           state.records[record.identityKey]?.status == .completed {
            return toStore
        }
        toStore.updatedAt = Date()
        try persist(toStore)
        return toStore
    }

    /// Atomically accepts a preflighted group before any transfer starts.
    public func beginDownloads(
        _ records: [DownloadedMediaRecord]
    ) throws -> [DownloadedMediaRecord] {
        guard !records.isEmpty else { return [] }
        var nextState = state
        var stored: [DownloadedMediaRecord] = []
        let now = Date()

        for record in records {
            var merged = mergedRecord(
                record,
                existing: nextState.records[record.identityKey]
            )
            merged.updatedAt = now
            nextState.records[merged.identityKey] = merged
            stored.append(merged)
        }

        try store.save(nextState)
        state = nextState
        for record in stored {
            emit(.item(record))
            emitAggregates(forGroup: record.groupID)
        }
        return stored
    }

    @discardableResult
    public func setArtworkFileName(
        identityKey: String,
        fileName: String
    ) throws -> Bool {
        guard fileName == URL(fileURLWithPath: fileName).lastPathComponent,
              var record = state.records[identityKey] else {
            return false
        }
        record.snapshot.artworkFileName = fileName
        record.updatedAt = Date()
        try persist(record)
        return true
    }

    /// Records byte progress for an in-flight download.
    public func updateProgress(
        identityKey: String,
        bytesDownloaded: Int64,
        totalBytes: Int64?
    ) throws {
        guard var record = state.records[identityKey] else { return }
        record.bytesDownloaded = bytesDownloaded
        if let totalBytes { record.totalBytes = totalBytes }
        if record.status != .downloading { record.status = .downloading }
        record.updatedAt = Date()
        try persist(record)
    }

    /// Transitions a record's status (e.g. to `.paused`/`.failed`/`.completed`),
    /// optionally attaching a non-secret reason.
    public func setStatus(
        identityKey: String,
        _ status: DownloadStatus,
        failureReason: String? = nil
    ) throws {
        guard var record = state.records[identityKey] else { return }
        record.status = status
        record.failureReason = failureReason
        record.updatedAt = Date()
        try persist(record)
    }

    /// Marks a download complete with its final byte total.
    public func markCompleted(identityKey: String, totalBytes: Int64) throws {
        guard var record = state.records[identityKey] else { return }
        record.status = .completed
        record.bytesDownloaded = totalBytes
        record.totalBytes = totalBytes
        record.failureReason = nil
        record.updatedAt = Date()
        try persist(record)
    }

    /// Removes a record from the catalog (the caller deletes the file).
    public func remove(identityKey: String) throws {
        guard state.records[identityKey] != nil else { return }
        state.records[identityKey] = nil
        try store.save(state)
        emit(.removed(identityKey: identityKey))
        emitAggregates(forGroup: nil)
    }

    // MARK: - Internals

    private func persist(_ record: DownloadedMediaRecord) throws {
        state.records[record.identityKey] = record
        try store.save(state)
        emit(.item(record))
        emitAggregates(forGroup: record.groupID)
    }

    private func mergedRecord(
        _ record: DownloadedMediaRecord,
        existing: DownloadedMediaRecord?
    ) -> DownloadedMediaRecord {
        guard let existing else { return record }
        if existing.status == .completed {
            return existing
        }
        var merged = record
        merged.bytesDownloaded = max(
            existing.bytesDownloaded,
            record.bytesDownloaded
        )
        merged.totalBytes = record.totalBytes ?? existing.totalBytes
        merged.createdAt = existing.createdAt
        if merged.snapshot.artworkFileName == nil {
            merged.snapshot.artworkFileName = existing.snapshot.artworkFileName
        }
        return merged
    }

    private func emitAggregates(forGroup groupID: String?) {
        if let groupID { emit(.group(groupProgress(groupID))) }
        emit(.global(globalProgress()))
    }

    private func groupProgress(_ groupID: String) -> DownloadProgressEvent.GroupProgress {
        let members = state.records.values.filter { $0.groupID == groupID }
        let bytes = members.reduce(Int64(0)) { $0 + $1.bytesDownloaded }
        let totals = members.compactMap(\.totalBytes)
        return .init(
            groupID: groupID,
            totalItems: members.count,
            completedItems: members.filter { $0.status == .completed }.count,
            bytesDownloaded: bytes,
            totalBytes: totals.count == members.count ? totals.reduce(0, +) : nil
        )
    }

    private func globalProgress() -> DownloadProgressEvent.GlobalProgress {
        let active = state.records.values.filter { $0.status.isActive }
        let bytes = active.reduce(Int64(0)) { $0 + $1.bytesDownloaded }
        let totals = active.compactMap(\.totalBytes)
        return .init(
            activeItems: active.count,
            bytesDownloaded: bytes,
            totalBytes: totals.count == active.count ? totals.reduce(0, +) : nil
        )
    }
}
