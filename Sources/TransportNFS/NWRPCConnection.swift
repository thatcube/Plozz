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

    /// Guards `pending` so a late callback after a timeout can't double-resume.
    private let lock = NSLock()
    private var isClosed = false

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
        try await withDeadline(timeout) {
            try await self.send(RPCRecordMarking.frame(message))
            return try await self.receiveRecord()
        } onTimeout: {
            self.forceClose()
        }
    }

    func close() async {
        forceClose()
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
            if length > 0 {
                message.append(try await receiveExactly(length))
            }
            if isLast { break }
            guard message.count <= 128 * 1024 * 1024 else { throw NFSError.malformedResponse }
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

/// Runs `operation` with a wall-clock deadline. On expiry it throws
/// ``NFSError.timeout`` and invokes `onTimeout` to tear down the underlying
/// socket so the abandoned in-flight call can't leak.
func withDeadline<T: Sendable>(
    _ timeout: Duration,
    operation: @escaping @Sendable () async throws -> T,
    onTimeout: @escaping @Sendable () -> Void
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            onTimeout()
            throw NFSError.timeout
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else {
            throw NFSError.cancelled
        }
        return result
    }
}
