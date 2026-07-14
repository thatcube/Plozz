import Foundation
import MediaTransportCore
import TransportNFS

/// A random-access byte source over NFSv3 `READ`.
///
/// NFSv3 `READ` is stateless (handle + offset + count), so — like the WebDAV
/// byte source and unlike SMB's channel-per-cursor source — no per-cursor
/// isolation is needed: one reader on a dedicated connection serves the sequential
/// reads the player issues. Seek safety rests on the stable file handle: if the
/// file is replaced or removed mid-playback the handle goes stale and `READ`
/// fails with `.sourceChanged` rather than returning bytes from a different file.
final class NFSByteSource: MediaTransportByteSource, @unchecked Sendable {
    let byteSize: Int64
    private let reader: NFSFileReader

    init(reader: NFSFileReader, byteSize: Int64) {
        self.reader = reader
        self.byteSize = byteSize
    }

    func read(at offset: Int64, length: Int) async throws -> Data {
        guard offset >= 0, length > 0 else {
            throw MediaTransportError.invalidInput(reason: "invalid NFS byte range")
        }
        // Reads at or past EOF are a normal end-of-stream signal (AVIO probes
        // past the end), not an error — return empty rather than issuing a
        // zero-progress READ.
        guard offset < byteSize else {
            return Data()
        }
        let lastByte = byteSize - 1
        let requestedEnd = offset.addingReportingOverflow(Int64(length) - 1)
        let end = requestedEnd.overflow ? lastByte : min(requestedEnd.partialValue, lastByte)
        let clampedLength = Int(end - offset + 1)

        do {
            return try await reader.read(offset: offset, length: clampedLength)
        } catch {
            throw mapNFSError(error)
        }
    }

    func shutdown() async {
        await reader.close()
    }
}
