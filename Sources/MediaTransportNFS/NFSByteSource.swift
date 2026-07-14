import Foundation
import MediaTransportCore
import TransportNFS

/// A random-access, cursor-isolated byte source over NFSv3 `READ`.
///
/// Mirrors SMB's `SMBCursorIsolatedFileByteSource`: each cursor of the lease
/// gets its OWN `NFSFileReader` (its own NFS connection), so a cancelled or
/// failed read on one cursor tears down only that cursor's connection and never
/// disturbs a sibling cursor cloned from the same lease (the engine clones
/// cursors for independent/seek readers). NFSv3 `READ` is stateless, and each
/// reader revalidates the file's size/mtime per read, so seek safety holds
/// without a shared server-side handle.
final class NFSByteSource: MediaTransportCursorIsolatedByteSource, @unchecked Sendable {
    let byteSize: Int64

    private let directCursorID = UUID()
    private let state: State

    init(
        byteSize: Int64,
        readerFactory: @escaping @Sendable () async throws -> NFSFileReader
    ) {
        self.byteSize = byteSize
        self.state = State(readerFactory: readerFactory)
    }

    func read(at offset: Int64, length: Int) async throws -> Data {
        try await read(cursorID: directCursorID, at: offset, length: length)
    }

    func read(cursorID: UUID, at offset: Int64, length: Int) async throws -> Data {
        guard offset >= 0, length > 0 else {
            throw MediaTransportError.invalidInput(reason: "invalid NFS byte range")
        }
        // Reads at or past EOF are a normal end-of-stream signal (AVIO probes
        // past the end), not an error.
        guard offset < byteSize else {
            return Data()
        }
        let lastByte = byteSize - 1
        let requestedEnd = offset.addingReportingOverflow(Int64(length) - 1)
        let end = requestedEnd.overflow ? lastByte : min(requestedEnd.partialValue, lastByte)
        let clampedLength = Int(end - offset + 1)
        return try await state.read(cursorID: cursorID, offset: offset, length: clampedLength)
    }

    func release(cursorID: UUID) async {
        await state.release(cursorID: cursorID)
    }

    func shutdown() async {
        await state.shutdown()
    }

    private actor State {
        private let readerFactory: @Sendable () async throws -> NFSFileReader
        private var readers: [UUID: NFSFileReader] = [:]
        private var isClosed = false

        init(readerFactory: @escaping @Sendable () async throws -> NFSFileReader) {
            self.readerFactory = readerFactory
        }

        func read(cursorID: UUID, offset: Int64, length: Int) async throws -> Data {
            guard !isClosed else { throw MediaTransportError.cancelled }
            let reader = try await readerForCursor(cursorID)
            do {
                return try await reader.read(offset: offset, length: length)
            } catch {
                // Tear down only this cursor's connection so a sibling cursor is
                // unaffected; the next read on this cursor reopens a channel.
                await discard(cursorID)
                throw mapNFSError(error)
            }
        }

        func release(cursorID: UUID) async {
            await discard(cursorID)
        }

        func shutdown() async {
            guard !isClosed else { return }
            isClosed = true
            let active = Array(readers.values)
            readers.removeAll()
            for reader in active {
                await reader.close()
            }
        }

        private func readerForCursor(_ cursorID: UUID) async throws -> NFSFileReader {
            if let reader = readers[cursorID] {
                return reader
            }
            let reader = try await readerFactory()
            // `shutdown()` can run during the `await` above and drain the map; if
            // so, this freshly-opened reader would leak its connection (shutdown
            // won't revisit it). Re-check and close it rather than insert.
            guard !isClosed else {
                await reader.close()
                throw MediaTransportError.cancelled
            }
            // A concurrent read for the SAME cursor can't happen (the reader
            // upstream serializes per cursor), but guard against a lost reader
            // if the map changed while awaiting the factory.
            if let existing = readers[cursorID] {
                await reader.close()
                return existing
            }
            readers[cursorID] = reader
            return reader
        }

        private func discard(_ cursorID: UUID) async {
            guard let reader = readers.removeValue(forKey: cursorID) else { return }
            await reader.close()
        }
    }
}
