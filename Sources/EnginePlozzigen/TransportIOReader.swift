#if canImport(AetherEngine)
import Foundation
import os
import AetherEngine
import AetherEngineSMB

public protocol TransportByteSource: AnyObject, Sendable {
    var byteSize: Int64 { get }

    func read(at offset: Int64, length: Int) async throws -> Data
    func shutdown() async
}

final class TransportSourceLease: @unchecked Sendable {
    private struct State {
        var readerCount = 1
        var operationCount = 0
        var isDraining = false
        var hasStartedShutdown = false
        var isShutdownComplete = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let source: TransportByteSource
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(source: TransportByteSource) {
        self.source = source
    }

    var byteSize: Int64 {
        source.byteSize
    }

    func retainReader() -> Bool {
        state.withLock { state in
            guard !state.isDraining else { return false }
            state.readerCount += 1
            return true
        }
    }

    func beginOperation() -> Bool {
        state.withLock { state in
            guard !state.isDraining else { return false }
            state.operationCount += 1
            return true
        }
    }

    func endOperation() {
        let shouldShutdown = state.withLock { state in
            precondition(state.operationCount > 0)
            state.operationCount -= 1
            return Self.shouldBeginShutdown(&state)
        }
        if shouldShutdown {
            beginShutdown()
        }
    }

    func releaseReader() {
        let shouldShutdown = state.withLock { state in
            precondition(state.readerCount > 0)
            state.readerCount -= 1
            if state.readerCount == 0 {
                state.isDraining = true
            }
            return Self.shouldBeginShutdown(&state)
        }
        if shouldShutdown {
            beginShutdown()
        }
    }

    func waitForFinalShutdown() async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = state.withLock { state in
                if state.isShutdownComplete {
                    return true
                }
                state.waiters.append(continuation)
                return false
            }
            if resumeImmediately {
                continuation.resume()
            }
        }
    }

    private static func shouldBeginShutdown(_ state: inout State) -> Bool {
        guard state.isDraining,
              state.readerCount == 0,
              state.operationCount == 0,
        !state.hasStartedShutdown
        else {
            return false
        }
        state.hasStartedShutdown = true
        return true
    }

    private func beginShutdown() {
        Task.detached(priority: .utility) { [self, source] in
            await source.shutdown()
            let waiters = state.withLock { state in
          state.isShutdownComplete = true
          let waiters = state.waiters
          state.waiters.removeAll()
          return waiters
            }
            waiters.forEach { $0.resume() }
        }
    }
}

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
    }

    private let source: TransportByteSource
    private let lease: TransportSourceLease
    private let readerState = OSAllocatedUnfairLock(initialState: ReaderState())
    private let inflight = OSAllocatedUnfairLock<TransportInflightRead?>(initialState: nil)
    private let avseekSize: Int32 = 65_536

    public init(source: TransportByteSource) {
        self.source = source
        self.lease = TransportSourceLease(source: source)
    }

    private init(source: TransportByteSource, lease: TransportSourceLease) {
        self.source = source
        self.lease = lease
    }

    deinit {
        close()
    }

    public func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
        guard let buffer, size > 0 else { return 0 }
        guard let offset = readerState.withLock({ state in
            state.isClosed ? nil : state.position
        }) else {
            return -1
        }
        guard lease.beginOperation() else { return -1 }

        let requestedLength = Int(size)
        let outcome = TransportReadOutcome()
        let operation = TransportInflightRead()
        let wasPublished = inflight.withLock { active -> Bool in
            guard active == nil else { return false }
            active = operation
            return true
        }
        guard wasPublished else {
            lease.endOperation()
            return -1
        }
        if readerState.withLock({ $0.isClosed }) {
            operation.cancel()
        }

        let task = Task.detached(priority: .userInitiated) { [source, lease] in
            defer {
                lease.endOperation()
                operation.semaphore.signal()
            }
            do {
                outcome.result = .success(
                    try await source.read(at: offset, length: requestedLength)
                )
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
                if !state.isClosed, state.position == offset {
                    state.position += Int64(readCount)
                }
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
                candidate = state.position + offset
            case Int32(SEEK_END):
                candidate = lease.byteSize + offset
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
              lease.retainReader()
        else {
            return nil
        }
        return TransportIOReader(source: source, lease: lease)
    }

    public func close() {
        let shouldRelease = readerState.withLock { state in
            guard !state.isClosed else { return false }
            state.isClosed = true
            return true
        }
        guard shouldRelease else { return }
        cancel()
        lease.releaseReader()
    }

    public func waitForFinalShutdown() async {
        await lease.waitForFinalShutdown()
    }
}

final class SMBTransportByteSource: TransportByteSource, @unchecked Sendable {
    private let connection: SMBConnection

    init(connection: SMBConnection) {
        self.connection = connection
    }

    var byteSize: Int64 {
        connection.byteSize
    }

    func read(at offset: Int64, length: Int) async throws -> Data {
        try await connection.read(at: offset, length: length)
    }

    func shutdown() async {
        connection.close()
    }
}
#endif
