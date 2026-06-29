import Foundation
import CoreModels

/// In-memory per-session memo of resolved lyrics, keyed by `MusicTrack.id`.
/// Bounded so a long listening session can't grow it without limit. Evicting
/// the oldest entry when full is fine — lyrics rarely change for the same
/// track, and a miss just falls through to the disk cache or the network
/// (both also fast).
actor LyricsMemoCache {
    static let shared = LyricsMemoCache()

    private var entries: [String: Lyrics?] = [:]
    private var order: [String] = []
    private let limit = 64

    func value(for key: String) -> Lyrics?? {
        guard let entry = entries[key] else { return nil }
        return .some(entry)
    }

    func set(_ value: Lyrics?, for key: String) {
        if entries[key] == nil {
            order.append(key)
            if order.count > limit, let evicted = order.first {
                order.removeFirst()
                entries.removeValue(forKey: evicted)
            }
        }
        entries[key] = value
    }
}

/// Persistent, on-disk cache of resolved lyrics keyed by `MusicTrack.id`. Lives
/// alongside `MetadataDiskCache` in the user's Caches directory so the OS can
/// reclaim it under pressure without losing user data.
///
/// Entries are stored **without TTL** — once we've ever resolved a track, we
/// trust that answer until the cache file is evicted by the OS or until the
/// schema is bumped via `cacheFileName`. The "what if lyrics get uploaded
/// later" case is handled by `AudioPlaybackController`'s background-refresh
/// path, which periodically re-checks remembered negatives (debounced via
/// each entry's `lastChecked` timestamp). That way the user never sees a
/// "Searching for lyrics…" or "No lyrics found" flash for a song we already
/// know is instrumental, but a fresh upload for that song still surfaces on a
/// later play without any manual cache-bust.
///
/// Per-song JSON encodes to roughly 3 KB, so a heavy listening history of a
/// few thousand tracks costs only a handful of MB on disk.
public actor LyricsDiskCache {
    public static let shared = LyricsDiskCache()

    private struct Entry: Codable {
        let lyrics: Lyrics?
        /// Timestamp of the last *authoritative* resolution that produced this
        /// entry. Used to debounce the background re-check of remembered
        /// negatives so we don't hammer LRCLIB on every play of the same
        /// instrumental — see `entryAge(_:)`.
        let lastChecked: Date
    }

    private var entries: [String: Entry] = [:]
    private let fileURL: URL?
    private var loaded = false
    private var dirty = false
    private var persistTask: Task<Void, Never>?

    /// The on-disk cache filename carries a schema version, mirroring the
    /// metadata cache, so bumping the version cleanly starts fresh if the
    /// `Lyrics` shape ever evolves or we want to invalidate every cached
    /// entry in one go.
    private static let cacheFileName = "plozz-lyrics-cache-v2.json"
    private static let cacheFilePrefix = "plozz-lyrics-cache"

    public init(directory: URL? = LyricsDiskCache.defaultDirectory()) {
        self.fileURL = directory?.appendingPathComponent(Self.cacheFileName)
        if let directory { Self.removeSupersededCaches(in: directory) }
    }

    /// Returns the cached entry for `key`:
    /// - `.some(.some(lyrics))` for a positive hit (use these lyrics);
    /// - `.some(.none)` for a remembered "no lyrics" answer (skip the
    ///   network and stay silent — caller may kick a background refresh);
    /// - `nil` when there's no entry and the caller should resolve.
    public func cached(_ key: String) -> Lyrics?? {
        loadIfNeeded()
        guard let entry = entries[key] else { return nil }
        return .some(entry.lyrics)
    }

    /// Seconds since the entry for `key` was last authoritatively resolved,
    /// or `nil` if there is no entry. Callers use this to decide whether a
    /// remembered negative is old enough to deserve a background re-check.
    public func entryAge(_ key: String) -> TimeInterval? {
        loadIfNeeded()
        guard let entry = entries[key] else { return nil }
        return Date().timeIntervalSince(entry.lastChecked)
    }

    /// Stores a resolved result for `key`. No TTL — entries live until the
    /// cache file is evicted by the OS or the schema is bumped.
    public func store(_ lyrics: Lyrics?, for key: String) {
        loadIfNeeded()
        entries[key] = Entry(lyrics: lyrics, lastChecked: Date())
        dirty = true
        schedulePersist()
    }

    /// Records that we *re-checked* `key` and found nothing new, without
    /// changing the stored result. Resets the debounce clock so the next
    /// background refresh waits the full interval again.
    public func touch(_ key: String) {
        loadIfNeeded()
        guard let entry = entries[key] else { return }
        entries[key] = Entry(lyrics: entry.lyrics, lastChecked: Date())
        dirty = true
        schedulePersist()
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) else {
            return
        }
        entries = decoded
    }

    /// Debounces writes so a burst of `store` calls (e.g. an album prefetch)
    /// produces one disk write rather than one per track.
    private func schedulePersist() {
        guard dirty else { return }
        persistTask?.cancel()
        persistTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await self?.persist()
        }
    }

    private func persist() {
        guard dirty, let fileURL else { return }
        dirty = false
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Deletes older-versioned cache files so each schema bump self-cleans
    /// its predecessor rather than leaving orphans on disk.
    private static func removeSupersededCaches(in directory: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return }
        for file in files where file.lastPathComponent != cacheFileName
            && file.lastPathComponent.hasPrefix(cacheFilePrefix)
            && file.pathExtension == "json" {
            try? FileManager.default.removeItem(at: file)
        }
    }

    public static func defaultDirectory() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    }
}

/// Whether a track title carries an explicit marker that it has no sung
/// lyrics — `(Instrumental)`, `[Karaoke]`, `Backing Track`, etc. These rarely
/// have synced lyrics on LRCLIB or anywhere else, so we can skip the lookup
/// entirely and resolve to "no lyrics" immediately, saving the round-trip.
///
/// Intentionally narrow so we don't false-positive on songs that just *mention*
/// these words (e.g. "Karaoke" by Drake actually has lyrics). Untitled
/// instrumentals like a classical piece named "Palladio" aren't caught here
/// — those rely on `LyricsDiskCache` remembering the negative result instead.
func isExplicitlyInstrumental(title: String) -> Bool {
    let pattern = "(?i)[\\(\\[\\-–—]\\s*(instrumental|karaoke|backing\\s+track|score\\s+version|instrumental\\s+version|karaoke\\s+version)\\s*[\\)\\]]?\\s*$"
    return title.range(of: pattern, options: .regularExpression) != nil
}
