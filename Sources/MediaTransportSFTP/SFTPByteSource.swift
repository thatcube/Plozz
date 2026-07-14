import CoreModels
import Foundation
import MediaTransportCore

/// A random-access byte source over an open SFTP file handle.
///
/// Like `WebDAVByteSource` (and unlike SMB's channel-per-cursor source), an SFTP
/// `READ` is a self-contained, request-id-multiplexed operation against a single
/// open handle, so concurrent cursor reads share one handle safely — no per-cursor
/// isolation is needed. Reads past EOF return empty data rather than erroring,
/// matching how AVIO probes past the end of a file.
///
/// Seek-safety: SFTP has no ETag, and unlike WebDAV (`If-Match` piggybacks on every
/// ranged GET for free) or SMB (a stat is cheap on its LAN links), an SFTP `FSTAT`
/// is a separate round-trip — costly on the WAN links SFTP commonly runs over. So
/// rather than revalidating on every read (which would roughly halve WAN
/// throughput), the source validates at open time (in `openSource`) and then
/// re-`FSTAT`s + rechecks size/mtime at a throttled cadence during playback,
/// failing closed on drift (`.sourceChanged`). This bounds the staleness window to
/// `revalidationInterval` while keeping the hot read path RTT-efficient. An
/// interval of 0 forces per-read revalidation (used by tests).
final class SFTPByteSource: MediaTransportByteSource, @unchecked Sendable {
    let byteSize: Int64

    private let backend: any SFTPTransportBackend
    private let handle: SFTPFileHandle
    private let representation: RemoteFileRepresentation
    private let revalidationInterval: TimeInterval
    private let clock: @Sendable () -> Date
    private let lock = NSLock()
    private var isClosed = false
    private var lastValidatedAt: Date

    init(
        byteSize: Int64,
        backend: any SFTPTransportBackend,
        handle: SFTPFileHandle,
        representation: RemoteFileRepresentation,
        revalidationInterval: TimeInterval,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.byteSize = byteSize
        self.backend = backend
        self.handle = handle
        self.representation = representation
        self.revalidationInterval = max(0, revalidationInterval)
        self.clock = clock
        // openSource just validated this handle, so start the throttle clock now.
        self.lastValidatedAt = clock()
    }

    func read(at offset: Int64, length: Int) async throws -> Data {
        guard offset >= 0, length > 0 else {
            throw MediaTransportError.invalidInput(reason: "invalid SFTP byte range")
        }
        // Claim a revalidation slot (or observe closure) atomically so concurrent
        // cursor reads don't each issue an FSTAT within the same interval.
        let decision: (closed: Bool, revalidate: Bool) = lock.withLock {
            if isClosed { return (true, false) }
            let now = clock()
            if now.timeIntervalSince(lastValidatedAt) >= revalidationInterval {
                lastValidatedAt = now
                return (false, true)
            }
            return (false, false)
        }
        guard !decision.closed else {
            throw MediaTransportError.cancelled
        }
        // A read at or past EOF is a normal end-of-stream signal, not an error.
        guard offset < byteSize else {
            return Data()
        }
        let lastByte = byteSize - 1
        let requestedEnd = offset.addingReportingOverflow(Int64(length) - 1)
        let end = requestedEnd.overflow ? lastByte : min(requestedEnd.partialValue, lastByte)
        let clampedLength = Int(end - offset + 1)

        do {
            if decision.revalidate {
                // Fail closed if the file changed underneath the open handle
                // (size/mtime drift) rather than mixing versions.
                let current = try await backend.fstat(handle: handle)
                try validateSFTPRepresentation(current, against: representation)
            }
            return try await backend.read(handle: handle, offset: offset, length: clampedLength)
        } catch {
            throw mapSFTPError(error)
        }
    }

    func shutdown() async {
        let shouldClose = lock.withLock {
            guard !isClosed else { return false }
            isClosed = true
            return true
        }
        guard shouldClose else { return }
        await backend.closeFile(handle: handle)
    }
}
