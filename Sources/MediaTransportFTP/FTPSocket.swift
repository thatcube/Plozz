import Foundation
import MediaTransportCore
import Network

/// Thin async wrapper over one `NWConnection`. Network.framework is thread-safe
/// when driven from a serial queue, so this is `@unchecked Sendable` around an
/// internal lock. Used for both the FTP control channel and each passive data
/// channel.
///
/// **Every** await (connect, send, receive) is bounded by a real deadline that,
/// on expiry, *tears down the connection* (`cancel()`) rather than merely
/// throwing — because `NWConnection`'s send/receive completion handlers can hang
/// indefinitely if the peer goes silent mid-transfer, which would otherwise
/// wedge a scan or playback forever. This mirrors SMB's "fail the pending op +
/// disconnect the session on timeout" reference.
final class FTPSocket: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue

    init(host: String, port: Int, parameters: NWParameters) {
        let endpointHost = NWEndpoint.Host(host)
        let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) ?? NWEndpoint.Port(integerLiteral: 21)
        self.connection = NWConnection(host: endpointHost, port: endpointPort, using: parameters)
        self.queue = DispatchQueue(label: "com.plozz.ftp.socket")
    }

    /// Starts the connection and resolves once it reaches `.ready` (TLS handshake
    /// included for a TLS-bearing `NWParameters`), or throws on failure/timeout.
    /// On timeout the connection is torn down.
    func start(timeout: TimeInterval = 20) async throws {
        let _: Void = try await withDeadline(timeout: timeout) { (done: @escaping @Sendable (Result<Void, Error>) -> Void) in
            self.connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    done(.success(()))
                case .failed(let error):
                    done(.failure(error))
                case .cancelled:
                    done(.failure(MediaTransportError.cancelled))
                default:
                    break
                }
            }
            self.connection.start(queue: self.queue)
        }
    }

    func send(_ data: Data, timeout: TimeInterval = 30) async throws {
        let _: Void = try await withDeadline(timeout: timeout) { (done: @escaping @Sendable (Result<Void, Error>) -> Void) in
            self.connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    done(.failure(error))
                } else {
                    done(.success(()))
                }
            })
        }
    }

    /// Receives between 1 and `maximumLength` bytes. Returns the data (possibly
    /// empty) and whether the stream is complete (EOF).
    func receive(maximumLength: Int, timeout: TimeInterval = 30) async throws -> (data: Data, isComplete: Bool) {
        try await withDeadline(timeout: timeout) { done in
            self.connection.receive(minimumIncompleteLength: 1, maximumLength: maximumLength) { data, _, isComplete, error in
                if let error {
                    done(.failure(error))
                } else {
                    done(.success((data ?? Data(), isComplete)))
                }
            }
        }
    }

    func cancel() {
        connection.stateUpdateHandler = nil
        connection.cancel()
    }

    /// Runs an `NWConnection` completion-handler operation with a hard deadline.
    /// The operation resolves via `done`; whichever of the operation, the
    /// deadline, or **task cancellation** fires first wins. On timeout or
    /// cancellation the connection is torn down (`cancel()`) so a pending
    /// `NWConnection` send/receive can't keep the caller — or, critically, the
    /// owning backend actor's serialization gate — blocked (the head-of-line
    /// trap the SFTP review flagged). A once-only ``ResumeBox`` guarantees
    /// exactly one resumption even across the install-vs-resolve race, and the
    /// deadline work item is cancelled when the operation wins.
    private func withDeadline<T: Sendable>(
        timeout: TimeInterval,
        _ body: @escaping @Sendable (@escaping @Sendable (Result<T, Error>) -> Void) -> Void
    ) async throws -> T {
        let box = ResumeBox<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                box.install(continuation)
                let deadline = DispatchWorkItem { [weak self] in
                    if box.resume(.failure(MediaTransportError.timeout)) {
                        self?.cancel()
                    }
                }
                queue.asyncAfter(deadline: .now() + timeout, execute: deadline)
                // DispatchWorkItem.cancel() is thread-safe; wrap it so it can be
                // captured by the @Sendable completion callback under strict
                // concurrency without weakening the deadline's own captures.
                let deadlineBox = UncheckedSendableBox(deadline)
                body { result in
                    if box.resume(result) {
                        deadlineBox.value.cancel()
                    }
                }
            }
        } onCancel: {
            // A cancelled read must release immediately, not wait out the
            // deadline — resume with .cancelled and tear the connection down so
            // the pending NWConnection op fails and the actor gate frees.
            if box.resume(.failure(MediaTransportError.cancelled)) {
                cancel()
            }
        }
    }
}

/// Guards a `CheckedContinuation` so it resumes exactly once, from whichever of
/// the operation callback, the deadline, or task cancellation fires first —
/// including the race where cancellation resolves *before* the continuation is
/// installed. `resume` returns `true` only for the caller that actually won, so
/// the winner alone performs side effects (connection teardown).
private final class ResumeBox<T>: @unchecked Sendable {
    private enum State {
        case waiting
        case installed(CheckedContinuation<T, Error>)
        case buffered(Result<T, Error>)
        case done
    }

    private let lock = NSLock()
    private var state: State = .waiting

    /// Attaches the continuation. If a result already arrived (cancellation or
    /// deadline won before `withCheckedThrowingContinuation`'s body ran), it is
    /// delivered immediately.
    func install(_ continuation: CheckedContinuation<T, Error>) {
        let buffered: Result<T, Error>? = lock.withLock {
            switch state {
            case .waiting:
                state = .installed(continuation)
                return nil
            case .buffered(let result):
                state = .done
                return result
            case .installed, .done:
                return nil
            }
        }
        if let buffered { continuation.resume(with: buffered) }
    }

    /// Returns `true` iff this call is the winning resolution.
    func resume(_ result: Result<T, Error>) -> Bool {
        let outcome: ResumeOutcome<T> = lock.withLock {
            switch state {
            case .installed(let continuation):
                state = .done
                return .resume(continuation)
            case .waiting:
                // Resolved before the continuation installed — buffer it. We
                // still won, so the caller runs its side effect (teardown).
                state = .buffered(result)
                return .buffered
            case .buffered, .done:
                return .lost
            }
        }
        switch outcome {
        case .resume(let continuation):
            continuation.resume(with: result)
            return true
        case .buffered:
            return true
        case .lost:
            return false
        }
    }
}

private enum ResumeOutcome<T> {
    case resume(CheckedContinuation<T, Error>)
    case buffered
    case lost
}

/// Minimal wrapper letting a thread-safe-but-non-`Sendable` value (here a
/// `DispatchWorkItem`, whose `cancel()` is thread-safe) be captured by a
/// `@Sendable` closure under strict concurrency.
private struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
