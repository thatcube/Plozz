import Foundation
import Network

/// A response the server should write back for a parsed request path.
struct LocalRemuxHTTPResponse: Sendable {
    var status: Int
    var contentType: String
    var body: Data

    static func ok(_ body: Data, contentType: String) -> LocalRemuxHTTPResponse {
        LocalRemuxHTTPResponse(status: 200, contentType: contentType, body: body)
    }

    static func notFound() -> LocalRemuxHTTPResponse {
        LocalRemuxHTTPResponse(status: 404, contentType: "text/plain", body: Data("not found".utf8))
    }

    static func serverError(_ message: String) -> LocalRemuxHTTPResponse {
        LocalRemuxHTTPResponse(status: 500, contentType: "text/plain", body: Data(message.utf8))
    }
}

/// A tiny **loopback-only** HTTP/1.1 server that hands AVPlayer its VOD HLS
/// playlist, the EXT-X-MAP init segment, and on-demand remuxed media segments.
///
/// A localhost server (rather than an `AVAssetResourceLoaderDelegate`) is used on
/// purpose: AVPlayer treats `http://127.0.0.1:port/…` exactly like any HLS origin,
/// including issuing `Range` requests, so the whole declared timeline is seekable
/// and a far seek simply fetches an already-listed segment — it can never 404. The
/// listener is pinned to `.loopback`, so it needs no Local Network entitlement.
final class LocalRemuxHTTPServer: @unchecked Sendable {
    typealias Handler = @Sendable (_ path: String) -> LocalRemuxHTTPResponse

    private let handler: Handler
    private let controlQueue = DispatchQueue(label: "com.plozz.remux.http.control")
    private let workQueue = DispatchQueue(label: "com.plozz.remux.http.work", attributes: .concurrent)
    private var listener: NWListener?
    private(set) var port: UInt16 = 0

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    /// Binds to an ephemeral loopback port and returns it. Throws if the listener
    /// fails to come up.
    func start() throws -> UInt16 {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        params.allowLocalEndpointReuse = true

        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }

        let semaphore = DispatchSemaphore(value: 0)
        var startError: Error?
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled:
                if case .failed(let error) = state { startError = error }
                semaphore.signal()
            default:
                break
            }
        }
        listener.start(queue: controlQueue)
        semaphore.wait()

        if let startError { throw startError }
        guard let rawPort = listener.port?.rawValue else {
            listener.cancel()
            throw NWError.posix(.EADDRNOTAVAIL)
        }
        self.listener = listener
        self.port = rawPort
        return rawPort
    }

    func stop() {
        controlQueue.sync {
            listener?.cancel()
            listener = nil
        }
    }

    // MARK: Connection handling

    private func accept(_ connection: NWConnection) {
        connection.start(queue: workQueue)
        receiveRequest(on: connection, buffer: Data())
    }

    /// Accumulates bytes until the end of the request headers, then dispatches.
    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var accumulated = buffer
            if let data { accumulated.append(data) }

            if let terminatorRange = accumulated.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = accumulated.subdata(in: accumulated.startIndex..<terminatorRange.lowerBound)
                self.handleRequest(headerData, on: connection)
                return
            }

            if error != nil || isComplete || accumulated.count > 256 * 1024 {
                connection.cancel()
                return
            }
            self.receiveRequest(on: connection, buffer: accumulated)
        }
    }

    private func handleRequest(_ headerData: Data, on connection: NWConnection) {
        guard let header = String(data: headerData, encoding: .utf8) else {
            send(.notFound(), method: "GET", range: nil, on: connection)
            return
        }
        let lines = header.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
        guard let requestLine = lines.first else {
            send(.notFound(), method: "GET", range: nil, on: connection)
            return
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            send(.notFound(), method: "GET", range: nil, on: connection)
            return
        }
        let method = String(parts[0]).uppercased()
        let path = String(parts[1])
        let range = Self.parseRange(in: lines)

        // Run the (possibly slow, remuxing) handler off the receive callback so
        // instant playlist/init responses aren't blocked behind a segment remux.
        let handler = self.handler
        workQueue.async { [weak self] in
            let response = handler(path)
            self?.send(response, method: method, range: range, on: connection)
        }
    }

    // MARK: Response writing

    private func send(
        _ response: LocalRemuxHTTPResponse,
        method: String,
        range: (Int, Int?)?,
        on connection: NWConnection
    ) {
        var status = response.status
        var body = response.body
        var extraHeaders = "Accept-Ranges: bytes\r\n"

        if status == 200, let (start, requestedEnd) = range, start < response.body.count {
            let end = min(requestedEnd ?? response.body.count - 1, response.body.count - 1)
            if end >= start {
                body = response.body.subdata(in: start..<(end + 1))
                status = 206
                extraHeaders += "Content-Range: bytes \(start)-\(end)/\(response.body.count)\r\n"
            }
        }

        let bodyToSend = method == "HEAD" ? Data() : body
        var head = "HTTP/1.1 \(status) \(Self.reason(for: status))\r\n"
        head += "Content-Type: \(response.contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += extraHeaders
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n\r\n"

        var packet = Data(head.utf8)
        packet.append(bodyToSend)
        connection.send(content: packet, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: Parsing helpers

    /// Parses a single-range `Range: bytes=start-[end]` header.
    private static func parseRange(in lines: [String]) -> (Int, Int?)? {
        guard let rangeLine = lines.first(where: { $0.lowercased().hasPrefix("range:") }) else { return nil }
        guard let equals = rangeLine.firstIndex(of: "=") else { return nil }
        let spec = rangeLine[rangeLine.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        let bounds = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = bounds.first, let start = Int(first) else { return nil }
        if bounds.count == 2, let end = Int(bounds[1]) { return (start, end) }
        return (start, nil)
    }

    private static func reason(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 206: return "Partial Content"
        case 404: return "Not Found"
        case 500: return "Internal Server Error"
        default: return "OK"
        }
    }
}
