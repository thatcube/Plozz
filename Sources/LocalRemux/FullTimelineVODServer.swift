import Foundation
import Network

/// A loopback HTTP/1.1 origin that serves one locally-remuxed title to AVPlayer:
/// the master/media VOD playlists, the shared `EXT-X-MAP` init segment, and each
/// fMP4 media segment, produced on demand by the C remuxer. AVPlayer connects to
/// `http://127.0.0.1:<port>/master.m3u8` and drives playback + native seeking by
/// requesting whatever segments it needs; because every segment for the whole
/// timeline is declared up front (VOD + ENDLIST) and the origin can always produce
/// any declared segment, seek-ahead never 404s and playback never freezes on seek.
///
/// Hardened for the seek-torture workload:
///   * **Concurrency** — connections are handled on a concurrent queue, so the
///     burst of parallel range requests AVPlayer issues while seeking are served
///     in parallel (segment *production* is serialised inside the content source).
///   * **Keep-alive** — HTTP/1.1 persistent connections are honoured, so AVPlayer
///     reuses one socket for the init + many segment reads instead of reconnecting.
///   * **Real range support** — single-range `206 Partial Content` with a correct
///     `Content-Range` (AVPlayer's fMP4 loader probes with `Range:`, and replying
///     `200` while advertising `Accept-Ranges` is a classic `-1011` trigger).
///
/// Bound to loopback only, so nothing is reachable off-device.
final class FullTimelineVODServer: @unchecked Sendable {

    typealias ResponseProvider = @Sendable (_ path: String) -> (data: Data, contentType: String)?

    private let provider: ResponseProvider
    private let queue = DispatchQueue(
        label: "com.thatcube.Plozz.localremux.vod-origin",
        attributes: .concurrent
    )
    private var listener: NWListener?
    private(set) var port: UInt16 = 0

    /// Tracks live connections so `stop()` can tear them all down on teardown.
    private let connectionsLock = NSLock()
    private var connections: Set<ObjectIdentifier> = []
    private var connectionByID: [ObjectIdentifier: NWConnection] = [:]

    private let maxHeaderBytes = 64 * 1024
    private let maxRequestsPerConnection = 100_000

    init(provider: @escaping ResponseProvider) {
        self.provider = provider
    }

    // MARK: - Lifecycle

    /// Starts listening on an ephemeral loopback port. Returns the base URL once
    /// ready, or `nil` on failure.
    func start(timeout: TimeInterval = 5) -> URL? {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        params.allowLocalEndpointReuse = true
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
        }

