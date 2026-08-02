import CoreModels
import Foundation

public struct MediaAliasLedgerState: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public let version: Int
    public var records: [MediaAliasRecord]

    public init(version: Int = currentVersion, records: [MediaAliasRecord] = []) {
        self.version = version
        self.records = records.sorted { $0.id < $1.id }
    }

    public static let empty = Self()
}

public protocol MediaAliasStoring: Sendable {
    func load() throws -> MediaAliasLedgerState
    func save(_ state: MediaAliasLedgerState) throws
    func remove() throws
    func destructiveRemove() throws
}

public extension MediaAliasStoring {
    func destructiveRemove() throws {
        try remove()
    }
}

public struct MediaAliasEncodedSizeMetric: Equatable, Sendable {
    public let recordCount: Int
    public let encodedByteCount: Int
    public let largestRecordByteCount: Int
}

public enum MediaAliasEncodingMetrics {
    public static func measure(
        records: [MediaAliasRecord]
    ) throws -> MediaAliasEncodedSizeMetric {
        let state = MediaAliasLedgerState(records: records)
        let encoded = try canonicalData(state)
        let largest = try records.reduce(into: 0) { result, record in
            result = max(result, try canonicalData(record.canonicalized()).count)
        }
        return MediaAliasEncodedSizeMetric(
            recordCount: records.count,
            encodedByteCount: encoded.count,
            largestRecordByteCount: largest
        )
    }

    static func canonicalData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
}

public final class InMemoryMediaAliasStore: MediaAliasStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var state: MediaAliasLedgerState

    public init(_ state: MediaAliasLedgerState = .empty) {
        self.state = state
    }

    public func load() throws -> MediaAliasLedgerState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    public func save(_ state: MediaAliasLedgerState) throws {
        lock.lock()
        defer { lock.unlock() }
        self.state = state
    }

    public func remove() throws {
        lock.lock()
        defer { lock.unlock() }
        state = .empty
    }

    public func destructiveRemove() throws {
        try remove()
    }
}

/// Atomic Application Support file storage for the long-lived alias identity
/// ledger. Alias payloads are non-secret and do not belong in Keychain. One
/// canonical file per profile avoids Keychain item-size and item-count ceilings;
/// `.atomic` writes publish a complete replacement or leave the prior file intact.
/// Mutations still encode and replace the identity ledger in O(record count);
/// feature payloads must remain in separate keyed stores, and ``MediaAliasStoring``
/// is the migration seam for a transactional database if alias churn outgrows this
/// measured representation.
public final class AtomicFileMediaAliasStore: MediaAliasStoring, @unchecked Sendable {
    private struct FileEnvelope: Codable {
        let version: Int
        let revision: UInt64
        let records: [MediaAliasRecord]

        var state: MediaAliasLedgerState {
            MediaAliasLedgerState(version: version, records: records)
        }
    }

    private let fileManager: FileManager
    let fileURL: URL
    private let legacyStore: (any MediaAliasStoring)?
    private let operationLock: NSLock
    private var loadedRevision: UInt64?
    private var loadFailed = false
    private var legacyCleanupURL: URL {
        fileURL.deletingLastPathComponent()
            .appendingPathComponent(".legacy-cleaned")
    }

