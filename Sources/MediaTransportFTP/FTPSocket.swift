import Foundation
import MediaTransportCore
import Network

/// Thin async wrapper over one `NWConnection`. Network.framework is thread-safe
/// when driven from a serial queue, so this is `@unchecked Sendable` around an
/// internal lock. Used for both the FTP control channel and each passive data
/// channel.
final class FTPSocket: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var didFinishStart = false

    init(host: String, port: Int, parameters: NWParameters) {
        let endpointHost = NWEndpoint.Host(host)
        let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) ?? NWEndpoint.Port(integerLiteral: 21)
        self.connection = NWConnection(host: endpointHost, port: endpointPort, using: parameters)
        self.queue = DispatchQueue(label: "com.plozz.ftp.socket")
    }

    /// Starts the connection and resolves once it reaches `.ready` (TLS handshake
    /// included for a TLS-bearing `NWParameters`), or throws on failure.
    func start(timeout: TimeInterval = 20) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await self.startInner() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw MediaTransportError.timeout
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    private func startInner() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.withLock { startContinuation = continuation }
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.finishStart(with: .success(()))
                case .failed(let error):
                    self.finishStart(with: .failure(error))
                case .cancelled:
                    self.finishStart(with: .failure(MediaTransportError.cancelled))
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    private func finishStart(with result: Result<Void, Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            guard !didFinishStart else { return nil }
            didFinishStart = true
            let c = startContinuation
            startContinuation = nil
            return c
        }
        continuation?.resume(with: result)
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    /// Receives between 1 and `maximumLength` bytes. Returns the data (possibly
    /// empty) and whether the stream is complete (EOF).
    func receive(maximumLength: Int) async throws -> (data: Data, isComplete: Bool) {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: maximumLength) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: (data ?? Data(), isComplete))
            }
        }
    }

    func cancel() {
        connection.stateUpdateHandler = nil
        connection.cancel()
    }
}
