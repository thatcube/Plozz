import CoreModels
import Foundation

public struct WatchlistIntentStoreState: Codable, Hashable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var nextRank: UInt64
    public var intents: [WatchlistIntent]
    public var migration: WatchlistMigrationMetadata

    public init(
        version: Int = currentVersion,
        nextRank: UInt64 = 0,
        intents: [WatchlistIntent] = [],
        migration: WatchlistMigrationMetadata = .init()
    ) {
        self.version = version
        let maximumRank = intents.map(\.rank).max()
        let requiredNextRank = maximumRank.map {
            $0 == UInt64.max ? UInt64.max : $0 + 1
        } ?? 0
        self.nextRank = max(nextRank, requiredNextRank)
        self.intents = intents.map { $0.canonicalized() }.sorted {
            $0.aliasID < $1.aliasID
        }
        self.migration = WatchlistMigrationMetadata(
            legacyHomeSeedCompletedAt: migration.legacyHomeSeedCompletedAt,
            nativeImportRetiredAt: migration.nativeImportRetiredAt
        )
    }

    public static let empty = Self()
}

public protocol WatchlistIntentStoring: Sendable {
    func load() throws -> WatchlistIntentStoreState
    func save(_ state: WatchlistIntentStoreState) throws
    func destructiveRemove() throws
}

public final class InMemoryWatchlistIntentStore: WatchlistIntentStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: WatchlistIntentStoreState

    public init(_ value: WatchlistIntentStoreState = .empty) {
        self.value = value
    }

    public func load() throws -> WatchlistIntentStoreState {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    public func save(_ state: WatchlistIntentStoreState) throws {
        lock.lock()
        defer { lock.unlock() }
        value = state
    }

    public func destructiveRemove() throws {
        lock.lock()
        defer { lock.unlock() }
        value = .empty
    }
}

/// Versioned, profile-scoped, atomic file store. A failed decode blocks normal
/// writes so corrupt bytes cannot be silently replaced; only explicit profile
/// deletion may destructively remove them.
public final class AtomicWatchlistIntentStore: WatchlistIntentStoring, @unchecked Sendable {
    private struct Envelope: Codable {
        let version: Int
        let revision: UInt64
        let nextRank: UInt64
        let intents: [WatchlistIntent]
        let migration: WatchlistMigrationMetadata

        var state: WatchlistIntentStoreState {
            WatchlistIntentStoreState(
                version: version,
                nextRank: nextRank,
                intents: intents,
                migration: migration
            )
        }
    }

    private let fileManager: FileManager
    public let fileURL: URL
    private let lock = NSLock()
    private var loadedRevision: UInt64?
    private var loadFailed = false

    public init(
        directoryURL: URL,
        profileID: String,
        fileManager: FileManager = .default
    ) throws {
        guard !profileID.isEmpty,
              profileID == profileID.trimmingCharacters(in: .whitespacesAndNewlines)
        else { throw DurableLocalStateError.invalidKey }
        self.fileManager = fileManager
        let encoded = Data(profileID.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        fileURL = directoryURL
            .appendingPathComponent("v1", isDirectory: true)
            .appendingPathComponent(encoded, isDirectory: true)
            .appendingPathComponent("state.json")
    }

    public func load() throws -> WatchlistIntentStoreState {
        lock.lock()
        defer { lock.unlock() }
        guard fileManager.fileExists(atPath: fileURL.path) else {
            loadedRevision = nil
            loadFailed = false
            return .empty
        }
        do {
            let envelope = try JSONDecoder().decode(
                Envelope.self,
                from: Data(contentsOf: fileURL, options: [.mappedIfSafe])
            )
            try Self.validate(envelope.state)
            loadedRevision = envelope.revision
            loadFailed = false
            return envelope.state
        } catch let error as DurableLocalStateError {
            loadFailed = true
            throw error
        } catch {
            loadFailed = true
            throw DurableLocalStateError.malformedPayload
        }
    }

    public func save(_ state: WatchlistIntentStoreState) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !loadFailed else { throw DurableLocalStateError.malformedPayload }
        try Self.validate(state)
        let diskRevision = try currentDiskRevision()
        guard diskRevision == loadedRevision else {
            throw DurableLocalStateError.writeConflict
        }
        let canonical = WatchlistIntentStoreState(
            version: state.version,
            nextRank: state.nextRank,
            intents: state.intents,
            migration: state.migration
        )
        let nextRevision = (diskRevision ?? 0) &+ 1
        let envelope = Envelope(
            version: canonical.version,
            revision: nextRevision,
            nextRank: canonical.nextRank,
            intents: canonical.intents,
            migration: canonical.migration
        )
        guard let data = CanonicalJSON.encode(envelope) else {
            throw DurableLocalStateError.malformedPayload
        }
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: [.atomic])
        loadedRevision = nextRevision
    }

    public func destructiveRemove() throws {
        lock.lock()
        defer { lock.unlock() }
        if fileManager.fileExists(atPath: fileURL.path) {
            try fileManager.removeItem(at: fileURL)
        }
        loadedRevision = nil
        loadFailed = false
    }

    private func currentDiskRevision() throws -> UInt64? {
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        do {
            return try JSONDecoder().decode(
                Envelope.self,
                from: Data(contentsOf: fileURL, options: [.mappedIfSafe])
            ).revision
        } catch {
            throw DurableLocalStateError.malformedPayload
        }
    }

    private static func validate(_ state: WatchlistIntentStoreState) throws {
        let maximumRank = state.intents.map(\.rank).max()
        let requiredNextRank = maximumRank.map {
            $0 == UInt64.max ? UInt64.max : $0 + 1
        } ?? 0
        guard state.version == WatchlistIntentStoreState.currentVersion,
              Set(state.intents.map(\.aliasID)).count == state.intents.count,
              state.nextRank >= requiredNextRank
        else { throw DurableLocalStateError.malformedPayload }
    }
}
