import CoreModels
import Foundation
import MediaTransportCore

public enum MediaDownloadError: Error, Sendable, Equatable {
    case unsupportedSource
    case cannotOpenSource
    case destinationUnavailable
    case unexpectedEndOfFile(expected: Int64, actual: Int64)
    case invalidChunk(expectedMaximum: Int, actual: Int)
}

/// A random-access byte reader for one open download source. Abstracts the
/// transport cursor so the engine can be unit-tested with a fake and stays
/// decoupled from the concrete (internally-constructed) transport resolved source.
public protocol DownloadByteReader: Sendable {
    var byteSize: Int64 { get }
    func read(at offset: Int64, length: Int) async throws -> Data
    func close() async
}

/// Opens a ``DownloadByteReader`` for a direct-share source. The production
/// implementation composes the transport resolver; tests inject a fake.
public protocol DownloadByteSourceOpening: Sendable {
    func open(_ source: DirectShareDownloadSource) async throws -> any DownloadByteReader
}

/// Fetches the bytes for one download to a local file, resuming from a byte
/// offset and honoring cancellation. Engines never touch the registry/queue — the
/// queue owns state and calls the engine to move bytes.
public protocol MediaDownloadEngine: Sendable {
    /// Downloads `record` to `destination`, resuming from the bytes already on
    /// disk. Calls `onProgress(bytesOnDisk, totalBytes)` as it advances and returns
    /// the final total byte count on success. Throws `CancellationError` when
    /// cancelled (leaving a valid partial file to resume from later).
    func download(
        record: DownloadedMediaRecord,
        to destination: URL,
        onProgress: @escaping @Sendable (Int64, Int64) async -> Void
    ) async throws -> Int64
}

/// Optional capability for engines that must push policy into the underlying
/// transfer system (for example URLSession's cellular/Low Data request flags).
public protocol DownloadPolicyApplying: Sendable {
    func applyDownloadPolicy(_ policy: DownloadNetworkPolicy)
}

public protocol DownloadPersistentWorkCancelling: Sendable {
    func discardPersistentWork(identityKey: String) async
}

/// Routes durable records to the transport-specific byte mover.
public struct RoutingMediaDownloadEngine:
    MediaDownloadEngine,
    DownloadPolicyApplying,
    DownloadPersistentWorkCancelling
{
    private let directShare: any MediaDownloadEngine
    private let managedHTTP: any MediaDownloadEngine

    public init(
        directShare: any MediaDownloadEngine,
        managedHTTP: any MediaDownloadEngine
    ) {
        self.directShare = directShare
        self.managedHTTP = managedHTTP
    }

    public func download(
        record: DownloadedMediaRecord,
        to destination: URL,
        onProgress: @escaping @Sendable (Int64, Int64) async -> Void
    ) async throws -> Int64 {
        switch record.sourceKind {
        case .directShare:
            try await directShare.download(
                record: record,
                to: destination,
                onProgress: onProgress
            )
        case .managedHTTP:
            try await managedHTTP.download(
                record: record,
                to: destination,
                onProgress: onProgress
            )
        }
    }

    public func applyDownloadPolicy(_ policy: DownloadNetworkPolicy) {
        (directShare as? any DownloadPolicyApplying)?.applyDownloadPolicy(policy)
        (managedHTTP as? any DownloadPolicyApplying)?.applyDownloadPolicy(policy)
    }

    public func discardPersistentWork(identityKey: String) async {
        await (managedHTTP as? any DownloadPersistentWorkCancelling)?
            .discardPersistentWork(identityKey: identityKey)
    }
}

/// Production opener: resolves a direct-share locator through the shared transport
/// registry and hands back a cursor-backed reader. This is the ONLY place the
/// engine touches the (SMB/NFS/WebDAV/SFTP/FTP) transport stack — the same
/// `read(at:length:)` path playback uses.
public struct MediaTransportByteSourceOpener: DownloadByteSourceOpening {
    private let resolver: any MediaTransportNetworkFileResolving

    public init(resolver: any MediaTransportNetworkFileResolving) {
        self.resolver = resolver
    }

    public func open(_ source: DirectShareDownloadSource) async throws -> any DownloadByteReader {
        let locator = try source.makeLocator()
        let resolved = try await resolver.resolve(locator)
        guard let cursor = resolved.sourceLease.makeCursor() else {
            await resolved.waitForFinalShutdown()
            throw MediaDownloadError.cannotOpenSource
        }
        return TransportCursorByteReader(resolved: resolved, cursor: cursor)
    }
}

/// Cursor-backed reader that keeps the resolved transport source alive until the
/// download closes it.
final class TransportCursorByteReader: DownloadByteReader, @unchecked Sendable {
    private let resolved: MediaTransportResolvedSource
    private let cursor: MediaTransportSourceCursor

    init(resolved: MediaTransportResolvedSource, cursor: MediaTransportSourceCursor) {
        self.resolved = resolved
        self.cursor = cursor
    }

    var byteSize: Int64 { cursor.byteSize }

    func read(at offset: Int64, length: Int) async throws -> Data {
        try await cursor.read(at: offset, length: length)
    }

    func close() async {
        cursor.close()
        await resolved.waitForFinalShutdown()
    }
}

