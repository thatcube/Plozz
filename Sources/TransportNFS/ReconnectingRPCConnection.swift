import Foundation

/// An ``RPCConnection`` that redials transparently when its socket dies.
///
/// NFSv3 is deliberately stateless (RFC 1813 §1.3): a file handle is server-
/// persistent and survives the loss of the TCP connection that produced it, and
/// the read-only procedures this client issues (GETATTR / LOOKUP / READ /
/// READDIR / ACCESS) are idempotent. Retransmitting a call on a fresh connection
/// is therefore the *specified* recovery, not a workaround — it is what the
/// Linux kernel client and libnfs do.
///
/// Without this, one dropped socket poisoned a mount permanently: `NFSMountSession`
/// and `NFSFileReader` each bound an `RPCClient` to a single connection for life,
/// so every later call failed with `ENOTCONN` in microseconds. iOS made that the
/// common case rather than an edge case — the system tears down sockets when an
/// app is suspended, so backgrounding the app was enough to kill a share until
/// relaunch. (The registry's dead-session eviction couldn't save it either: it
/// only probes *idle* sessions, and never probes one that is in use.)
///
/// Reconnection is bounded to a single retry per exchange so a genuinely
/// unreachable server still surfaces `.connectionFailed` promptly instead of
/// looping.
actor ReconnectingRPCConnection: RPCConnection {
    private let factory: any RPCConnectionFactory
    private let host: String
    private let port: UInt16
    private let timeout: Duration

    private var current: (any RPCConnection)?
    /// Bumped on every successful dial. An exchange records the generation it
    /// used, so a failure can only discard *that* connection — a concurrent
    /// exchange that already redialed isn't torn down underneath itself.
    private var generation: UInt64 = 0
    private var isClosed = false

    /// - Parameter initial: the already-connected socket from the mount
    ///   handshake, adopted so construction costs no extra dial.
    init(
        factory: any RPCConnectionFactory,
        host: String,
        port: UInt16,
        timeout: Duration,
        initial: (any RPCConnection)? = nil
    ) {
        self.factory = factory
        self.host = host
        self.port = port
        self.timeout = timeout
        self.current = initial
    }

    func exchange(_ message: Data) async throws -> Data {
        var lastError: Error?
        for _ in 0..<2 {
            guard !isClosed else { throw NFSError.cancelled }
            let (connection, usedGeneration) = try await activeConnection()
            do {
                return try await connection.exchange(message)
            } catch let error as NFSError {
                switch error {
                case .connectionFailed:
                    // The socket is gone. Drop it and retransmit on a fresh one.
                    lastError = error
                    await discard(generation: usedGeneration)
                case .timeout:
                    // `NWRPCConnection` force-closes on deadline, so this socket
                    // is dead too — evict it, but don't retry: a retransmission
                    // would double an already-exhausted wall clock.
                    await discard(generation: usedGeneration)
                    throw error
                default:
                    throw error
                }
            }
        }
        throw lastError ?? NFSError.connectionFailed(detail: "reconnect exhausted \(host):\(port)")
    }

    func close() async {
        guard !isClosed else { return }
        isClosed = true
        let connection = current
        current = nil
        await connection?.close()
    }

    private func activeConnection() async throws -> (any RPCConnection, UInt64) {
        if let current {
            return (current, generation)
        }
        let dialed = try await factory.connect(host: host, port: port, timeout: timeout)
        // Reentrancy: the actor serviced other calls during the dial above, so a
        // sibling exchange may have installed a connection (or closed us).
        if let current {
            await dialed.close()
            return (current, generation)
        }
        guard !isClosed else {
            await dialed.close()
            throw NFSError.cancelled
        }
        generation &+= 1
        current = dialed
        return (dialed, generation)
    }

    private func discard(generation staleGeneration: UInt64) async {
        guard generation == staleGeneration, let connection = current else { return }
        current = nil
        await connection.close()
    }
}
