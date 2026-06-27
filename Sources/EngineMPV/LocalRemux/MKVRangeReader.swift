import Foundation
import CoreModels

/// Thread-safe cumulative counter for bytes pulled from the origin server, shared
/// between the header/cue reader and the FFmpeg AVIO reader so the diagnostics
/// overlay can report a single "bytes pulled" figure for the whole session.
final class RemuxByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var total: Int64 = 0

    func add(_ count: Int) {
        guard count > 0 else { return }
        lock.lock(); total += Int64(count); lock.unlock()
    }

    var value: Int64 {
        lock.lock(); defer { lock.unlock() }
        return total
    }
}

/// Reads the original MKV bytes from the provider over authenticated HTTP **range**
/// requests. The authed URL (Jellyfin `/Videos/{id}/stream?static=true&api_key=…`
/// or Plex `…?download=1`) is supplied already-signed in
/// ``LocalRemuxSourceDescriptor/originalURL``.
///
/// Two consumers use it: the pure cue parser (which fetches arbitrary windows as
/// `Data`) and the FFmpeg AVIO layer (pointer-based blocking read/seek). All reads
/// are synchronous — the FFmpeg remux drives them from a dedicated serial queue
/// off the main thread, so blocking there is intentional backpressure.
final class MKVRangeReader: @unchecked Sendable {
    enum ReaderError: Error, CustomStringConvertible {
        case http(Int)
        case transport(String)
        case noContentRange
        case cancelled

        var description: String {
            switch self {
            case .http(let code): return "HTTP \(code)"
            case .transport(let message): return "transport: \(message)"
            case .noContentRange: return "missing Content-Range"
            case .cancelled: return "cancelled"
            }
        }
    }

    private let url: URL
    private let session: URLSession
    private let byteCounter: RemuxByteCounter?

    /// Current read position for the AVIO read callback (seek updates it).
    private let positionLock = NSLock()
    private var position: Int64 = 0

    /// Cached total length, resolved lazily via a 1-byte range probe.
    private var cachedSize: Int64?

    init(url: URL, byteCounter: RemuxByteCounter? = nil, session: URLSession? = nil) {
        self.url = url
        self.byteCounter = byteCounter
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.timeoutIntervalForRequest = 30
            config.waitsForConnectivity = false
            self.session = URLSession(configuration: config)
        }
    }

    // MARK: Random-access fetch (cue parser)

    /// Fetches `length` bytes starting at `offset`. The returned data may be
    /// shorter than requested at end-of-file.
    func fetchRange(offset: Int64, length: Int) throws -> Data {
        guard length > 0 else { return Data() }
        let upper = offset + Int64(length) - 1
        let (data, _) = try performRange(lower: offset, upper: upper)
        byteCounter?.add(data.count)
        return data
    }

    /// Fetches from `offset` to the end of the file.
    func fetchToEnd(offset: Int64) throws -> Data {
        let total = try totalSize()
        guard total > offset else { return Data() }
        return try fetchRange(offset: offset, length: Int(total - offset))
    }

    /// Total byte length of the source, resolved once and cached.
    func totalSize() throws -> Int64 {
        if let cachedSize { return cachedSize }
        let (_, total) = try performRange(lower: 0, upper: 0)
        guard let total else { throw ReaderError.noContentRange }
        cachedSize = total
        return total
    }

    // MARK: FFmpeg AVIO bridge (pointer-based)

    /// Backs the C read callback: fill `buffer` with up to `count` bytes from the
    /// current position, advancing it. Returns bytes read (0 at EOF).
    func avioRead(buffer: UnsafeMutablePointer<UInt8>, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let pos = currentPosition
        do {
            let data = try fetchRange(offset: pos, length: count)
            if data.isEmpty { return 0 }
            data.copyBytes(to: buffer, count: data.count)
            advancePosition(by: Int64(data.count))
            return data.count
        } catch {
            return -1
        }
    }

    /// Backs the C seek callback. `whence` follows POSIX (SEEK_SET/CUR/END) plus
    /// FFmpeg's `AVSEEK_SIZE` (0x10000) to query the total length.
    func avioSeek(offset: Int64, whence: Int32) -> Int64 {
        let avseekSize: Int32 = 0x10000
        switch whence {
        case avseekSize:
            return (try? totalSize()) ?? -1
        case Int32(SEEK_SET):
            setPosition(offset)
        case Int32(SEEK_CUR):
            setPosition(currentPosition + offset)
        case Int32(SEEK_END):
            if let total = try? totalSize() { setPosition(total + offset) } else { return -1 }
        default:
            return -1
        }
        return currentPosition
    }

    // MARK: Position helpers

    private var currentPosition: Int64 {
        positionLock.lock(); defer { positionLock.unlock() }
        return position
    }

    private func setPosition(_ value: Int64) {
        positionLock.lock(); position = max(0, value); positionLock.unlock()
    }

    private func advancePosition(by delta: Int64) {
        positionLock.lock(); position += delta; positionLock.unlock()
    }

    // MARK: Synchronous range request

    /// Performs a synchronous `Range` GET and returns the body plus the parsed
    /// total length (from `Content-Range`, when present).
    private func performRange(lower: Int64, upper: Int64) throws -> (Data, Int64?) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("bytes=\(lower)-\(upper)", forHTTPHeaderField: "Range")

        let semaphore = DispatchSemaphore(value: 0)
        var resultData: Data?
        var resultTotal: Int64?
        var resultError: Error?

        let task = session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                resultError = ReaderError.transport(error.localizedDescription)
                return
            }
            guard let http = response as? HTTPURLResponse else {
                resultError = ReaderError.transport("no HTTP response")
                return
            }
            guard http.statusCode == 200 || http.statusCode == 206 else {
                resultError = ReaderError.http(http.statusCode)
                return
            }
            resultData = data ?? Data()
            resultTotal = Self.parseTotalLength(from: http)
        }
        task.resume()
        semaphore.wait()

        if let resultError { throw resultError }
        return (resultData ?? Data(), resultTotal)
    }

    /// Parses the resource's total length from a ranged response: the `/total`
    /// suffix of `Content-Range`, else `Content-Length` for a full `200`.
    private static func parseTotalLength(from http: HTTPURLResponse) -> Int64? {
        if let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
           let slash = contentRange.lastIndex(of: "/") {
            let totalPart = contentRange[contentRange.index(after: slash)...]
            if totalPart != "*", let total = Int64(totalPart.trimmingCharacters(in: .whitespaces)) {
                return total
            }
        }
        if http.statusCode == 200, http.expectedContentLength > 0 {
            return http.expectedContentLength
        }
        return nil
    }
}