/// Downloads direct-share files (SMB/NFS/WebDAV/SFTP/FTP) via the transport cursor
/// byte API — the uniform `read(at:length:)` path that works identically across
/// every share transport. Resumes by byte offset; foreground/while-running only
/// (the OS can't continue a stateful-socket transfer while suspended).
public struct TransportCursorDownloadEngine:
    MediaDownloadEngine,
    DownloadPolicyApplying,
    @unchecked Sendable
{
    private let opener: any DownloadByteSourceOpening
    private let chunkSize: Int
    private let fileManager: FileManager
    private let rateLimiter: DownloadRateLimiter

    public init(
        opener: any DownloadByteSourceOpening,
        chunkSize: Int = 4 * 1_024 * 1_024,
        fileManager: FileManager = .default,
        rateLimiter: DownloadRateLimiter = DownloadRateLimiter()
    ) {
        self.opener = opener
        self.chunkSize = max(64 * 1_024, chunkSize)
        self.fileManager = fileManager
        self.rateLimiter = rateLimiter
    }

    /// Convenience: build the engine directly from a transport resolver.
    public init(
        resolver: any MediaTransportNetworkFileResolving,
        chunkSize: Int = 4 * 1_024 * 1_024,
        fileManager: FileManager = .default,
        rateLimiter: DownloadRateLimiter = DownloadRateLimiter()
    ) {
        self.init(
            opener: MediaTransportByteSourceOpener(resolver: resolver),
            chunkSize: chunkSize,
            fileManager: fileManager,
            rateLimiter: rateLimiter
        )
    }

    public func applyDownloadPolicy(_ policy: DownloadNetworkPolicy) {
        Task {
            await rateLimiter.update(
                maximumBytesPerSecond: policy.maximumBytesPerSecond
            )
        }
    }

    public func download(
        record: DownloadedMediaRecord,
        to destination: URL,
        onProgress: @escaping @Sendable (Int64, Int64) async -> Void
    ) async throws -> Int64 {
        guard let source = record.directShareSource else {
            throw MediaDownloadError.unsupportedSource
        }

        try ensureParentDirectory(of: destination)
        let startOffset = try prepareResume(destination: destination)

        let reader = try await opener.open(source)
        do {
            let total = try await copyBytes(
                from: reader,
                to: destination,
                startingAt: startOffset,
                onProgress: onProgress
            )
            await reader.close()
            return total
        } catch {
            await reader.close()
            throw error
        }
    }

    private func copyBytes(
        from reader: any DownloadByteReader,
        to destination: URL,
        startingAt startOffset: Int64,
        onProgress: @Sendable (Int64, Int64) async -> Void
    ) async throws -> Int64 {
        let total = reader.byteSize
        // A resume offset past EOF (file shrank/changed) means start over.
        var offset = max(0, startOffset)
        if offset > total {
            offset = 0
            try truncate(destination, to: 0)
        }

        guard let handle = FileHandle(forWritingAtPath: destination.path) else {
            throw MediaDownloadError.destinationUnavailable
        }
        defer { try? handle.close() }
        try handle.seekToEnd()

        await onProgress(offset, total)
        while offset < total {
            try Task.checkCancellation()
            let length = Int(min(Int64(chunkSize), total - offset))
            try await rateLimiter.waitToTransfer(byteCount: length)
            let data = try await reader.read(at: offset, length: length)
            guard !data.isEmpty else {
                throw MediaDownloadError.unexpectedEndOfFile(
                    expected: total,
                    actual: offset
                )
            }
            guard data.count <= length else {
                throw MediaDownloadError.invalidChunk(
                    expectedMaximum: length,
                    actual: data.count
                )
            }
            try handle.write(contentsOf: data)
            offset += Int64(data.count)
            await onProgress(offset, total)
        }
        try handle.synchronize()
        guard offset == total else {
            throw MediaDownloadError.unexpectedEndOfFile(
                expected: total,
                actual: offset
            )
        }
        return offset
    }

    private func ensureParentDirectory(of url: URL) throws {
        let dir = url.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: dir.path) {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// Shared leaky-bucket scheduler used by every foreground byte mover. Waiting
    /// happens before each source read, so the configured value limits aggregate
    /// download traffic rather than disk writes.
    public actor DownloadRateLimiter {
        private let clock = ContinuousClock()
        private var maximumBytesPerSecond: Int64?
        private var nextTransfer: ContinuousClock.Instant?

        public init(maximumBytesPerSecond: Int64? = nil) {
            self.maximumBytesPerSecond = maximumBytesPerSecond
        }

        public func update(maximumBytesPerSecond: Int64?) {
            self.maximumBytesPerSecond = maximumBytesPerSecond.flatMap {
                $0 > 0 ? $0 : nil
            }
            nextTransfer = nil
        }

        public func waitToTransfer(byteCount: Int) async throws {
            guard byteCount > 0,
                  let maximumBytesPerSecond,
                  maximumBytesPerSecond > 0 else {
                return
            }

            let now = clock.now
            let start = nextTransfer.map { max($0, now) } ?? now
            let nanoseconds = Int64(
                (Double(byteCount) / Double(maximumBytesPerSecond))
                    * 1_000_000_000
            )
            nextTransfer = start.advanced(
                by: .nanoseconds(max(1, nanoseconds))
            )
            if start > now {
                try await clock.sleep(until: start)
            }
        }
    }

    /// Returns the byte offset to resume from: the size of any existing partial
    /// file, or 0 (creating an empty file) when none exists.
    private func prepareResume(destination: URL) throws -> Int64 {
        if fileManager.fileExists(atPath: destination.path) {
            let attrs = try fileManager.attributesOfItem(atPath: destination.path)
            return (attrs[.size] as? NSNumber)?.int64Value ?? 0
        }
        guard fileManager.createFile(atPath: destination.path, contents: nil) else {
            throw MediaDownloadError.destinationUnavailable
        }
        return 0
    }

    private func truncate(_ url: URL, to length: Int64) throws {
        guard let handle = FileHandle(forWritingAtPath: url.path) else {
            throw MediaDownloadError.destinationUnavailable
        }
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(length))
    }
}
