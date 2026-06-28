import Foundation

/// Track C's no-Cues persisted-index orchestration: the replay fast-path glue over
/// `KeyframeIndexCache`, WITHOUT ever doing a synchronous client scan of a no-Cues
/// file.
///
///  1. `loadCached` — at open, look up a persisted `KeyframeTable` for the source
///     (key = token-stripped host|path|size|round(duration)), validated by the
///     cache's size+duration guard PLUS a cheap HEAD ETag/Last-Modified compare
///     (catches a same-size/same-duration re-encode). A hit feeds
///     `RemuxSegmenter.applyExternalKeyframes` → exact-EXTINF static VOD at ~1s,
///     no scan. A miss returns nil so the caller starts now on B7's provisional
///     full-vod table.
///
///  2. `CachedProvider` — the cache exposed as one interchangeable `KeyframeProvider`
///     source behind the protocol Track A owns.
///
/// The PRODUCER side (first-watch background discovery → persist) is intentionally
/// NOT wired yet — it is HELD until the no-Cues class is sized by B6's "found N
/// CuePoints" result. When un-held, the background full-timeline walk runs on B5's
/// `MatroskaKeyframeSampler` (coordinator-granted for that one job: a single
/// sequential cluster-size-skip walk over the WHOLE timeline, a different access
/// pattern than B6's `plozz_remux_kf_probe_*` live per-seek probe, which stays the
/// canonical serving/far-seek primitive). The sampler is currently parked inert in
/// the test target and relocates to `Sources/LocalRemux/` when wired. The `persist`
/// entry point below is deliberately parser-agnostic so that wiring is a one-liner.
///
/// Behind `com.plozz.playback.remuxPersistIndex` (default OFF) at the call site, so
/// the default open path is byte-identical.
enum KeyframeIndexService {

    /// A source's HTTP validators, captured by a cheap HEAD at open. All optional —
    /// origins that don't support HEAD or omit validators simply yield nils and the
    /// cache falls back to its size+duration guard.
    struct SourceValidators {
        var size: Int64
        var etag: String?
        var lastModified: String?
    }

    // MARK: - Load (replay fast-path)

    /// Returns the persisted **`KeyframeTable`** for `url` when present and still
    /// valid for the current `size` + `duration` (+ optional ETag/Last-Modified),
    /// else nil. The shared `KeyframeTable { duration, times }` currency — identical
    /// to what Track A's Cues reader and a server endpoint emit — so a cache HIT is
    /// handed straight to the same `KeyframeProvider` / planner path. Pure disk + an
    /// already-captured validator; no scan, no large I/O.
    static func loadCached(url: URL, size: Int64, duration: Double,
                           validators: SourceValidators?,
                           cache: KeyframeIndexCache? = KeyframeIndexCache.makeDefault())
        -> KeyframeTable? {
        guard let cache, size > 0, duration > 0 else { return nil }
        let key = KeyframeIndexCache.key(url: url, size: size, duration: duration)
        guard let times = cache.load(key: key, expectedSize: size, expectedDuration: duration,
                                     expectedETag: validators?.etag,
                                     expectedLastModified: validators?.lastModified) else {
            return nil
        }
        let table = KeyframeTable(duration: duration, times: times)
        return table.isUsable ? table : nil
    }

    /// A `KeyframeProvider` backed by the persisted index — the cache as one of the
    /// interchangeable discovery sources behind the protocol Track A owns. Returns
    /// the cached `KeyframeTable` (HIT) or nil (MISS → caller falls through to the
    /// next provider, e.g. Cues / server / the background sampler build). Never
    /// scans: it only reads the tiny sidecar with an already-captured validator.
    struct CachedProvider: KeyframeProvider {
        let url: URL
        let size: Int64
        let duration: Double
        let validators: SourceValidators?
        var cache: KeyframeIndexCache? = KeyframeIndexCache.makeDefault()

        func keyframeTable() -> KeyframeTable? {
            KeyframeIndexService.loadCached(url: url, size: size, duration: duration,
                                            validators: validators, cache: cache)
        }
    }

    // MARK: - HEAD validators

    /// Cheap HEAD probe capturing the source size + ETag / Last-Modified for the
    /// cache guard. Synchronous (run it off the main actor). Returns nil only when
    /// the request fails outright; a 200/206 with no validators still yields a
    /// `SourceValidators` carrying size so size+duration validation proceeds.
    static func headValidators(url: URL, headers: [String: String] = [:],
                               timeout: TimeInterval = 10) -> SourceValidators? {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = timeout
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config)

        let semaphore = DispatchSemaphore(value: 0)
        var response: URLResponse?
        let task = session.dataTask(with: request) { _, resp, _ in
            response = resp
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + timeout)

        guard let http = response as? HTTPURLResponse, http.statusCode < 400 else {
            return nil
        }
        let etag = http.value(forHTTPHeaderField: "ETag")
        let lastModified = http.value(forHTTPHeaderField: "Last-Modified")
        let size: Int64 = http.expectedContentLength > 0 ? http.expectedContentLength : -1
        return SourceValidators(size: size, etag: etag, lastModified: lastModified)
    }

    // MARK: - Persist (producer entry point)

    /// Persists a discovered `KeyframeTable` for `url` under the content-stable key,
    /// so the next open is an instant cache HIT. Parser-AGNOSTIC by design: it takes
    /// the finished table, not a scanner, so whichever producer ran feeds it
    /// directly. For the no-Cues background full-walk that producer is B5's
    /// `MatroskaKeyframeSampler` (coordinator-granted for the whole-timeline walk);
    /// for Cues titles it is the Cues reader's `times`. Stores `times` only
    /// (offset-free; offsets are re-derived at mux via BACKWARD seek), plus the
    /// size/duration + optional ETag/Last-Modified validators. Best-effort: any
    /// failure is swallowed (caching is a pure optimisation).
    @discardableResult
    static func persist(_ table: KeyframeTable, url: URL, size: Int64, duration: Double,
                        target: Double, validators: SourceValidators?,
                        cache: KeyframeIndexCache? = KeyframeIndexCache.makeDefault()) -> Bool {
        guard let cache, size > 0, duration > 0, table.isUsable else { return false }
        let key = KeyframeIndexCache.key(url: url, size: size, duration: duration)
        cache.store(key: key, size: size, duration: duration, target: target,
                    times: table.times,
                    etag: validators?.etag, lastModified: validators?.lastModified)
        return true
    }
}
