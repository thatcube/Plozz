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

    /// Background read-ahead (flag `com.plozz.playback.remuxPrefetch`). When > 0,
    /// after each on-demand segment is served the source produces the next
    /// `prefetchDepth` segments ahead of the playhead on a background queue, so a
    /// high-bitrate 4K title's sequential segments are cache-warm before AVPlayer
    /// asks — decoupling production (fetch+mux) from just-in-time delivery so the
    /// audio buffer never underruns. 0 (default/flag-off) = the original strictly
    /// on-demand behaviour, zero overhead.
    private let prefetchDepth: Int
    private let prefetchQueue = DispatchQueue(
        label: "com.thatcube.Plozz.localremux.prefetch", qos: .utility)
    /// Highest segment index AVPlayer has requested; the prefetch window follows
    /// it so a seek re-aims read-ahead at the new playhead. Guarded by `cacheLock`.
    private var prefetchCursor = -1
    /// Whether a prefetch worker pass is queued/running (one at a time). `cacheLock`.
    private var prefetchScheduled = false
    /// Segment indices a prefetch pass is currently producing, so the worker never
    /// double-schedules one. Guarded by `cacheLock`.
    private var prefetchInFlight: Set<Int> = []
    /// Set on teardown so an in-progress prefetch worker stops promptly. `cacheLock`.
    private var stopped = false

    /// B7 lazy/windowed index. When true the segment timeline is discovered
    /// PROGRESSIVELY: the media playlist is served as a growing EVENT playlist (not
    /// pinned) until discovery reaches EOF, a background driver extends the frontier
    /// off the playback-critical path, and the in-range segment bound follows the
    /// live published count rather than a fixed total. When false (default) the
    /// behaviour is byte-identical to the original VOD path.
    private let lazyEnabled: Bool
    /// Live published segment count (lazy mode); for non-lazy it equals the fixed
    /// total. Guarded by `cacheLock`.
    private var liveSegmentCount: Int
    /// Live published segment durations for the EVENT media playlist. `cacheLock`.
    private var liveSegmentDurations: [Double]
    /// Whether progressive discovery has reached EOF (timeline complete). `cacheLock`.
    private var lazyComplete: Bool
    /// Whether the background discovery driver has been started (once). `cacheLock`.
    private var lazyFillStarted = false
    private let lazyQueue = DispatchQueue(
        label: "com.thatcube.Plozz.localremux.lazyindex", qos: .userInitiated)
    /// Uptime (ns) the session began driving discovery, for the fill-rate telemetry.
    private var lazyFillStartNanos: UInt64 = 0
    /// B7 windowed-fill state (all `cacheLock`). The background driver must NOT race
    /// the frontier to EOF — that re-creates the brutal upfront I/O (just moved off
    /// the open path) AND starves the foreground segment mux of the shared demuxer
    /// lock. Instead it keeps the published timeline only `lazyWindowAhead` segments
    /// ahead of the playhead and then IDLES until playback advances.
    /// `lazyPlayhead` = highest segment index AVPlayer has requested.
    private var lazyPlayhead = 0
    /// Count of in-flight FOREGROUND (on-demand, non-prefetch) segment muxes. While
    /// > 0 the background fill yields so a just-in-time segment never waits behind a
    /// discovery batch (the fix for seg1 starving to 20s → teardown → seg2 404).
    private var foregroundMuxPending = 0
    /// Keep this many segments published ahead of the playhead, then idle.
    private let lazyWindowAhead = 16

    let segmentCount: Int

    init(segmenter: RemuxSegmenter, planner: RemuxSegmentPlanner,
         segmentCacheLimitBytes: Int = 96 << 20, prefetchDepth: Int = 0,
         lazyEnabled: Bool = false) {
        self.segmenter = segmenter
        self.planner = planner
        self.segmentCacheLimitBytes = segmentCacheLimitBytes
        self.prefetchDepth = max(0, prefetchDepth)
        self.lazyEnabled = lazyEnabled
        if lazyEnabled {
            let durations = segmenter.currentSegmentDurations()
            self.liveSegmentDurations = durations
            self.liveSegmentCount = durations.count
            self.lazyComplete = false
            self.segmentCount = 0   // unused in lazy mode (bound follows liveSegmentCount)
        } else {
            self.liveSegmentDurations = planner.segmentDurations
            self.liveSegmentCount = planner.segmentDurations.count
            self.lazyComplete = true
            self.segmentCount = planner.segmentDurations.count
        }
    }

    /// Stops background prefetch. Called on session teardown BEFORE the segmenter
    /// is closed so the worker doesn't drive a freed demuxer.
    func stop() {
        cacheLock.lock()
        stopped = true
        cacheLock.unlock()
    }

    // MARK: - B7 lazy/windowed background discovery

    /// Starts the background driver that progressively discovers the rest of the
    /// timeline's real keyframe boundaries, OFF the playback-critical path. Each
    /// pass advances the frontier by a small, bounded probe budget (releasing the
    /// demuxer lock between batches so on-demand muxing interleaves), republishing
    /// the growing EVENT playlist, until discovery reaches EOF. Idempotent; a no-op
    /// when lazy mode is off. The fill is much faster than realtime playback, so the
    /// timeline typically becomes a complete VOD list within seconds — after which
    /// far-scrub is instant. Crash-safe: bounded, cancellable, never a synchronous
    /// O(filesize) or O(total-segments) stall.
    func startLazyFill() {
        guard lazyEnabled else { return }
        cacheLock.lock()
        if lazyFillStarted || stopped || lazyComplete { cacheLock.unlock(); return }
        lazyFillStarted = true
        lazyFillStartNanos = DispatchTime.now().uptimeNanoseconds
        cacheLock.unlock()
        lazyQueue.async { [weak self] in self?.lazyFillLoop() }
    }

    private func lazyFillLoop() {
        // WINDOWED background discovery. Two hard rules learned on-device (a frontier
        // race to EOF pulled 594MB in 30s AND starved the foreground mux → seg1 took
        // 20s → teardown → seg2 404):
        //  1) Never extend more than `lazyWindowAhead` segments past the playhead;
        //     idle until playback advances. Discovery cost stays local to the window.
        //  2) Yield to the foreground: hold the demuxer lock only for SMALL probe
        //     batches, and pause entirely while an on-demand segment mux is pending.
        let batchProbes = 8
        var totalProbes = 0
        var passes = 0
        let fillNetStart = segmenter.networkSnapshot()
        while true {
            cacheLock.lock()
            let stop = stopped || lazyComplete
            let playhead = lazyPlayhead
            let published = liveSegmentCount
            let foregroundPending = foregroundMuxPending
            cacheLock.unlock()
            if stop { break }

            // Foreground priority: a just-in-time segment is muxing — get out of its
            // way (don't contend for the shared demuxer lock) and re-check shortly.
            if foregroundPending > 0 {
                usleep(5_000)
                continue
            }

            // Windowed: already enough runway ahead of the playhead → idle until
            // AVPlayer advances (or a seek jumps the playhead forward).
            if published >= playhead + lazyWindowAhead {
                usleep(120_000)
                continue
            }

            let progress = segmenter.extendLazyIndex(untilSeconds: 0, maxProbes: batchProbes)
            totalProbes += progress.probes
            passes += 1

            let durations = segmenter.currentSegmentDurations()
            cacheLock.lock()
            liveSegmentDurations = durations
            liveSegmentCount = durations.count
            lazyComplete = progress.complete
            let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds &- lazyFillStartNanos) / 1_000_000
            cacheLock.unlock()

            // Periodic + terminal fill telemetry (the coordinator greps `remux-lazy:`).
            // fill-bytes is the cumulative BACKGROUND discovery cost; because it's
            // windowed it tracks the playhead, never the whole timeline up front.
            if progress.complete || passes % 8 == 0 {
                let net = segmenter.networkSnapshot()
                let fillBytes = max(0, net.bytesFetched - fillNetStart.bytesFetched)
                RemuxLog.info(String(format:
                    "remux-lazy: fill ready=%d complete=%@ probes=%d elapsed=%.0fms fill-bytes=%.2fMB playhead=%d window=%d header-reads=%d",
                    durations.count, progress.complete ? "YES" : "no", totalProbes, elapsedMs,
                    Double(fillBytes) / 1_048_576.0, playhead, lazyWindowAhead,
                    segmenter.lazyHeaderReads()))
            }
            if progress.complete { break }
            // No progress and not complete (e.g. transient seek failure): avoid a
            // hot spin — back off briefly before retrying.
            if progress.probes == 0 {
                usleep(50_000)
            } else {
                // Yield the lock briefly so a foreground mux thread (NSLock is not
                // fair) can acquire the demuxer between batches.
                usleep(2_000)
            }
        }
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
            // Lazy/EVENT mode: the playlist grows as discovery extends, so it must
            // NOT be pinned until the timeline is complete — each AVPlayer reload
            // sees the latest published segments. Once complete it's the final VOD
            // list and gets pinned like the original path.
            if lazyEnabled {
                return lazyMediaPlaylistBytes()
            }
            return pinnedBytes(route.resourceName) { self.planner.mediaPlaylist().data(using: .utf8) ?? Data() }
        case .initSegment:
            return pinnedBytes(route.resourceName) { self.segmenter.initSegment() }
        case .segment(let index):
            let bound = currentSegmentBound()
            guard index >= 0, index < bound else {
                RemuxLog.error("Origin: segment \(index) out of range (count=\(bound))")
                return nil
            }
            // Advance the playhead so the windowed background fill follows AVPlayer
            // (a seek jumps it forward; the window re-aims around the new position).
            if lazyEnabled {
                cacheLock.lock()
                if index > lazyPlayhead { lazyPlayhead = index }
                cacheLock.unlock()
            }
            return segmentBytes(index)
        }
    }

    /// The in-range bound for a requested segment index. In lazy mode this follows
    /// the live published count (which grows as discovery extends); otherwise it's
    /// the fixed total.
    private func currentSegmentBound() -> Int {
        guard lazyEnabled else { return segmentCount }
        cacheLock.lock(); defer { cacheLock.unlock() }
        return liveSegmentCount
    }

    /// Builds the current EVENT (or, once complete, VOD) media playlist from the
    /// live published durations. Pinned only once discovery is complete.
    private func lazyMediaPlaylistBytes() -> Data? {
        cacheLock.lock()
        let durations = liveSegmentDurations
        let complete = lazyComplete
        if complete, let cached = pinned[RemuxRoute.mediaName] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let text = planner.mediaPlaylist(durations: durations, complete: complete)
        let data = text.data(using: .utf8) ?? Data()
        if complete {
            cacheLock.lock()
            pinned[RemuxRoute.mediaName] = data
            cacheLock.unlock()
        }
        return data
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

        let produced = produceSegment(index, isPrefetch: false)
        // Kick read-ahead forward from this playhead (no-op when prefetch is off).
        schedulePrefetch(playhead: index)
        return produced
    }

    /// Produces (fetch + `-c copy` mux), caches, and throughput-logs one segment,
    /// serialised behind `productionLock` (the C demuxer is single-threaded) with a
    /// double-checked cache lookup so an on-demand request and a background prefetch
    /// can never mux the same index twice. Shared by the on-demand and prefetch
    /// paths. Returns the bytes, or `nil` if the mux failed after one retry.
    @discardableResult
    private func produceSegment(_ index: Int, isPrefetch: Bool) -> Data? {
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
        // drove, and the cadence gap since the previous mux. A mux that takes
        // longer than the segment's own duration cannot keep AVPlayer fed, so
        // playback stalls/stutters — this line pinpoints that vs a clean
        // timeline-drift bug (which would mux fast but play out of sync).
        let netBefore = segmenter.networkSnapshot()
        let muxStart = DispatchTime.now().uptimeNanoseconds
        let gapNanos: UInt64 = lastSegmentServedUptimeNanos == 0
            ? 0 : muxStart &- lastSegmentServedUptimeNanos

        // Foreground priority: while a just-in-time (non-prefetch) segment is being
        // muxed, the background discovery driver yields the shared demuxer lock so
        // this mux never waits behind a probe batch.
        let foreground = lazyEnabled && !isPrefetch
        if foreground {
            cacheLock.lock(); foregroundMuxPending += 1; cacheLock.unlock()
        }
        var data = segmenter.mediaSegment(index)
        if data == nil || data?.isEmpty == true {
            // Never 404 a declared segment on a transient failure: retry once.
            RemuxLog.error("Origin: segment \(index) mux returned empty — retrying once")
            data = segmenter.mediaSegment(index)
        }
        if foreground {
            cacheLock.lock(); foregroundMuxPending = max(0, foregroundMuxPending - 1); cacheLock.unlock()
        }
        guard let produced = data, !produced.isEmpty else {
            RemuxLog.error("Origin: segment \(index) mux FAILED after retry")
            return nil
        }

        let muxEnd = DispatchTime.now().uptimeNanoseconds
        lastSegmentServedUptimeNanos = muxEnd
        logThroughput(index: index, isPrefetch: isPrefetch, bytesOut: produced.count,
                      muxNanos: muxEnd &- muxStart, gapNanos: gapNanos,
                      netBefore: netBefore, netAfter: segmenter.networkSnapshot())

        insertSegment(index, produced)
        return produced
    }

    // MARK: - Background prefetch (read-ahead)

    /// Advances the prefetch window to follow `playhead` and ensures a worker pass
    /// is running. No-op when `prefetchDepth == 0` (flag off) or torn down.
    private func schedulePrefetch(playhead index: Int) {
        guard prefetchDepth > 0 else { return }
        cacheLock.lock()
        if stopped { cacheLock.unlock(); return }
        if index > prefetchCursor { prefetchCursor = index }
        let needsWorker = !prefetchScheduled
        if needsWorker { prefetchScheduled = true }
        cacheLock.unlock()
        if needsWorker {
            prefetchQueue.async { [weak self] in self?.prefetchWorker() }
        }
    }

    /// Serially produces the next uncached segments inside the window
    /// `(cursor, cursor+prefetchDepth]`, re-reading the cursor between segments so
    /// a seek re-aims the read-ahead at the new playhead. Exits when the window is
    /// full (all cached / in flight) or on teardown.
    private func prefetchWorker() {
        while true {
            cacheLock.lock()
            if stopped { prefetchScheduled = false; cacheLock.unlock(); return }
            let cursor = prefetchCursor
            let maxIndex = min(cursor + prefetchDepth, liveSegmentCount - 1)
            var target = -1
            var i = cursor + 1
            while i <= maxIndex {
                if segmentCache[i] == nil && !prefetchInFlight.contains(i) { target = i; break }
                i += 1
            }
            if target < 0 { prefetchScheduled = false; cacheLock.unlock(); return }
            prefetchInFlight.insert(target)
            cacheLock.unlock()

            produceSegment(target, isPrefetch: true)

            cacheLock.lock()
            prefetchInFlight.remove(target)
            cacheLock.unlock()
        }
    }

    /// Emits the always-on per-segment throughput/cadence telemetry line.
    private func logThroughput(index: Int, isPrefetch: Bool, bytesOut: Int, muxNanos: UInt64,
                               gapNanos: UInt64,
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
            format: "remux-tput: seg=%d kind=%@ dur=%.2fs mux=%.0fms gap=%.0fms out=%.2fMB(%.1fMB/s) "
                + "net=%.0fms in=%.2fMB(%.1fMB/s) fetches=%d starved=%@",
            index, isPrefetch ? "pf" : "od", duration, muxMs, gapMs, outMB, muxRate,
            netMs, inMB, fetchRate, fetches, starved ? "YES" : "no"))
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
