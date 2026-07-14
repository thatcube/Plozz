import Foundation
import Network

/// Opens `RPCConnection`s over TCP. Abstracted so the NFS client can be driven
/// entirely by canned connections in tests (mirroring SMB's `backendFactory` and
/// WebDAV's injected `registryFactory`).
protocol RPCConnectionFactory: Sendable {
    func connect(host: String, port: UInt16, timeout: Duration) async throws -> any RPCConnection
}

/// Default factory: one `NWConnection` per RPC endpoint (portmap, mountd, nfsd).
struct NWRPCConnectionFactory: RPCConnectionFactory {
    func connect(host: String, port: UInt16, timeout: Duration) async throws -> any RPCConnection {
        let connection = NWRPCConnection(host: host, port: port, timeout: timeout)
        try await connection.start()
        return connection
    }
}

/// `RPCConnection` over a single TCP `NWConnection`.
///
/// tvOS can only issue outbound connections from ephemeral (non-privileged)
/// source ports, so this reaches NFS servers whose exports accept any source
/// port (`insecure`); a server that requires a reserved source port refuses the
/// connection, which surfaces as `.connectionFailed`. Reads reassemble ONC-RPC
/// record-marking fragments (RFC 5531 §11) into a single reply message.
final class NWRPCConnection: RPCConnection, @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.plozz.nfs.rpc")
    private let timeout: Duration

    /// Guards `pending` so a late callback after a timeout can't double-resume,
    /// and serializes `exchange`es (see `exchangeBusy`).
    private let lock = NSLock()
    private var isClosed = false
    /// Serializes RPC exchanges so at most one request/reply is in flight per
    /// connection — ONC-RPC over a stream is single-outstanding, and two
    /// concurrent exchanges would interleave `send`/`receive` and desync the
    /// record stream. Callers that need parallelism use separate connections.
    private var exchangeBusy = false
    private var exchangeWaiters: [CheckedContinuation<Void, Never>] = []

    init(host: String, port: UInt16, timeout: Duration) {
        let endpointHost = NWEndpoint.Host(host)
        let endpointPort = NWEndpoint.Port(rawValue: port) ?? .any
        let parameters = NWParameters.tcp
        parameters.prohibitedInterfaceTypes = [.cellular]
        self.connection = NWConnection(host: endpointHost, port: endpointPort, using: parameters)
        self.timeout = timeout
    }

    func start() async throws {
        try await withDeadline(timeout) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let box = ContinuationBox(continuation)
                self.connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        box.resume(returning: ())
                    case .failed, .cancelled:
                        box.resume(throwing: NFSError.connectionFailed)
                    case .waiting:
                        // A NAT/firewall path that never becomes ready; the
                        // outer deadline turns this into a timeout.
                        break
                    default:
                        break
                    }
                }
                self.connection.start(queue: self.queue)
            }
        } onTimeout: {
            self.forceClose()
        }
    }

    func exchange(_ message: Data) async throws -> Data {
        await acquireExchange()
        defer { releaseExchange() }
        return try await withDeadline(timeout) {
            try await self.send(RPCRecordMarking.frame(message))
            return try await self.receiveRecord()
        } onTimeout: {
            self.forceClose()
        }
    }

    func close() async {
        forceClose()
    }

    // MARK: - Exchange serialization

    private func acquireExchange() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if exchangeBusy {
                exchangeWaiters.append(continuation)
                lock.unlock()
            } else {
                exchangeBusy = true
                lock.unlock()
                continuation.resume()
            }
        }
    }

    private func releaseExchange() {
        lock.lock()
        if exchangeWaiters.isEmpty {
            exchangeBusy = false
            lock.unlock()
        } else {
            let next = exchangeWaiters.removeFirst()
            lock.unlock()
            next.resume()
        }
    }

    // MARK: - Send / receive primitives

    private func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let box = ContinuationBox(continuation)
            connection.send(content: data, completion: .contentProcessed { error in
                if error != nil {
                    box.resume(throwing: NFSError.connectionFailed)
                } else {
                    box.resume(returning: ())
                }
            })
        }
    }

    /// Reassembles one complete record-marked message (one or more fragments).
    private func receiveRecord() async throws -> Data {
        var message = Data()
        while true {
            let header = try await receiveExactly(4)
            let headerValue = (UInt32(header[header.startIndex]) << 24)
                | (UInt32(header[header.startIndex + 1]) << 16)
                | (UInt32(header[header.startIndex + 2]) << 8)
                | UInt32(header[header.startIndex + 3])
            let (isLast, length) = RPCRecordMarking.parseHeader(headerValue)
            guard length >= 0, length <= 64 * 1024 * 1024 else {
                throw NFSError.malformedResponse
            }
            // Bound the cumulative message BEFORE allocating the next fragment,
            // so a stream of large fragments (incl. the final one) can't blow
            // past the cap.
            guard message.count + length <= 128 * 1024 * 1024 else {
                throw NFSError.malformedResponse
            }
            if length > 0 {
                message.append(try await receiveExactly(length))
            }
            if isLast { break }
        }
        return message
    }

    /// Receives exactly `count` bytes, looping over partial `NWConnection`
    /// deliveries.
    private func receiveExactly(_ count: Int) async throws -> Data {
        var buffer = Data()
        buffer.reserveCapacity(count)
        while buffer.count < count {
            let remaining = count - buffer.count
            let chunk = try await receiveChunk(maximum: remaining)
            buffer.append(chunk)
        }
        return buffer
    }

    private func receiveChunk(maximum: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            let box = ContinuationBox(continuation)
            connection.receive(minimumIncompleteLength: 1, maximumLength: maximum) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    box.resume(returning: data)
                    return
                }
                if error != nil || isComplete {
                    box.resume(throwing: NFSError.connectionFailed)
                    return
                }
                // No data, no error, not complete: an empty keep-alive delivery.
                box.resume(throwing: NFSError.connectionFailed)
            }
        }
    }

    private func forceClose() {
        lock.lock()
        let alreadyClosed = isClosed
        isClosed = true
        lock.unlock()
        guard !alreadyClosed else { return }
        connection.forceCancel()
    }
}

