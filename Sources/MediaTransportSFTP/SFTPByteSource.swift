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
/// Seek-safety: SFTP has no ETag, so — exactly as SMB does — before each read we
/// `FSTAT` the open handle and reject any size/mtime drift from the representation
/// captured at scan time (`.sourceChanged`). An `FSTAT` on the handle reflects an
/// in-place rewrite of the file (same inode) as well as the scanned representation
/// going stale, which a one-time open-only check would miss.
final class SFTPByteSource: MediaTransportByteSource, @unchecked Sendable {
    let byteSize: Int64

    private let backend: any SFTPTransportBackend
    private let handle: SFTPFileHandle
    private let representation: RemoteFileRepresentation
    private let lock = NSLock()
    private var isClosed = false

    init(
        byteSize: Int64,
        backend: any SFTPTransportBackend,
        handle: SFTPFileHandle,
        representation: RemoteFileRepresentation
    ) {
        self.byteSize = byteSize
        self.backend = backend
        self.handle = handle
        self.representation = representation
    }

    func read(at offset: Int64, length: Int) async throws -> Data {
        guard offset >= 0, length > 0 else {
            throw MediaTransportError.invalidInput(reason: "invalid SFTP byte range")
        }
        guard !lock.withLock({ isClosed }) else {
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
            // Revalidate the open handle against the scanned representation before
            // serving bytes, so a file changing underneath playback fails closed
            // rather than mixing versions (mirrors SMB's per-read validation).
            let current = try await backend.fstat(handle: handle)
            try validateSFTPRepresentation(current, against: representation)
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
