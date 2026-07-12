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
    }

    private let cursor: MediaTransportSourceCursor
    private let lease: MediaTransportSourceLease
    private let resolvedSource: MediaTransportResolvedSource?
    private let readerState = OSAllocatedUnfairLock(initialState: ReaderState())
    private let inflight = OSAllocatedUnfairLock<TransportInflightRead?>(initialState: nil)
    private let avseekSize: Int32 = 65_536

    public init(source: TransportByteSource) {
        let lease = MediaTransportSourceLease(source: source)
        self.lease = lease
        self.resolvedSource = nil
        self.cursor = lease.makeCursor()!
    }

    public init(resolvedSource: MediaTransportResolvedSource) {
        self.resolvedSource = resolvedSource
        self.lease = resolvedSource.sourceLease
        self.cursor = resolvedSource.sourceLease.makeCursor()!
    }

    private init(
        cursor: MediaTransportSourceCursor,
        lease: MediaTransportSourceLease,
        resolvedSource: MediaTransportResolvedSource?
    ) {
        self.cursor = cursor
        self.lease = lease
        self.resolvedSource = resolvedSource
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
        let requestedLength = Int(size)
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

        let task = Task.detached(priority: .userInitiated) { [cursor] in
            defer {
                operation.semaphore.signal()
            }
            do {
                outcome.result = .success(
                    try await cursor.read(at: offset, length: requestedLength)
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
            resolvedSource: resolvedSource
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
