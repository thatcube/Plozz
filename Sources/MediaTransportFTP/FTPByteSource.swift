import CoreModels
import Foundation
import MediaTransportCore

/// Random-access byte source over FTP. Each playback cursor gets its **own**
/// FTP control+data connection (one server-side `RETR` cursor per channel), so
/// a cancelled or seeking cursor never disturbs a sibling — the FTP analogue of
/// SMB's per-cursor channel isolation. The underlying backend keeps a
/// contiguous read streaming on one data connection and restarts it with
/// `REST`+`RETR` on a discontiguous seek.
final class FTPCursorIsolatedByteSource:
    MediaTransportCursorIsolatedByteSource,
    @unchecked Sendable
{
    let byteSize: Int64

    private let directCursorID = UUID()
    private let state: State

    init(
        byteSize: Int64,
        path: String,
        expectedRepresentation: RemoteFileRepresentation,
        backendFactory: @escaping FTPBackendFactory
    ) {
        self.byteSize = byteSize
        self.state = State(
            path: path,
            expectedRepresentation: expectedRepresentation,
            backendFactory: backendFactory
        )
    }

    func read(at offset: Int64, length: Int) async throws -> Data {
        try await read(cursorID: directCursorID, at: offset, length: length)
    }

    func read(cursorID: UUID, at offset: Int64, length: Int) async throws -> Data {
        guard offset >= 0, length > 0 else {
            throw MediaTransportError.invalidInput(reason: "invalid FTP byte range")
        }
        // Reads at/after EOF are a normal end-of-stream signal (AVIO probes past
        // the end), not an error — return empty rather than asking for an
        // unsatisfiable range.
        guard offset < byteSize else { return Data() }
        return try await state.read(cursorID: cursorID, offset: offset, length: length)
    }

    func release(cursorID: UUID) async {
        await state.release(cursorID: cursorID)
    }

    func shutdown() async {
        await state.shutdown()
    }

    private actor State {
        private struct Channel {
            let id: UUID
            let task: Task<any FTPBackend, Error>
        }

        private let path: String
        private let expectedRepresentation: RemoteFileRepresentation
        private let backendFactory: FTPBackendFactory
        private var channels: [UUID: Channel] = [:]
        private var isClosed = false

        init(
            path: String,
            expectedRepresentation: RemoteFileRepresentation,
            backendFactory: @escaping FTPBackendFactory
        ) {
            self.path = path
            self.expectedRepresentation = expectedRepresentation
            self.backendFactory = backendFactory
        }

        func read(cursorID: UUID, offset: Int64, length: Int) async throws -> Data {
            let channel = try channel(for: cursorID)
            let backend: any FTPBackend
            do {
                backend = try await withTaskCancellationHandler {
                    try await channel.task.value
                } onCancel: {
                    channel.task.cancel()
                }
            } catch {
                await discard(channel, for: cursorID)
                throw mapFTPError(error)
            }

            do {
                return try await backend.read(
                    path: path,
                    at: offset,
                    length: length,
                    expected: expectedRepresentation
                )
            } catch {
                // A failed read taints the channel's transfer state; drop it so
                // the next read on this cursor reconnects cleanly.
                await discard(channel, for: cursorID)
                throw mapFTPError(error)
            }
        }

        func release(cursorID: UUID) async {
            guard let channel = channels.removeValue(forKey: cursorID) else { return }
            await close(channel)
        }

        func shutdown() async {
            guard !isClosed else { return }
            isClosed = true
            let active = Array(channels.values)
            channels.removeAll()
            for channel in active {
                await close(channel)
            }
        }

        private func channel(for cursorID: UUID) throws -> Channel {
            guard !isClosed else { throw MediaTransportError.cancelled }
            if let existing = channels[cursorID] { return existing }
            let factory = backendFactory
            let channel = Channel(
                id: UUID(),
                task: Task.detached(priority: .userInitiated) {
                    try await factory()
                }
            )
            channels[cursorID] = channel
            return channel
        }

        private func discard(_ channel: Channel, for cursorID: UUID) async {
            guard channels[cursorID]?.id == channel.id else { return }
            channels.removeValue(forKey: cursorID)
            await close(channel)
        }

        private func close(_ channel: Channel) async {
            channel.task.cancel()
            if case .success(let backend) = await channel.task.result {
                await backend.shutdown()
            }
        }
    }
}
