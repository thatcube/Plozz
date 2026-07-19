import CoreModels
import Foundation
@testable import MediaDownloads

// MARK: - Secure store fake (so the durable store is testable without FeatureAuth)

final class MemorySecureStore: SecureStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]

    func setString(_ value: String, for key: String) throws {
        lock.lock(); defer { lock.unlock() }
        storage[key] = value
    }

    func string(for key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return storage[key]
    }

    func readString(for key: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return storage[key]
    }

    func removeValue(for key: String) throws {
        lock.lock(); defer { lock.unlock() }
        storage[key] = nil
    }

    func allKeys() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(storage.keys)
    }
}

// MARK: - Fake byte reader / opener for the download engine

/// A deterministic in-memory byte reader. Optionally simulates an interruption by
/// throwing `failure` once a read is requested at/after `failAtOffset`.
final class FakeByteReader: DownloadByteReader, @unchecked Sendable {
    let bytes: Data
    let maxChunk: Int
    let failAtOffset: Int64?
    let failure: Error
    private(set) var closed = false

    init(
        bytes: Data,
        maxChunk: Int = Int.max,
        failAtOffset: Int64? = nil,
        failure: Error = CancellationError()
    ) {
        self.bytes = bytes
        self.maxChunk = max(1, maxChunk)
        self.failAtOffset = failAtOffset
        self.failure = failure
    }

    var byteSize: Int64 { Int64(bytes.count) }

    func read(at offset: Int64, length: Int) async throws -> Data {
        if let failAtOffset, offset >= failAtOffset { throw failure }
        guard offset < Int64(bytes.count) else { return Data() }
        let start = Int(offset)
        let end = min(start + min(length, maxChunk), bytes.count)
        return bytes.subdata(in: start..<end)
    }

    func close() async { closed = true }
}

/// A fully controllable engine for queue tests.
struct FakeDownloadEngine: MediaDownloadEngine {
    let behavior: @Sendable (DownloadedMediaRecord, @Sendable (Int64, Int64) async -> Void) async throws -> Int64

    init(
        behavior: @escaping @Sendable (DownloadedMediaRecord, @Sendable (Int64, Int64) async -> Void) async throws -> Int64
    ) {
        self.behavior = behavior
    }

    /// Convenience: always completes at `totalBytes`.
    static func completing(at totalBytes: Int64) -> FakeDownloadEngine {
        FakeDownloadEngine { _, onProgress in
            await onProgress(totalBytes, totalBytes)
            return totalBytes
        }
    }

    /// Convenience: always throws the given error.
    static func failing(with error: Error) -> FakeDownloadEngine {
        FakeDownloadEngine { _, _ in throw error }
    }

    func download(
        record: DownloadedMediaRecord,
        to destination: URL,
        onProgress: @escaping @Sendable (Int64, Int64) async -> Void
    ) async throws -> Int64 {
        try await behavior(record, onProgress)
    }
}

/// Opener that hands out pre-seeded readers in order (one per `open` call), so a
/// resume test can supply an interrupting reader then a completing one.
final class FakeOpener: DownloadByteSourceOpening, @unchecked Sendable {
    private let lock = NSLock()
    private var readers: [FakeByteReader]
    private(set) var openCount = 0

    init(_ readers: [FakeByteReader]) {
        self.readers = readers
    }

    func open(_ source: DirectShareDownloadSource) async throws -> any DownloadByteReader {
        lock.lock(); defer { lock.unlock() }
        openCount += 1
        guard !readers.isEmpty else { throw MediaDownloadError.cannotOpenSource }
        return readers.removeFirst()
    }
}

// MARK: - Factories

enum DownloadTestFactory {
    static func imdbIdentity(_ value: String = "tt0133093") -> MediaIdentity {
        .external(source: "imdb", value: value)
    }

    static func movie(imdb: String = "tt0133093", title: String = "The Matrix") -> MediaItem {
        MediaItem(
            id: "srv-\(imdb)",
            title: title,
            kind: .movie,
            productionYear: 1999,
            providerIDs: ["imdb": imdb]
        )
    }

    static func directShareSource(
        relativePath: String = "Movies/The Matrix (1999)/movie.mkv",
        size: Int64 = 100
    ) throws -> DirectShareDownloadSource {
        let identity = try RemoteFileIdentity(kind: .strongETag, value: "\"v1\"")
        let representation = try RemoteFileRepresentation(
            size: size, identity: identity, consistency: .stronglyBound
        )
        return DirectShareDownloadSource(
            accountID: "account1",
            sourceID: "source1",
            credentialRevision: CredentialRevision(),
            relativePath: relativePath,
            representation: representation,
            container: "mkv",
            mimeType: "video/x-matroska"
        )
    }

    static func record(
        identity: MediaIdentity? = nil,
        status: DownloadStatus = .queued,
        bytesDownloaded: Int64 = 0,
        totalBytes: Int64? = nil,
        groupID: String? = nil,
        localFileName: String = "media.mkv"
    ) throws -> DownloadedMediaRecord {
        DownloadedMediaRecord(
            identity: identity ?? imdbIdentity(),
            groupID: groupID,
            sourceKind: .directShare,
            status: status,
            directShareSource: try directShareSource(),
            localFileName: localFileName,
            bytesDownloaded: bytesDownloaded,
            totalBytes: totalBytes,
            snapshot: PinnedMediaSnapshot(title: "The Matrix", kind: .movie, year: 1999)
        )
    }

    static func tempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaDownloadsTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func request(
        identity: MediaIdentity? = nil,
        groupID: String? = nil
    ) throws -> DownloadRequest {
        DownloadRequest(
            identity: identity ?? imdbIdentity(),
            groupID: groupID,
            sourceKind: .directShare,
            directShareSource: try directShareSource(),
            contentType: "video/x-matroska",
            fileExtension: "mkv",
            snapshot: PinnedMediaSnapshot(title: "The Matrix", kind: .movie, year: 1999)
        )
    }
}

/// A storage locator rooted at a caller-provided directory, for engine/queue tests.
struct FixedDownloadStorageLocator: DownloadStorageLocating {
    let root: URL
    func pinnedMediaDirectory() throws -> URL {
        if !FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        return root
    }
}
