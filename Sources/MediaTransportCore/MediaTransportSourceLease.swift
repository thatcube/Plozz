import Foundation

public protocol MediaTransportByteSource: AnyObject, Sendable {
    var byteSize: Int64 { get }
    func read(at offset: Int64, length: Int) async throws -> Data
    func shutdown() async
}

/// Optional specialization for transports that require a distinct underlying
/// channel per logical cursor. A cancelled read may tear down that cursor's
/// channel without disrupting cloned cursors that share the same lease.
public protocol MediaTransportCursorIsolatedByteSource: MediaTransportByteSource {
    func read(
        cursorID: UUID,
        at offset: Int64,
        length: Int
    ) async throws -> Data
    func release(cursorID: UUID) async
}

/// Reference-counted ownership for a random-access source.
///
/// Cursors are independent. Closing or cancelling one cursor never closes
/// another, and the source shuts down exactly once after the final cursor and
/// every read already admitted by the lease have drained. A lease that never
/// creates a cursor owns the source until `close()` or deinitialization.
public final class MediaTransportSourceLease: @unchecked Sendable {
    private struct State {
        var hasUnclaimedLease = true
        var cursorIDs: Set<UUID> = []
        var operationCount = 0
        var isDraining = false
        var shutdownStarted = false
        var shutdownComplete = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let source: any MediaTransportByteSource
    private let lock = NSLock()
    private var state = State()

    public init(source: any MediaTransportByteSource) {
        self.source = source
    }

    deinit {
        let shouldShutdown = lock.withLock {
            guard state.hasUnclaimedLease, !state.shutdownStarted else { return false }
            state.hasUnclaimedLease = false
            state.isDraining = true
            state.shutdownStarted = true
            return true
        }
        if shouldShutdown {
            let source = self.source
            Task.detached(priority: .utility) {
                await source.shutdown()
            }
        }
    }

    public var byteSize: Int64 { source.byteSize }

    public func makeCursor() -> MediaTransportSourceCursor? {
        let id = UUID()
        let admitted = lock.withLock {
            guard !state.isDraining else { return false }
            state.hasUnclaimedLease = false
            state.cursorIDs.insert(id)
            return true
        }
        return admitted ? MediaTransportSourceCursor(id: id, lease: self) : nil
    }

    public func close() {
        let shouldShutdown = lock.withLock {
            guard state.hasUnclaimedLease else { return false }
            state.hasUnclaimedLease = false
            state.isDraining = true
            return markShutdownIfReady()
        }
        if shouldShutdown {
            startShutdown()
        }
    }

    public func waitForFinalShutdown() async {
        close()
        await withCheckedContinuation { continuation in
            let complete = lock.withLock {
                guard !state.shutdownComplete else { return true }
                state.waiters.append(continuation)
                return false
            }
            if complete {
                continuation.resume()
            }
        }
    }

    fileprivate func beginOperation(cursorID: UUID) -> Bool {
        lock.withLock {
            guard state.cursorIDs.contains(cursorID), !state.isDraining else {
                return false
            }
            state.operationCount += 1
            return true
        }
    }

    fileprivate func read(
        cursorID: UUID,
        at offset: Int64,
        length: Int
    ) async throws -> Data {
        if let isolatedSource = source as? any MediaTransportCursorIsolatedByteSource {
            return try await isolatedSource.read(
                cursorID: cursorID,
                at: offset,
                length: length
            )
        }
        return try await source.read(at: offset, length: length)
    }

    fileprivate func endOperation() {
        let shouldShutdown = lock.withLock {
            precondition(state.operationCount > 0)
            state.operationCount -= 1
            return markShutdownIfReady()
        }
        if shouldShutdown {
            startShutdown()
        }
    }

    fileprivate func release(cursorID: UUID) {
        let outcome = lock.withLock { () -> (released: Bool, shouldShutdown: Bool) in
            guard state.cursorIDs.remove(cursorID) != nil else {
                return (false, false)
            }
            if state.cursorIDs.isEmpty {
                state.isDraining = true
            }
            return (true, markShutdownIfReady())
        }
        guard outcome.released else { return }
        if let isolatedSource = source as? any MediaTransportCursorIsolatedByteSource {
            Task.detached(priority: .utility) {
                await isolatedSource.release(cursorID: cursorID)
            }
        }
        if outcome.shouldShutdown {
            startShutdown()
        }
    }

    private func markShutdownIfReady() -> Bool {
        guard state.isDraining, state.cursorIDs.isEmpty,
              state.operationCount == 0, !state.shutdownStarted else {
            return false
        }
        state.shutdownStarted = true
        return true
    }

    private func startShutdown() {
        Task.detached(priority: .utility) { [self, source] in
            await source.shutdown()
            let waiters = lock.withLock {
                state.shutdownComplete = true
                let waiters = state.waiters
                state.waiters.removeAll()
                return waiters
            }
            waiters.forEach { $0.resume() }
        }
    }
}

public final class MediaTransportSourceCursor: @unchecked Sendable {
    private struct State {
        var isClosed = false
        var reads: [UUID: Task<Data, Error>] = [:]
    }

    private let id: UUID
    private let lease: MediaTransportSourceLease
    private let lock = NSLock()
    private var state = State()

    fileprivate init(id: UUID, lease: MediaTransportSourceLease) {
        self.id = id
        self.lease = lease
    }

    deinit {
        close()
    }

    public var byteSize: Int64 { lease.byteSize }

    public func clone() -> MediaTransportSourceCursor? {
        guard !lock.withLock({ state.isClosed }) else { return nil }
        return lease.makeCursor()
    }

    public func read(at offset: Int64, length: Int) async throws -> Data {
        try Task.checkCancellation()
        guard offset >= 0, length > 0 else {
            throw MediaTransportError.invalidInput(reason: "invalid byte range")
        }
        guard lease.beginOperation(cursorID: id) else {
            throw MediaTransportError.cancelled
        }
        let operationID = UUID()
        let cursorID = id
        let task = lock.withLock { () -> Task<Data, Error>? in
            guard !state.isClosed else { return nil }
            let task = Task.detached(priority: .userInitiated) { [lease] in
                try await lease.read(cursorID: cursorID, at: offset, length: length)
            }
            state.reads[operationID] = task
            return task
        }
        guard let task else {
            lease.endOperation()
            throw MediaTransportError.cancelled
        }
        defer {
            _ = lock.withLock { state.reads.removeValue(forKey: operationID) }
            lease.endOperation()
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Cancels this cursor's current reads only. The cursor remains reusable.
    public func cancel() {
        let reads = lock.withLock { Array(state.reads.values) }
        reads.forEach { $0.cancel() }
    }

    public func close() {
        let shouldRelease = lock.withLock {
            guard !state.isClosed else { return false }
            state.isClosed = true
            return true
        }
        guard shouldRelease else { return }
        cancel()
        lease.release(cursorID: id)
    }
}
