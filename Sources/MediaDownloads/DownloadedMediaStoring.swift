import CoreModels
import Foundation

/// Persistence seam for the download catalog. Cold-start safe: ``load()`` returns
/// ``DownloadedMediaRegistryState/empty`` when nothing is stored. A durable
/// implementation that cannot decode existing state must block later writes so
/// corruption is never overwritten with an empty catalog.
public protocol DownloadedMediaStoring: Sendable {
    func load() -> DownloadedMediaRegistryState
    func save(_ state: DownloadedMediaRegistryState) throws
}

/// In-memory store for tests/previews and the safe default so a registry can
/// always be constructed without touching disk.
public final class InMemoryDownloadedMediaStore: DownloadedMediaStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var state: DownloadedMediaRegistryState

    public init(_ state: DownloadedMediaRegistryState = .empty) {
        self.state = state
    }

    public func load() -> DownloadedMediaRegistryState {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    public func save(_ state: DownloadedMediaRegistryState) throws {
        lock.lock(); defer { lock.unlock() }
        self.state = state
    }
}

/// Durable, user-independent Keychain-backed catalog store.
///
/// Mirrors ``DurableWatchMutationStore``: the (potentially large) JSON catalog is
/// split into ≤256 KB chunks addressed by a manifest, written to an alternating
/// generation (`slot0`/`slot1`) with a monotonic revision so a crash mid-write
/// leaves the previous complete generation intact. A decode failure latches the
/// store closed (writes throw) so a corrupt catalog is never silently replaced by
/// an empty one.
public final class DurableDownloadedMediaStore: DownloadedMediaStoring, @unchecked Sendable {
    private struct Manifest: DurableLocalStateValue {
        static let durableLocalStateSchemaID = "com.plozz.media-downloads-manifest.v1"
        let generation: String
        let chunkCount: Int
        let revision: UInt64
    }

    private struct Chunk: DurableLocalStateValue {
        static let durableLocalStateSchemaID = "com.plozz.media-downloads-chunk.v1"
        let data: Data
    }

    private static let maximumChunkCount = 64
    private let store: DurableLocalStateStore
    private let scope: DurableLocalStateScope
    private let manifestKey: DurableLocalStateKey
    private let onLoadFailure: @Sendable () -> Void
    private let lock = NSLock()
    private var loadFailed = false
    private var loadedRevision: UInt64?

    public init(
        store: DurableLocalStateStore,
        profileID: String,
        onLoadFailure: @escaping @Sendable () -> Void = {}
    ) throws {
        self.store = store
        self.onLoadFailure = onLoadFailure
        self.scope = .profile(profileID: profileID)
        self.manifestKey = try DurableLocalStateKey(
            collection: .localMediaDownloads,
            scope: self.scope,
            recordID: "manifest"
        )
    }

    public func load() -> DownloadedMediaRegistryState {
        lock.lock()
        do {
            guard let manifest = try store.load(Manifest.self, for: manifestKey) else {
                loadedRevision = nil
                lock.unlock()
                return .empty
            }
            guard (1...Self.maximumChunkCount).contains(manifest.chunkCount),
                  manifest.generation == "slot0" || manifest.generation == "slot1" else {
                throw DurableLocalStateError.malformedPayload
            }
            var encoded = Data()
            for index in 0..<manifest.chunkCount {
                guard let chunk = try store.load(
                    Chunk.self,
                    for: try chunkKey(generation: manifest.generation, index: index)
                ) else {
                    throw DurableLocalStateError.malformedPayload
                }
                encoded.append(chunk.data)
            }
            do {
                let state = try JSONDecoder().decode(
                    DownloadedMediaRegistryState.self,
                    from: encoded
                )
                loadedRevision = manifest.revision
                lock.unlock()
                return state
            } catch {
                throw DurableLocalStateError.malformedPayload
            }
        } catch {
            loadFailed = true
            lock.unlock()
            onLoadFailure()
            return .empty
        }
    }

    public func save(_ state: DownloadedMediaRegistryState) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !loadFailed else {
            throw DurableLocalStateError.malformedPayload
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(state)
        let chunkByteCount = max(1, min(128 * 1_024, store.maximumPayloadBytes * 45 / 100))
        let chunks = stride(from: 0, to: max(1, encoded.count), by: chunkByteCount).map {
            offset -> Data in
            guard !encoded.isEmpty else { return Data() }
            return encoded.subdata(in: offset..<min(offset + chunkByteCount, encoded.count))
        }
        guard chunks.count <= Self.maximumChunkCount else {
            throw DurableLocalStateError.payloadTooLarge
        }

        let previous = try store.load(Manifest.self, for: manifestKey)
        guard previous?.revision == loadedRevision else {
            throw DurableLocalStateError.writeConflict
        }
        let generation = previous?.generation == "slot0" ? "slot1" : "slot0"
        let revision = (previous?.revision ?? 0) &+ 1
        for (index, data) in chunks.enumerated() {
            try store.save(Chunk(data: data), for: try chunkKey(generation: generation, index: index))
        }
        try store.save(
            Manifest(generation: generation, chunkCount: chunks.count, revision: revision),
            for: manifestKey
        )
        loadedRevision = revision
    }

    private func chunkKey(generation: String, index: Int) throws -> DurableLocalStateKey {
        try DurableLocalStateKey(
            collection: .localMediaDownloads,
            scope: scope,
            recordID: "chunk.\(generation).\(index)"
        )
    }
}
