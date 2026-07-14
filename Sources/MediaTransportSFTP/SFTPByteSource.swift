import Foundation
import MediaTransportCore

/// A random-access byte source over an open SFTP file handle.
///
/// Unlike SMB's channel-per-cursor source, an SFTP `READ` is a self-contained,
/// request-id-multiplexed operation against a single open handle, so concurrent
/// cursor reads share one handle safely and no per-cursor isolation is needed —
/// the same shape as `WebDAVByteSource`. Seek-safety was established once at
/// `openSource` (size + mtime revalidation via `FSTAT`); because a POSIX SFTP
/// handle keeps reading the inode it opened even if the path is later replaced,
/// the representation captured at open stays stable for the life of the handle.
/// Reads past EOF return empty data rather than erroring, matching how AVIO
/// probes past the end of a file.
final class SFTPByteSource: MediaTransportByteSource, @unchecked Sendable {
    let byteSize: Int64

    private let backend: any SFTPTransportBackend
    private let handle: SFTPFileHandle
    private let lock = NSLock()
    private var isClosed = false

    init(byteSize: Int64, backend: any SFTPTransportBackend, handle: SFTPFileHandle) {
        self.byteSize = byteSize
        self.backend = backend
        self.handle = handle
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
