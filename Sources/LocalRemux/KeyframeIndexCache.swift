import Foundation
import CryptoKit

/// A small on-disk cache of the **real keyframe times (PTS)** discovered for a
/// remuxed source the first time it was played.
///
/// Discovering keyframe-accurate segment boundaries on a Matroska file whose Cues
/// index is missing/degenerate is inherently expensive — the Cues *are* the
/// keyframe→byte map, so without them the boundaries can only be found by reading
/// or seeking through the stream (see `plozz_remux_rescan_keyframe_segments`).
/// That cost is wasteful to repeat: the boundaries never change for a given file.
///
/// This cache persists the discovered boundary list keyed by a **token-stripped,
/// content-stable identity** (host + path + byte size + duration), so a *resume*
/// from an arbitrary offset, a re-watch, or a relaunch reopens the title
/// INSTANTLY with the exact same keyframe-aligned table (no scan, no I/O beyond a
/// tiny sidecar read). It composes with any first-watch discovery strategy: the
/// expensive exact scan is paid at most once per title, ever.
///
/// Pure value type over an injectable directory so the key derivation and the
/// store/load round-trip are unit-testable without touching the real caches dir.
struct KeyframeIndexCache {

    /// Persisted payload (versioned). `size` + `duration` are re-validated on load
    /// so a file that was replaced/re-encoded under the same URL can't restore a
    /// stale boundary list. `etag` / `lastModified` are an OPTIONAL second guard:
    /// captured from a cheap HEAD at open, they catch the rare same-size *and*
    /// same-duration re-encode that the size/duration guard alone would miss. Both
    /// are `Codable` optionals so entries written before this field, and entries
    /// for servers that expose no validator, decode and validate unchanged.
    private struct Entry: Codable {
        var v: Int
        var size: Int64
        var duration: Double
        var target: Double
        /// Raw keyframe **times (PTS seconds)** — NOT baked cumulative cut points.
        /// Storing the fundamental keyframe list (rather than one cadence's
        /// boundaries) lets `RemuxSegmentPlanner` re-derive segments for any target
        /// cadence on load, and keeps ONE definition across producers: B5/B6's Cues
        /// reader emits `readCues().map { $0.seconds }`, Track C's no-Cues discovery
        /// emits the same shape — both land here as `KeyframeTable.times`.
        var times: [Double]
        var etag: String?
        var lastModified: String?
    }

    /// Current payload version; bump to invalidate all prior entries on a format
    /// change. v2: payload stores raw keyframe `times` (PTS) rather than baked
    /// `boundaries` (cumulative cut points).
    static let version = 2

    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    /// The default cache living under the app's Caches directory. Returns nil only
    /// if the caches directory can't be resolved/created (then callers simply skip
    /// caching — never fatal).
    static func makeDefault(fileManager: FileManager = .default) -> KeyframeIndexCache? {
        guard let caches = try? fileManager.url(for: .cachesDirectory, in: .userDomainMask,
                                                appropriateFor: nil, create: true) else {
            return nil
        }
        let dir = caches.appendingPathComponent("PlozzKeyframeIndex", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return KeyframeIndexCache(directory: dir)
    }

    // MARK: - Key

    /// A stable cache key for a source. Deliberately ignores the URL **query**
    /// (Plex/Jellyfin embed a rotating auth token there, which must not change the
    /// identity of the same media) and folds in the byte size + rounded duration
    /// so different content served from the same path can't collide.
    static func key(url: URL, size: Int64, duration: Double) -> String {
        let host = url.host ?? ""
        let path = url.path
        let raw = "\(host)|\(path)|\(size)|\(Int(duration.rounded()))"
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func fileURL(for key: String) -> URL {
        directory.appendingPathComponent("\(key).json", isDirectory: false)
    }

    // MARK: - Load / store

    /// Returns the cached keyframe time list for `key` when present and its
    /// recorded `size` + `duration` still match the current source (so a replaced
    /// file is treated as a miss). nil on any mismatch / decode failure / absence.
    ///
    /// `expectedETag` / `expectedLastModified` are an optional second guard: when a
    /// caller supplies one (from a cheap HEAD at open) AND the stored entry recorded
    /// the same kind of validator, a mismatch is treated as a miss — catching the
    /// rare same-size/same-duration re-encode. When the caller passes nil (server
    /// exposes no validator) the entry is judged on size+duration alone, so the
    /// fast path still works against origins without ETags.
    func load(key: String, expectedSize: Int64, expectedDuration: Double,
              expectedETag: String? = nil, expectedLastModified: String? = nil,
              fileManager: FileManager = .default) -> [Double]? {
        let url = fileURL(for: key)
        guard let data = try? Data(contentsOf: url),
              let entry = try? JSONDecoder().decode(Entry.self, from: data),
              entry.v == Self.version,
              entry.times.count >= 2 else {
            return nil
        }
        // Content guard: a re-encode under the same URL changes size/duration.
        guard entry.size == expectedSize,
              abs(entry.duration - expectedDuration) <= 1.0 else {
            return nil
        }
        // Validator guard (only when both sides have one): a same-size/same-duration
        // re-encode still changes the ETag / Last-Modified, so an explicit mismatch
        // is a miss. Absent on either side → skip (size+duration already passed).
        if let want = expectedETag, let have = entry.etag, want != have { return nil }
        if let want = expectedLastModified, let have = entry.lastModified,
           expectedETag == nil, entry.etag == nil, want != have {
            return nil
        }
        // Sanity: strictly increasing, non-negative (a corrupt list must never
        // produce zero/negative-duration segments).
        var prev = -1.0
        for t in entry.times {
            if !(t.isFinite) || t < 0 || t <= prev - 1e-9 { return nil }
            prev = t
        }
        return entry.times
    }

    /// Persists keyframe `times` for `key` (atomic write). Best-effort: any failure
    /// is swallowed (caching is a pure optimisation, never required for
    /// correctness). `etag` / `lastModified` are recorded when the source exposed
    /// them at open so a later `load` can apply the validator guard.
    func store(key: String, size: Int64, duration: Double, target: Double,
               times: [Double], etag: String? = nil, lastModified: String? = nil) {
        guard times.count >= 2 else { return }
        let entry = Entry(v: Self.version, size: size, duration: duration,
                          target: target, times: times,
                          etag: etag, lastModified: lastModified)
        guard let data = try? JSONEncoder().encode(entry) else { return }
        try? data.write(to: fileURL(for: key), options: .atomic)
    }
}
