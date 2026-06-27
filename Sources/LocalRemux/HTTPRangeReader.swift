import Foundation

/// Synchronous HTTP byte-range reader backing the remux core's custom AVIO. The
/// remux core pulls the original MKV lazily: it calls `read`/`seek` (on a
/// background queue, never the main thread) and this reader satisfies them with
/// ranged `GET`s against the provider's static file URL.
///
/// The source URL is self-authenticating (Jellyfin `?api_key=`, Plex
/// `?X-Plex-Token=`), so no extra headers are required — but a header map is
/// accepted for completeness. A small trailing read-ahead cache collapses the
/// many small sequential reads libavformat issues during demux/seek into fewer
/// round-trips.
final class HTTPRangeReader: @unchecked Sendable {
    private let url: URL
    private let headers: [String: String]
    private let session: URLSession

    private var position: Int64 = 0
    private(set) var totalSize: Int64 = -1

    /// Read-ahead cache: a contiguous block `[cacheStart, cacheStart+cache.count)`.
    private var cache = Data()
    private var cacheStart: Int64 = 0
    /// Over-read granularity: fetch at least this many bytes per network round-trip.
    private let readAhead: Int

    init(url: URL, headers: [String: String] = [:], readAhead: Int = 1 << 20) {
        self.url = url
        self.headers = headers
        self.readAhead = readAhead
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    // MARK: - AVIO surface

    /// Total byte size, fetched once via a ranged probe (`Content-Range`/length).
    func size() -> Int64 {
        if totalSize >= 0 { return totalSize }
        _ = fetch(offset: 0, length: 1) // primes totalSize from Content-Range
        return totalSize
    }

    /// Fills `buffer` with up to `count` bytes from the current position; returns
    /// the number of bytes read, 0 at EOF, or -1 on error. Advances the position.
    func read(into buffer: UnsafeMutablePointer<UInt8>, count: Int) -> Int {
        guard count > 0 else { return 0 }
        if totalSize >= 0 && position >= totalSize { return 0 }

        // Serve from cache when the position is inside the cached block.
        if let n = readFromCache(into: buffer, count: count) { return n }

        // Refill the cache with a read-ahead block at the current position.
        let want = max(count, readAhead)
        guard let block = fetch(offset: position, length: want), !block.isEmpty else {
            return totalSize >= 0 && position >= totalSize ? 0 : -1
        }
        cache = block
        cacheStart = position

        if let n = readFromCache(into: buffer, count: count) { return n }
        return -1
    }

    /// Seek to `offset` per `whence` (SEEK_SET/CUR/END). Returns the new absolute
    /// position, or -1 on error.
    func seek(offset: Int64, whence: Int32) -> Int64 {
        let SEEK_SET_: Int32 = 0, SEEK_CUR_: Int32 = 1, SEEK_END_: Int32 = 2
        let base: Int64
        switch whence {
        case SEEK_SET_: base = 0
        case SEEK_CUR_: base = position
        case SEEK_END_: base = size()
        default: return -1
        }
        let target = base + offset
        if target < 0 { return -1 }
        position = target
        return position
    }

    // MARK: - Cache

    private func readFromCache(into buffer: UnsafeMutablePointer<UInt8>, count: Int) -> Int? {
        let cacheEnd = cacheStart + Int64(cache.count)
        guard position >= cacheStart, position < cacheEnd else { return nil }
        let localOffset = Int(position - cacheStart)
        let available = cache.count - localOffset
        let n = min(count, available)
        cache.withUnsafeBytes { raw in
            let src = raw.baseAddress!.advanced(by: localOffset)
            buffer.update(from: src.assumingMemoryBound(to: UInt8.self), count: n)
        }
        position += Int64(n)
        return n
    }

    // MARK: - Network

    /// Performs a synchronous ranged GET. Updates `totalSize` from the response
    /// `Content-Range` (or `Content-Length` for a full 200). Returns the body or
    /// `nil` on failure.
    private func fetch(offset: Int64, length: Int) -> Data? {
        var request = URLRequest(url: url)
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        let end = offset + Int64(length) - 1
        request.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")

        let semaphore = DispatchSemaphore(value: 0)
        var resultData: Data?
        var resultResponse: URLResponse?
        var resultError: Error?
        let task = session.dataTask(with: request) { data, response, error in
            resultData = data
            resultResponse = response
            resultError = error
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()

        if let http = resultResponse as? HTTPURLResponse {
            updateTotalSize(from: http)
            let status = http.statusCode
            if status >= 400 || resultData == nil {
                // Auth/redirect/range failures here are the most likely reason a
                // locally-muxed segment comes back empty → origin 404 → AVPlayer
                // -1011. Always log them (redacted) so a single repro reveals it.
                RemuxLog.error("RangeReader: GET bytes=\(offset)-\(end) -> HTTP \(status) bytes=\(resultData?.count ?? -1) url=\(RemuxLog.redact(url))")
            } else if offset == 0 && length <= 1 {
                RemuxLog.info("RangeReader: size probe -> HTTP \(status) total=\(totalSize) url=\(RemuxLog.redact(url))")
            }
        } else if let resultError {
            RemuxLog.error("RangeReader: GET bytes=\(offset)-\(end) failed \(resultError.localizedDescription) url=\(RemuxLog.redact(url))")
        } else {
            RemuxLog.error("RangeReader: GET bytes=\(offset)-\(end) no HTTP response url=\(RemuxLog.redact(url))")
        }
        return resultData
    }

    private func updateTotalSize(from http: HTTPURLResponse) {
        guard totalSize < 0 else { return }
        // Prefer Content-Range "bytes a-b/total".
        if let cr = http.value(forHTTPHeaderField: "Content-Range"),
           let slash = cr.lastIndex(of: "/") {
            let totalStr = cr[cr.index(after: slash)...].trimmingCharacters(in: .whitespaces)
            if let total = Int64(totalStr) { totalSize = total; return }
        }
        // Full 200 response: Content-Length is the whole file.
        if http.statusCode == 200, http.expectedContentLength > 0 {
            totalSize = http.expectedContentLength
        }
    }
}
