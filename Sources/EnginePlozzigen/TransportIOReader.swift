#if canImport(AetherEngine)
import Foundation
import os
import AetherEngine
import MediaTransportCore

public typealias TransportByteSource = MediaTransportByteSource

private final class TransportReadOutcome: @unchecked Sendable {
    var result: Result<Data, Error> = .success(Data())
}

private final class TransportInflightRead: @unchecked Sendable {
    private struct State {
        var task: Task<Void, Never>?
        var isCancelled = false
    }

    let semaphore = DispatchSemaphore(value: 0)
    private let state = OSAllocatedUnfairLock(initialState: State())

    func attach(_ task: Task<Void, Never>) {
        let shouldCancel = state.withLock { state in
            state.task = task
            return state.isCancelled
        }
        if shouldCancel {
            task.cancel()
        }
    }

    func cancel() {
        let task = state.withLock { state in
            state.isCancelled = true
            return state.task
        }
        task?.cancel()
        semaphore.signal()
    }

    var isCancelled: Bool {
        state.withLock { $0.isCancelled }
    }
}

public final class TransportIOReader: IOReader, @unchecked Sendable {
    private struct ReaderState {
        var position: Int64 = 0
        var isClosed = false
        /// In-memory read-ahead window. `bufferData` holds the bytes of the file
        /// starting at absolute offset `bufferStart`; empty when nothing is cached.
        /// ffmpeg's small (256 KB) AVIO reads are served from here so one large
        /// underlying transport round-trip satisfies many demux reads.
        var bufferStart: Int64 = 0
        var bufferData = Data()

        /// Bytes of `bufferData` available from `position` forward, or 0 on a miss.
        func bufferedAhead(from offset: Int64) -> Int {
            guard !bufferData.isEmpty else { return 0 }
            let delta = offset - bufferStart
            guard delta >= 0, delta < Int64(bufferData.count) else { return 0 }
            return bufferData.count - Int(delta)
        }
    }

    private let cursor: MediaTransportSourceCursor
    private let lease: MediaTransportSourceLease
    private let resolvedSource: MediaTransportResolvedSource?
    private let readerState = OSAllocatedUnfairLock(initialState: ReaderState())
    private let inflight = OSAllocatedUnfairLock<TransportInflightRead?>(initialState: nil)
    private let avseekSize: Int32 = 65_536

    /// How much to fetch per underlying transport read. ffmpeg drives the demux
    /// with 256 KB AVIO reads; on a high-latency source (WebDAV/SFTP/FTP) that is
    /// dozens of serial round-trips per GOP, each paying request latency and
    /// restarting TCP slow-start. Reading a large contiguous window instead
    /// collapses those into one round-trip and lets the transport sustain its
    /// congestion window across the whole read — the dominant cold-start win.
    /// Served bytes are handed back to ffmpeg in its own 256 KB bites from memory.
    static let defaultReadAheadWindow = 4 * 1024 * 1024  // 4 MB
    private let readAheadWindow: Int

    public convenience init(source: TransportByteSource) {
        self.init(source: source, readAheadWindow: Self.defaultReadAheadWindow)
    }

    init(source: TransportByteSource, readAheadWindow: Int) {
        let lease = MediaTransportSourceLease(source: source)
        self.lease = lease
        self.resolvedSource = nil
        self.cursor = lease.makeCursor()!
        self.readAheadWindow = max(1, readAheadWindow)
    }

    public init(resolvedSource: MediaTransportResolvedSource) {
        self.resolvedSource = resolvedSource
        self.lease = resolvedSource.sourceLease
        self.cursor = resolvedSource.sourceLease.makeCursor()!
        self.readAheadWindow = Self.defaultReadAheadWindow
    }

    private init(
        cursor: MediaTransportSourceCursor,
        lease: MediaTransportSourceLease,
        resolvedSource: MediaTransportResolvedSource?,
        readAheadWindow: Int
    ) {
        self.cursor = cursor
        self.lease = lease
        self.resolvedSource = resolvedSource
        self.readAheadWindow = readAheadWindow
    }

    deinit {
        close()
    }

    public func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
        guard let buffer, size > 0 else { return 0 }
        let requestedLength = Int(size)

