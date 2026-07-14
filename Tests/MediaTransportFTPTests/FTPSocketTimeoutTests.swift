import Foundation
import MediaTransportCore
@testable import MediaTransportFTP
import Network
import XCTest

/// Proves finding #1 (bounded timeouts + forced teardown): a peer that accepts a
/// connection but never sends must NOT wedge a `receive` forever. Uses an
/// in-process loopback `NWListener` that accepts and stays silent — fully
/// hermetic (no external network).
final class FTPSocketTimeoutTests: XCTestCase {
    func testReceiveTimesOutAndTearsDownWhenPeerSilent() async throws {
        let accepted = SilentAcceptBox()
        let listener = try NWListener(using: NWParameters(tls: nil, tcp: NWProtocolTCP.Options()))
        listener.newConnectionHandler = { connection in
            // Accept and hold the connection open, but never send a byte.
            accepted.hold(connection)
            connection.start(queue: .global())
        }
        listener.start(queue: .global())
        defer {
            listener.cancel()
            accepted.cancelAll()
        }

        let port = try await waitForPort(listener)
        let socket = FTPSocket(
            host: "127.0.0.1",
            port: Int(port),
            parameters: NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        )
        try await socket.start(timeout: 5)

        let started = Date()
        do {
            _ = try await socket.receive(maximumLength: 64, timeout: 1)
            XCTFail("expected a timeout from a silent peer")
        } catch let error as MediaTransportError {
            XCTAssertEqual(error, .timeout)
        }
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 4, "receive must time out near its bound, not hang")

        // After the timeout tore the connection down, a further receive must fail
        // promptly rather than hang again.
        do {
            _ = try await socket.receive(maximumLength: 64, timeout: 3)
            XCTFail("expected prompt failure after teardown")
        } catch {
            // Any prompt error (timeout/cancelled/failed) is acceptable here.
        }
    }

    // MARK: - Helpers

    private func waitForPort(_ listener: NWListener) async throws -> UInt16 {
        for _ in 0..<200 {
            if let port = listener.port?.rawValue, port != 0 {
                return port
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        throw MediaTransportError.timeout
    }
}

private final class SilentAcceptBox: @unchecked Sendable {
    private let lock = NSLock()
    private var connections: [NWConnection] = []

    func hold(_ connection: NWConnection) {
        lock.withLock { connections.append(connection) }
    }

    func cancelAll() {
        let connections = lock.withLock { () -> [NWConnection] in
            let held = self.connections
            self.connections.removeAll()
            return held
        }
        connections.forEach { $0.cancel() }
    }
}
