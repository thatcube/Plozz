import Foundation

/// Owns the locally-remuxed bytes the loopback origin serves for one title and the
/// caching/concurrency policy that makes far seeks robust:
///
///   * The master + media playlists and the shared `EXT-X-MAP` init segment are
///     produced once and pinned forever (they are tiny and every seek needs them).
///   * Media segments are produced on demand by the C remuxer (`-c copy`, from the
///     nearest source keyframe) and held in a bounded LRU so a burst of seek-ahead
///     requests and the inevitable "Range then full" re-reads don't re-mux.
///   * Production is serialised (the C demuxer is single-threaded) with a
///     double-checked cache lookup so two concurrent requests for the same segment
///     mux it once, and cache *hits* stay concurrent.
///   * A declared segment is NEVER reported missing: on a transient mux failure it
///     retries once before giving up, and an evicted segment is simply re-produced.
///
/// All public methods are safe to call from many connection handlers at once.
final class RemuxContentSource: @unchecked Sendable {

    /// A produced resource: its bytes and whether it is a pinned (playlist/init)
    /// entry that must never be evicted.
    struct Produced {
        let data: Data
        let route: RemuxRoute
    }

    /// Notified (off the main actor) as bytes are produced, so the session can fold
    /// them into the shared `LocalRemuxMetricsController` for the overlay.
    var onMetrics: (@Sendable (_ distinctSegments: Int, _ bytesProduced: Int64) -> Void)?

    private let segmenter: RemuxSegmenter
    private let planner: RemuxSegmentPlanner

    /// Guards the caches and counters; cheap, held only around dictionary ops.
    private let cacheLock = NSLock()
    /// Serialises the actual C remux calls (the demuxer is single-threaded).
    private let productionLock = NSLock()

    private var pinned: [String: Data] = [:]
    private var segmentCache: [Int: Data] = [:]
    /// LRU order of cached segment indices (oldest first).
    private var lru: [Int] = []
    private var segmentCacheBytes: Int = 0
    private let segmentCacheLimitBytes: Int

    private var distinctSegmentsProduced = 0
    private var totalBytesProduced: Int64 = 0

    /// Wall-clock (uptime ns) the previous on-demand segment mux finished, so the
    /// per-segment throughput line can report the inter-request cadence gap — a
    /// long gap before a just-in-time mux is the server-side fingerprint of an
    /// AVPlayer rebuffer/stall.
    private var lastSegmentServedUptimeNanos: UInt64 = 0

    let segmentCount: Int

    init(segmenter: RemuxSegmenter, planner: RemuxSegmentPlanner, segmentCacheLimitBytes: Int = 96 << 20) {
        self.segmenter = segmenter
        self.planner = planner
        self.segmentCacheLimitBytes = segmentCacheLimitBytes
        self.segmentCount = planner.segmentDurations.count
    }

    // MARK: - Serving

    /// Returns the bytes + content type for a request path, or `nil` for an unknown
    /// resource (→ the server replies 404). A declared in-range segment that fails
    /// to mux is retried once before `nil` is returned, so seek-ahead never trips a
    /// spurious 404 on a segment the playlist promised.
    func response(forPath path: String) -> (data: Data, contentType: String)? {
        guard let route = RemuxRoute.parse(path: path) else {
            RemuxLog.error("Origin: unknown resource path=\(path)")
            return nil
        }
        guard let data = bytes(for: route) else { return nil }
        return (data, route.contentType)
    }

    private func bytes(for route: RemuxRoute) -> Data? {
        switch route {
        case .master:
            return pinnedBytes(route.resourceName) { self.planner.masterPlaylist().data(using: .utf8) ?? Data() }
        case .media:
            return pinnedBytes(route.resourceName) { self.planner.mediaPlaylist().data(using: .utf8) ?? Data() }
        case .initSegment:
            return pinnedBytes(route.resourceName) { self.segmenter.initSegment() }
        case .segment(let index):
            guard index >= 0, index < segmentCount else {
                RemuxLog.error("Origin: segment \(index) out of range (count=\(segmentCount))")
                return nil
            }
            return segmentBytes(index)
        }
    }

    // MARK: - Pinned resources (playlists + init)

    private func pinnedBytes(_ name: String, _ make: () -> Data?) -> Data? {
        cacheLock.lock()
        if let cached = pinned[name] { cacheLock.unlock(); return cached }
        cacheLock.unlock()

        productionLock.lock()
        defer { productionLock.unlock() }
        // Double-check: another thread may have produced it while we waited.
        cacheLock.lock()
        if let cached = pinned[name] { cacheLock.unlock(); return cached }
        cacheLock.unlock()

        guard let data = make(), !data.isEmpty else {
            RemuxLog.error("Origin: failed to produce pinned resource \(name)")
            return nil
        }
        cacheLock.lock()
        pinned[name] = data
        cacheLock.unlock()
        return data
    }

    // MARK: - Media segments