        // Fast path: serve from the in-memory read-ahead window without touching
        // the transport. `.hit` copies bytes out and advances the cursor.
        enum Probe { case closed, miss(offset: Int64), hit(count: Int) }
        let probe: Probe = readerState.withLock { state in
            guard !state.isClosed else { return .closed }
            let offset = state.position
            let ahead = state.bufferedAhead(from: offset)
            guard ahead > 0 else { return .miss(offset: offset) }
            let count = min(ahead, requestedLength)
            let start = Int(offset - state.bufferStart)
            state.bufferData.withUnsafeBytes { raw in
                buffer.update(from: raw.baseAddress!.advanced(by: start).assumingMemoryBound(to: UInt8.self), count: count)
            }
            state.position = offset + Int64(count)
            return .hit(count: count)
        }
        switch probe {
        case .closed: return -1
        case .hit(let count): return Int32(count)
        case .miss(let offset):
            return fetchAndServe(into: buffer, offset: offset, requestedLength: requestedLength)
        }
    }

    /// Largest single read issued to the underlying transport. The window is
    /// filled by concatenating reads of at most this size so no backend ever sees
    /// an oversized length (SFTP loops at 32 KB, WebDAV/NFS/SMB all accept ≤1 MB),
    /// while ffmpeg's 256 KB demux reads are still served from the multi-MB window.
    private static let maxBackendChunk = 1024 * 1024  // 1 MB

    /// Miss path: fetch a `readAheadWindow`-sized window at `offset` (clamped to
    /// EOF and never smaller than the demand), cache it, and hand back the
    /// requested prefix. Preserves the single-in-flight-read + cancellation model.
    /// The window is filled with bounded (`maxBackendChunk`) transport reads so a
    /// large window never becomes a single oversized backend request.
    private func fetchAndServe(
        into buffer: UnsafeMutablePointer<UInt8>,
        offset: Int64,
        requestedLength: Int
    ) -> Int32 {
        let byteSize = lease.byteSize
        let remaining = byteSize > offset ? Int(min(byteSize - offset, Int64(Int.max))) : 0
        guard remaining > 0 else { return 0 }  // at/past EOF
        let fetchLength = min(max(requestedLength, readAheadWindow), remaining)

        let outcome = TransportReadOutcome()
        let operation = TransportInflightRead()
        let wasPublished = inflight.withLock { active -> Bool in
            guard active == nil else { return false }
            active = operation
            return true
        }
        guard wasPublished else {
            return -1
        }
        if readerState.withLock({ $0.isClosed }) {
            operation.cancel()
        }

        let chunkSize = Self.maxBackendChunk
        let task = Task.detached(priority: .userInitiated) { [cursor] in
            defer {
                operation.semaphore.signal()
            }
            do {
                var assembled = Data()
                assembled.reserveCapacity(fetchLength)
                var cursorOffset = offset
                // Fill the window with bounded reads, concatenating partial reads
                // (a backend may cap each read below the chunk size). Stop only on
                // an empty read (EOF / nothing more) or cancellation; the demux
                // re-reads any remainder and short reads are handled downstream.
                while assembled.count < fetchLength {
                    try Task.checkCancellation()
                    let want = min(chunkSize, fetchLength - assembled.count)
                    let piece = try await cursor.read(at: cursorOffset, length: want)
                    if piece.isEmpty { break }
                    assembled.append(piece)
                    cursorOffset += Int64(piece.count)
                }
                outcome.result = .success(assembled)
            } catch {
                outcome.result = .failure(error)
            }
        }
        operation.attach(task)
        operation.semaphore.wait()

        let wasCancelled = operation.isCancelled
        inflight.withLock { active in
            if active === operation {
                active = nil
            }
        }
        guard !wasCancelled else { return -1 }

        switch outcome.result {
        case .failure:
            return -1
        case .success(let data):
            guard !data.isEmpty else { return 0 }
            let readCount = min(data.count, requestedLength)
            data.copyBytes(to: buffer, count: readCount)
            readerState.withLock { state in
                // Only adopt the window / advance if no seek raced in while the
                // async fetch was outstanding (reads and seeks both take this lock;
                // the fetch blocks on the semaphore, not the lock).
                guard !state.isClosed, state.position == offset else { return }
                state.bufferStart = offset
                state.bufferData = data
                state.position = offset + Int64(readCount)
            }
            return Int32(readCount)
        }
    }


    public func seek(offset: Int64, whence: Int32) -> Int64 {
        readerState.withLock { state in
            guard !state.isClosed else { return -1 }
            let candidate: Int64
            switch whence {
            case Int32(SEEK_SET):
                candidate = offset
            case Int32(SEEK_CUR):
                let (value, overflow) = state.position.addingReportingOverflow(offset)
                guard !overflow else { return -1 }
                candidate = value
            case Int32(SEEK_END):
                let (value, overflow) = lease.byteSize.addingReportingOverflow(offset)
                guard !overflow else { return -1 }
                candidate = value
            case avseekSize:
                return lease.byteSize
            default:
                return -1
            }
            guard candidate >= 0 else { return -1 }
            state.position = candidate
            return candidate
        }
    }

    public func cancel() {
        inflight.withLock { $0 }?.cancel()
    }

    public func makeIndependentReader() -> IOReader? {
        guard !readerState.withLock({ $0.isClosed }),
              let cursor = cursor.clone()
        else {
            return nil
        }
        return TransportIOReader(
            cursor: cursor,
            lease: lease,
            resolvedSource: resolvedSource,
            readAheadWindow: readAheadWindow
        )
    }

    public func close() {
        let shouldRelease = readerState.withLock { state in
            guard !state.isClosed else { return false }
            state.isClosed = true
            return true
        }
        guard shouldRelease else { return }
        cancel()
        cursor.close()
    }

    public func waitForFinalShutdown() async {
        if let resolvedSource {
            await resolvedSource.waitForFinalShutdown()
        } else {
            await lease.waitForFinalShutdown()
        }
    }
}
#endif