/// Single-shot continuation wrapper: the first `resume` wins so a callback that
/// races the deadline (or a duplicate `NWConnection` state transition) can't
/// resume a continuation twice.
private final class ContinuationBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: T) {
        take()?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        take()?.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<T, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let continuation = self.continuation
        self.continuation = nil
        return continuation
    }
}

/// Single-winner election shared between an operation, its timeout, and external
/// cancellation, so the socket-teardown side effect (`onTimeout`) runs at most
/// once and never after the operation already succeeded.
private final class DeadlineFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var resolved = false

    /// Returns true exactly once, for the first caller to claim.
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if resolved { return false }
        resolved = true
        return true
    }
}

/// Runs `operation` with a wall-clock deadline. On expiry OR external
/// cancellation it tears down the underlying socket (`onTimeout`) so the
/// abandoned in-flight continuation resumes (rather than hanging), and it never
/// tears down a connection whose operation already completed successfully.
func withDeadline<T: Sendable>(
    _ timeout: Duration,
    operation: @escaping @Sendable () async throws -> T,
    onTimeout: @escaping @Sendable () -> Void
) async throws -> T {
    let flag = DeadlineFlag()
    return try await withTaskCancellationHandler {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                let result = try await operation()
                // Operation won: block any later timeout/cancel from closing the
                // socket out from under a successful exchange.
                _ = flag.claim()
                return result
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                if flag.claim() { onTimeout() }
                throw NFSError.timeout
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw NFSError.cancelled
            }
            return result
        }
    } onCancel: {
        // External cancellation: the NWConnection continuation ignores task
        // cancellation, so force the socket closed to make its callback fire and
        // unstick the awaiting operation (otherwise the task group would hang
        // waiting for a child that never resumes).
        if flag.claim() { onTimeout() }
    }
}