        guard let listener = try? NWListener(using: params) else {
            RemuxLog.error("Origin: failed to create NWListener")
            return nil
        }
        self.listener = listener

        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.port = listener.port?.rawValue ?? 0
                ready.signal()
            case .failed(let error):
                RemuxLog.error("Origin: listener failed \(error.localizedDescription)")
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)

        if ready.wait(timeout: .now() + timeout) == .timedOut || port == 0 {
            RemuxLog.error("Origin: failed to become ready")
            stop()
            return nil
        }
        RemuxLog.info("Origin: ready on 127.0.0.1:\(port)")
        return URL(string: "http://127.0.0.1:\(port)")
    }

    func stop() {
        listener?.cancel()
        listener = nil
        connectionsLock.lock()
        let live = Array(connectionByID.values)
        connections.removeAll()
        connectionByID.removeAll()
        connectionsLock.unlock()
        for c in live { c.cancel() }
    }

    deinit { stop() }

    // MARK: - Connection lifecycle

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connectionsLock.lock()
        connections.insert(id)
        connectionByID[id] = connection
        connectionsLock.unlock()

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.forget(connection)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveRequest(on: connection, buffer: Data(), servedSoFar: 0)
    }

    private func forget(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connectionsLock.lock()
        connections.remove(id)
        connectionByID.removeValue(forKey: id)
        connectionsLock.unlock()
    }

    private func close(_ connection: NWConnection) {
        connection.cancel()
        forget(connection)
    }

    // MARK: - Request reading (with keep-alive)

    /// Reads until the end of the HTTP request headers (`\r\n\r\n`), responds, then
    /// — for a keep-alive connection — loops to read the next request (carrying any
    /// pipelined bytes that followed the header terminator).
    private func receiveRequest(on connection: NWConnection, buffer: Data, servedSoFar: Int) {
        if servedSoFar >= maxRequestsPerConnection {
            close(connection)
            return
        }
        if let headerEnd = Self.headerTerminator(in: buffer) {
            let head = buffer.subdata(in: buffer.startIndex..<headerEnd)
            let leftover = buffer.subdata(in: headerEnd..<buffer.endIndex)
            respond(to: head, on: connection, leftover: leftover, servedSoFar: servedSoFar)
            return
        }
        if buffer.count > maxHeaderBytes {
            RemuxLog.error("Origin: request headers exceeded \(maxHeaderBytes) bytes")
            close(connection)
            return
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: maxHeaderBytes) { [weak self] chunk, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let chunk, !chunk.isEmpty { buffer.append(chunk) }

            if Self.headerTerminator(in: buffer) != nil {
                self.receiveRequest(on: connection, buffer: buffer, servedSoFar: servedSoFar)
                return
            }
            if isComplete || error != nil {
                self.close(connection)
                return
            }
            self.receiveRequest(on: connection, buffer: buffer, servedSoFar: servedSoFar)
        }
    }

    private func respond(to head: Data, on connection: NWConnection, leftover: Data, servedSoFar: Int) {
        guard let request = String(data: head, encoding: .utf8),
              let requestLine = request.split(separator: "\r\n", maxSplits: 1).first else {
            RemuxLog.error("Origin: malformed request (no request line)")
            sendError(status: "400 Bad Request", on: connection, keepAlive: false)
            return
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            RemuxLog.error("Origin: malformed request line")
            sendError(status: "400 Bad Request", on: connection, keepAlive: false)
            return
        }
        let method = String(parts[0]).uppercased()
        let path = String(parts[1].split(separator: "?").first ?? parts[1])
        let isHead = method == "HEAD"
        let keepAlive = Self.wantsKeepAlive(request)
        let range = Self.parseRange(in: request)

        guard method == "GET" || method == "HEAD" else {
            sendError(status: "405 Method Not Allowed", on: connection, keepAlive: keepAlive)
            return
        }

        guard let response = provider(path) else {
            RemuxLog.error("Origin: \(method) \(path) -> 404 (no resource)")
            sendError(status: "404 Not Found", on: connection, keepAlive: keepAlive)
            return
        }
        send(
            method: method, path: path, body: response.data, contentType: response.contentType,
            headOnly: isHead, range: range, keepAlive: keepAlive,
            on: connection, leftover: leftover, servedSoFar: servedSoFar
        )
    }

    // MARK: - Responses

    private func send(method: String, path: String, body: Data, contentType: String,
                      headOnly: Bool, range: (start: Int, end: Int?)?, keepAlive: Bool,
                      on connection: NWConnection, leftover: Data, servedSoFar: Int) {
        let total = body.count
        var status = "200 OK"
        var slice = body
        var contentRange: String?

        if let range {
            if range.start >= 0, range.start < total {
                let end = min(range.end ?? (total - 1), total - 1)
                if end >= range.start {
                    status = "206 Partial Content"
                    slice = body.subdata(in: range.start..<(end + 1))
                    contentRange = "bytes \(range.start)-\(end)/\(total)"
                }
            } else if range.start >= total {
                status = "416 Range Not Satisfiable"
                slice = Data()
                contentRange = "bytes */\(total)"
            }
        }

        var header = "HTTP/1.1 \(status)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(slice.count)\r\n"
        header += "Accept-Ranges: bytes\r\n"
        if let contentRange { header += "Content-Range: \(contentRange)\r\n" }
        header += "Cache-Control: no-store\r\n"
        header += "Connection: \(keepAlive ? "keep-alive" : "close")\r\n\r\n"

        let rangeDesc = range.map { "\($0.start)-\($0.end.map(String.init) ?? "")" } ?? "none"
        RemuxLog.info("Origin: \(method) \(path) range=\(rangeDesc) -> \(status) ct=\(contentType) bytes=\(slice.count)/\(total)")

        var out = Data(header.utf8)
        if !headOnly { out.append(slice) }
        connection.send(content: out, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error != nil || !keepAlive {
                self.close(connection)
            } else {
                // Persistent connection: serve the next (possibly pipelined) request.
                self.receiveRequest(on: connection, buffer: leftover, servedSoFar: servedSoFar + 1)
            }
        })
    }

    private func sendError(status: String, on connection: NWConnection, keepAlive: Bool) {
        // We always close after an error (simpler; avoids desyncing the request
        // stream on a malformed/oversized request), so advertise it honestly
        // regardless of what the client asked for.
        var header = "HTTP/1.1 \(status)\r\n"
        header += "Content-Length: 0\r\n"
        header += "Connection: close\r\n\r\n"
        connection.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] _ in
            self?.close(connection)
        })
    }

    // MARK: - Parsing helpers

    /// Parses a single `Range: bytes=START-END` header (END optional). Returns
    /// `nil` for no/unsupported (multi/suffix) range → the caller serves `200`.
    static func parseRange(in request: String) -> (start: Int, end: Int?)? {
        for line in request.split(separator: "\r\n") {
            guard line.lowercased().hasPrefix("range:"), let eq = line.firstIndex(of: "=") else { continue }
            let spec = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            guard !spec.contains(",") else { return nil }
            let comps = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            guard let first = comps.first, let start = Int(first) else { return nil }
            var end: Int?
            if comps.count == 2, !comps[1].isEmpty { end = Int(comps[1]) }
            return (start, end)
        }
        return nil
    }

    /// HTTP/1.1 defaults to keep-alive; honour an explicit `Connection: close`.
    static func wantsKeepAlive(_ request: String) -> Bool {
        for line in request.split(separator: "\r\n") {
            let lower = line.lowercased()
            guard lower.hasPrefix("connection:") else { continue }
            if lower.contains("close") { return false }
            if lower.contains("keep-alive") { return true }
        }
        return true
    }

    /// Returns the index just past the `\r\n\r\n` header terminator, if present.
    private static func headerTerminator(in data: Data) -> Data.Index? {
        let terminator = Data([0x0d, 0x0a, 0x0d, 0x0a])
        guard let range = data.range(of: terminator) else { return nil }
        return range.upperBound
    }
}
