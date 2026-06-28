import Foundation
import CryptoKit

/// A small on-disk cache of the **real keyframe boundary times** discovered for a
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
    /// stale boundary list.
    private struct Entry: Codable {
        var v: Int
        var size: Int64
        var duration: Double
        var target: Double
        var boundaries: [Double]
    }

    /// Current payload version; bump to invalidate all prior entries on a format
    /// change.
    static let version = 1

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

    /// Returns the cached keyframe boundary list for `key` when present and its
    /// recorded `size` + `duration` still match the current source (so a replaced
    /// file is treated as a miss). nil on any mismatch / decode failure / absence.
    func load(key: String, expectedSize: Int64, expectedDuration: Double,
              fileManager: FileManager = .default) -> [Double]? {
        let url = fileURL(for: key)
        guard let data = try? Data(contentsOf: url),
              let entry = try? JSONDecoder().decode(Entry.self, from: data),
              entry.v == Self.version,
              entry.boundaries.count >= 2 else {
            return nil
        }
        // Content guard: a re-encode under the same URL changes size/duration.
        guard entry.size == expectedSize,
              abs(entry.duration - expectedDuration) <= 1.0 else {
            return nil
        }
        // Sanity: strictly increasing, non-negative (a corrupt list must never
        // produce zero/negative-duration segments).
        var prev = -1.0
        for b in entry.boundaries {
            if !(b.isFinite) || b < 0 || b <= prev - 1e-9 { return nil }
            prev = b
        }
        return entry.boundaries
    }

    /// Persists `boundaries` for `key` (atomic write). Best-effort: any failure is
    /// swallowed (caching is a pure optimisation, never required for correctness).
    func store(key: String, size: Int64, duration: Double, target: Double,
               boundaries: [Double]) {
        guard boundaries.count >= 2 else { return }
        let entry = Entry(v: Self.version, size: size, duration: duration,
                          target: target, boundaries: boundaries)
        guard let data = try? JSONEncoder().encode(entry) else { return }
        try? data.write(to: fileURL(for: key), options: .atomic)
    }

    /// Derives the keyframe boundary list ([0, d0, d0+d1, …, total]) from a
    /// rebuilt segment-duration table. The boundaries are exactly the segment
    /// start times plus the final end, which is what the planner regroups into the
    /// identical table on the next open.
    static func boundaries(fromDurations durations: [Double]) -> [Double] {
        guard !durations.isEmpty else { return [] }
        var out: [Double] = [0]
        out.reserveCapacity(durations.count + 1)
        var acc = 0.0
        for d in durations {
            acc += d
            out.append(acc)
        }
        return out
    }
}
