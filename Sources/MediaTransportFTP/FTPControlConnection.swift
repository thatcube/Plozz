import Foundation
import MediaTransportCore

/// Drives the FTP control channel: sends CRLF-terminated commands and frames
/// replies with ``FTPReplyParser``. Confined to the owning ``FTPNetworkBackend``
/// actor (not independently `Sendable`); it buffers raw bytes and extracts
/// `\r\n`-delimited lines, receiving more from the socket as needed.
final class FTPControlConnection {
    private let socket: FTPSocket
    private var buffer = Data()
    private static let maxReplyBytes = 64 * 1_024

    init(socket: FTPSocket) {
        self.socket = socket
    }

    /// Reads one complete reply (single- or multi-line).
    func readReply() async throws -> FTPReply {
        var parser = FTPReplyParser()
        while true {
            let line = try await readLine()
            if let reply = try parser.consume(line: line) {
                return reply
            }
        }
    }

    /// Sends a command and returns the reply. Never logs `command` (it may be a
    /// `PASS`), consistent with the transport modules' secret-safe posture.
    @discardableResult
    func send(_ command: String) async throws -> FTPReply {
        let payload = Data((command + "\r\n").utf8)
        try await socket.send(payload)
        return try await readReply()
    }

    /// Sends a command and asserts a positive-completion (2xx) reply, throwing
    /// `unexpectedReply(code:)` otherwise.
    @discardableResult
    func sendExpectingCompletion(_ command: String) async throws -> FTPReply {
        let reply = try await send(command)
        guard reply.isPositiveCompletion else {
            throw FTPProtocolError.unexpectedReply(code: reply.code)
        }
        return reply
    }

    private func readLine() async throws -> String {
        let crlf = Data([0x0D, 0x0A])
        while true {
            if let range = buffer.range(of: crlf) {
                let lineData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                return String(decoding: lineData, as: UTF8.self)
            }
            guard buffer.count <= Self.maxReplyBytes else {
                throw FTPProtocolError.malformedReply
            }
            let (data, isComplete) = try await socket.receive(maximumLength: 8 * 1_024)
            if !data.isEmpty { buffer.append(data) }
            if isComplete, buffer.range(of: crlf) == nil {
                // Stream closed with a dangling partial line.
                if buffer.isEmpty { throw MediaTransportError.transport(code: -1) }
                let lineData = buffer
                buffer.removeAll(keepingCapacity: false)
                return String(decoding: lineData, as: UTF8.self)
            }
        }
    }

    func cancel() {
        socket.cancel()
    }
}