    private func segmentBytes(_ index: Int) -> Data? {
        // Fast path: a concurrent cache hit needs no production lock.
        cacheLock.lock()
        if let cached = segmentCache[index] {
            touchLRU(index)
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        productionLock.lock()
        defer { productionLock.unlock() }
        // Double-check under the production lock: a peer may have just muxed it.
        cacheLock.lock()
        if let cached = segmentCache[index] {
            touchLRU(index)
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        // Throughput-starvation diagnostic: time the mux and the network the mux
        // drove, and the cadence gap since the previous on-demand mux. A mux that
        // takes longer than the segment's own duration cannot keep AVPlayer fed,
        // so playback stalls/stutters — this line pinpoints that vs a clean
        // timeline-drift bug (which would mux fast but play out of sync).
        let netBefore = segmenter.networkSnapshot()
        let muxStart = DispatchTime.now().uptimeNanoseconds
        let gapNanos: UInt64 = lastSegmentServedUptimeNanos == 0
            ? 0 : muxStart &- lastSegmentServedUptimeNanos

        var data = segmenter.mediaSegment(index)
        if data == nil || data?.isEmpty == true {
            // Never 404 a declared segment on a transient failure: retry once.
            RemuxLog.error("Origin: segment \(index) mux returned empty — retrying once")
            data = segmenter.mediaSegment(index)
        }
        guard let produced = data, !produced.isEmpty else {
            RemuxLog.error("Origin: segment \(index) mux FAILED after retry")
            return nil
        }

        let muxEnd = DispatchTime.now().uptimeNanoseconds
        lastSegmentServedUptimeNanos = muxEnd
        logThroughput(index: index, bytesOut: produced.count,
                      muxNanos: muxEnd &- muxStart, gapNanos: gapNanos,
                      netBefore: netBefore, netAfter: segmenter.networkSnapshot())

        insertSegment(index, produced)
        return produced
    }

    /// Emits the always-on per-segment throughput/cadence telemetry line.
    private func logThroughput(index: Int, bytesOut: Int, muxNanos: UInt64, gapNanos: UInt64,
                               netBefore: HTTPRangeReader.NetworkSnapshot,
                               netAfter: HTTPRangeReader.NetworkSnapshot) {
        let muxMs = Double(muxNanos) / 1_000_000
        let gapMs = Double(gapNanos) / 1_000_000
        let fetchedBytes = max(0, netAfter.bytesFetched - netBefore.bytesFetched)
        let netMs = Double(max(0, netAfter.networkWaitNanos - netBefore.networkWaitNanos)) / 1_000_000
        let fetches = netAfter.fetchCount - netBefore.fetchCount
        let outMB = Double(bytesOut) / 1_048_576
        let inMB = Double(fetchedBytes) / 1_048_576
        let muxRate = muxMs > 0 ? outMB / (muxMs / 1000) : 0
        let fetchRate = netMs > 0 ? inMB / (netMs / 1000) : 0
        let duration = (index >= 0 && index < planner.segmentDurations.count)
            ? planner.segmentDurations[index] : 0
        // starved=YES when producing this segment took longer than the segment's
        // own playback duration — AVPlayer cannot stay ahead of real time.
        let starved = duration > 0 && (muxMs / 1000) > duration
        RemuxLog.info(String(
            format: "remux-tput: seg=%d dur=%.2fs mux=%.0fms gap=%.0fms out=%.2fMB(%.1fMB/s) "
                + "net=%.0fms in=%.2fMB(%.1fMB/s) fetches=%d starved=%@",
            index, duration, muxMs, gapMs, outMB, muxRate, netMs, inMB, fetchRate, fetches,
            starved ? "YES" : "no"))
    }

    /// Stores a freshly produced segment, updates counters, and evicts the LRU tail
    /// until the cache is back under its byte budget. Must hold neither lock on
    /// entry (it takes `cacheLock` itself).
    private func insertSegment(_ index: Int, _ data: Data) {
        cacheLock.lock()
        if segmentCache[index] == nil {
            segmentCache[index] = data
            segmentCacheBytes += data.count
            lru.append(index)
            distinctSegmentsProduced += 1
            totalBytesProduced += Int64(data.count)
        }
        // Evict oldest until under budget (never evict below one segment).
        while segmentCacheBytes > segmentCacheLimitBytes, lru.count > 1 {
            let victim = lru.removeFirst()
            if victim == index { lru.append(victim); continue }
            if let evicted = segmentCache.removeValue(forKey: victim) {
                segmentCacheBytes -= evicted.count
            }
        }
        let distinct = distinctSegmentsProduced
        let bytes = totalBytesProduced
        cacheLock.unlock()

        onMetrics?(distinct, bytes)
    }

    /// Moves `index` to the most-recently-used end. Caller holds `cacheLock`.
    private func touchLRU(_ index: Int) {
        if let pos = lru.firstIndex(of: index) {
            lru.remove(at: pos)
            lru.append(index)
        }
    }
}