    public init(
        directoryURL: URL,
        profileID: String,
        legacyStore: (any MediaAliasStoring)? = nil,
        fileManager: FileManager = .default
    ) throws {
        guard !profileID.isEmpty,
              profileID == profileID.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw DurableLocalStateError.invalidKey
        }
        self.fileManager = fileManager
        self.legacyStore = legacyStore
        let profileDirectory = Self.profileDirectory(
            root: directoryURL,
            profileID: profileID
        )
        fileURL = profileDirectory.appendingPathComponent("state.json", isDirectory: false)
        operationLock = MediaAliasFileCoordination.shared.lock(
            for: fileURL.standardizedFileURL.path
        )
    }

    public func load() throws -> MediaAliasLedgerState {
        operationLock.lock()
        defer { operationLock.unlock() }
        do {
            let state = try withExclusiveFileLock {
                if fileManager.fileExists(atPath: fileURL.path) {
                    let loaded = try loadFile()
                    loadedRevision = loaded.revision
                    try cleanupLegacyStoreIfNeeded()
                    return loaded.state
                }
                loadedRevision = nil
                guard let legacyStore else { return .empty }
                let migrated = try legacyStore.load()
                guard migrated != .empty else { return .empty }
                try saveFile(migrated)
                try cleanupLegacyStoreIfNeeded()
                return migrated
            }
            loadFailed = false
            return state
        } catch {
            loadFailed = true
            throw error
        }
    }

    public func save(_ state: MediaAliasLedgerState) throws {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard !loadFailed else {
            throw DurableLocalStateError.malformedPayload
        }
        try withExclusiveFileLock {
            try saveFile(state)
        }
    }

    public func remove() throws {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard !loadFailed else {
            throw DurableLocalStateError.malformedPayload
        }

        try withExclusiveFileLock {
            let currentRevision = try diskRevision()
            guard currentRevision == loadedRevision else {
                throw DurableLocalStateError.writeConflict
            }
            try legacyStore?.remove()
            if fileManager.fileExists(atPath: fileURL.path) {
                try fileManager.removeItem(at: fileURL)
            }
            loadedRevision = nil
        }
    }

    public func destructiveRemove() throws {
        operationLock.lock()
        defer { operationLock.unlock() }
        try withExclusiveFileLock {
            try legacyStore?.destructiveRemove()
            if fileManager.fileExists(atPath: fileURL.path) {
                try fileManager.removeItem(at: fileURL)
            }
            loadedRevision = nil
            loadFailed = false
        }
    }

    private func loadFile() throws -> (state: MediaAliasLedgerState, revision: UInt64) {
        let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        let state: MediaAliasLedgerState
        let revision: UInt64
        do {
            let envelope = try JSONDecoder().decode(FileEnvelope.self, from: data)
            state = envelope.state
            revision = envelope.revision
        } catch {
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               object["revision"] != nil {
                throw DurableLocalStateError.malformedPayload
            }
            do {
                state = try JSONDecoder().decode(MediaAliasLedgerState.self, from: data)
                revision = 0
            } catch {
                throw DurableLocalStateError.malformedPayload
            }
        }
        guard state.version == MediaAliasLedgerState.currentVersion,
              Set(state.records.map(\.id)).count == state.records.count else {
            throw DurableLocalStateError.malformedPayload
        }
        return (state, revision)
    }

    private func saveFile(_ state: MediaAliasLedgerState) throws {
        guard state.version == MediaAliasLedgerState.currentVersion,
              Set(state.records.map(\.id)).count == state.records.count else {
            throw DurableLocalStateError.malformedPayload
        }
        let canonical = MediaAliasLedgerState(
            version: state.version,
            records: state.records.map { $0.canonicalized() }
        )
        let currentRevision = try diskRevision()
        guard currentRevision == loadedRevision else {
            throw DurableLocalStateError.writeConflict
        }
        let nextRevision = (currentRevision ?? 0) &+ 1
        let envelope = FileEnvelope(
            version: canonical.version,
            revision: nextRevision,
            records: canonical.records
        )
        let data = try MediaAliasEncodingMetrics.canonicalData(envelope)
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: [.atomic])
        loadedRevision = nextRevision
    }

    private func diskRevision() throws -> UInt64? {
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        return try loadFile().revision
    }

    private func withExclusiveFileLock<T>(_ body: () throws -> T) throws -> T {
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let lockURL = directory.appendingPathComponent(".state.lock")
        if !fileManager.fileExists(atPath: lockURL.path) {
            guard fileManager.createFile(atPath: lockURL.path, contents: Data()) else {
                throw DurableLocalStateError.storageUnavailable
            }
        }
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var result: T?
        var operationError: Error?
        coordinator.coordinate(
            writingItemAt: lockURL,
            options: .forMerging,
            error: &coordinationError
        ) { _ in
            do {
                result = try body()
            } catch {
                operationError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let operationError { throw operationError }
        guard let result else { throw DurableLocalStateError.storageUnavailable }
        return result
    }

    private func cleanupLegacyStoreIfNeeded() throws {
        guard let legacyStore,
              !fileManager.fileExists(atPath: legacyCleanupURL.path) else {
            return
        }
        try legacyStore.destructiveRemove()
        guard fileManager.createFile(
            atPath: legacyCleanupURL.path,
            contents: Data()
        ) else {
            throw DurableLocalStateError.storageUnavailable
        }
    }

    private static func profileDirectory(root: URL, profileID: String) -> URL {
        let encoded = Data(profileID.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return stride(from: 0, to: encoded.count, by: 120).reduce(
            root.appendingPathComponent("v1", isDirectory: true)
        ) { url, offset in
            let start = encoded.index(encoded.startIndex, offsetBy: offset)
            let end = encoded.index(
                start,
                offsetBy: min(120, encoded.count - offset)
            )
            return url.appendingPathComponent(
                String(encoded[start..<end]),
                isDirectory: true
            )
        }
    }
}

/// Compatibility store for alias data written through
/// ``DurableLocalStateStore``. New production wiring uses
/// ``AtomicFileMediaAliasStore``. Keychain chunking has practical item-size,
/// item-count, and rewrite-cost ceilings, so it is retained only as a migration
/// source rather than the long-term ledger.
public final class DurableMediaAliasStore: MediaAliasStoring, @unchecked Sendable {
    private struct Manifest: DurableLocalStateValue {
        static let durableLocalStateSchemaID = "com.plozz.media-alias-manifest.v1"

        let formatVersion: Int
        let generation: String
        let chunkCount: Int
        let revision: UInt64
    }

    private struct Chunk: DurableLocalStateValue {
        static let durableLocalStateSchemaID = "com.plozz.media-alias-chunk.v1"

        let data: Data
    }

    private static let maximumChunkCount = 128
    private let store: DurableLocalStateStore
    private let scope: DurableLocalStateScope
    private let manifestKey: DurableLocalStateKey
    private let operationLock: NSLock
    private var loadedRevision: UInt64?
    private var loadFailed = false

    public init(store: DurableLocalStateStore, profileID: String) throws {
        self.store = store
        scope = .profile(profileID: profileID)
        operationLock = MediaAliasStoreCoordination.shared.lock(for: profileID)
        manifestKey = try DurableLocalStateKey(
            collection: .mediaAliasLedger,
            scope: scope,
            recordID: "manifest"
        )
    }

    public func load() throws -> MediaAliasLedgerState {
        operationLock.lock()
        defer { operationLock.unlock() }
        do {
            guard let manifest = try store.load(Manifest.self, for: manifestKey) else {
                loadedRevision = nil
                return .empty
            }
            guard manifest.formatVersion == MediaAliasLedgerState.currentVersion else {
                throw DurableLocalStateError.unsupportedVersion
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
            let state: MediaAliasLedgerState
            do {
                state = try JSONDecoder().decode(MediaAliasLedgerState.self, from: encoded)
            } catch {
                throw DurableLocalStateError.malformedPayload
            }
            guard state.version == MediaAliasLedgerState.currentVersion,
                  Set(state.records.map(\.id)).count == state.records.count else {
                throw DurableLocalStateError.malformedPayload
            }
            loadedRevision = manifest.revision
            return state
        } catch {
            loadFailed = true
            throw error
        }
    }

    public func save(_ state: MediaAliasLedgerState) throws {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard !loadFailed else {
            throw DurableLocalStateError.malformedPayload
        }
        guard state.version == MediaAliasLedgerState.currentVersion else {
            throw DurableLocalStateError.unsupportedVersion
        }

        let canonical = MediaAliasLedgerState(
            version: state.version,
            records: state.records.map { $0.canonicalized() }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(canonical)
        let chunkByteCount = max(
            1,
            min(128 * 1_024, store.maximumPayloadBytes * 45 / 100)
        )
        let chunks = stride(
            from: 0,
            to: max(1, encoded.count),
            by: chunkByteCount
        ).map { offset -> Data in
            guard !encoded.isEmpty else { return Data() }
            return encoded.subdata(
                in: offset..<min(offset + chunkByteCount, encoded.count)
            )
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
            try store.save(
                Chunk(data: data),
                for: try chunkKey(generation: generation, index: index)
            )
        }
        try store.save(
            Manifest(
                formatVersion: MediaAliasLedgerState.currentVersion,
                generation: generation,
                chunkCount: chunks.count,
                revision: revision
            ),
            for: manifestKey
        )
        loadedRevision = revision
    }

    public func remove() throws {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard !loadFailed else {
            throw DurableLocalStateError.malformedPayload
        }
        try store.remove(manifestKey)
        loadedRevision = nil
    }

    public func destructiveRemove() throws {
        operationLock.lock()
        defer { operationLock.unlock() }
        try store.remove(manifestKey)
        for generation in ["slot0", "slot1"] {
            for index in 0..<Self.maximumChunkCount {
                try store.remove(
                    try chunkKey(generation: generation, index: index)
                )
            }
        }
        loadedRevision = nil
        loadFailed = false
    }

    private func chunkKey(
        generation: String,
        index: Int
    ) throws -> DurableLocalStateKey {
        try DurableLocalStateKey(
            collection: .mediaAliasLedger,
            scope: scope,
            recordID: "chunk.\(generation).\(index)"
        )
    }
}

private final class MediaAliasStoreCoordination: @unchecked Sendable {
    static let shared = MediaAliasStoreCoordination()

    private let lock = NSLock()
    private var locksByProfile: [String: NSLock] = [:]

    func lock(for profileID: String) -> NSLock {
        lock.lock()
        defer { lock.unlock() }
        if let existing = locksByProfile[profileID] {
            return existing
        }
        let created = NSLock()
        locksByProfile[profileID] = created
        return created
    }
}

private final class MediaAliasFileCoordination: @unchecked Sendable {
    static let shared = MediaAliasFileCoordination()

    private let lock = NSLock()
    private var locksByPath: [String: NSLock] = [:]

    func lock(for path: String) -> NSLock {
        lock.lock()
        defer { lock.unlock() }
        if let existing = locksByPath[path] {
            return existing
        }
        let created = NSLock()
        locksByPath[path] = created
        return created
    }
}
