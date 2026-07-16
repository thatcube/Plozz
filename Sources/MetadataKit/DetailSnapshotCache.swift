import Foundation
import CoreModels

/// Persistent, on-disk cache of a title's **resolved detail** — the full item, its
/// children (seasons/folder contents), any already-loaded episodes-per-season, and
/// the discovered cross-server sources.
///
/// Why this exists: opening a detail page used to re-fetch *everything* from the
/// server every single time — the item, its seasons and episodes, and a live
/// cross-server search to find which servers host the title. So a show you'd
/// already opened ten times still showed a spinner while all of that was fetched
/// again. This cache lets a revisited title paint its hero, season/episode lists
/// and server picker **instantly** from the last-known snapshot, while the live
/// fetch refreshes it in the background (stale-while-revalidate). Image *bytes*
/// already persist in `URLCache`/`ArtworkImageCache`, so with the metadata cached
/// too a revisit is effectively free.
///
/// One small JSON file per title keeps writes cheap and atomic and lets the store
/// self-bound by pruning the least-recently-used files once a cap is reached.
///
/// Concurrency: this type holds **no mutable state** — every method only reads the
/// immutable configuration (`directory`/`maxEntries`/`maxAge`) and touches the
/// filesystem, which is already its own synchronization domain (atomic writes).
/// It is therefore a plain `Sendable` class, NOT an `actor`: making it an actor
/// would force every concurrent detail load (and every background `store`) to
/// serialize on a single executor, so one title's slow encode/prune could starve
/// another title's snapshot read for many seconds. Instead, the blocking file I/O
/// runs on a concurrent background queue so independent titles never block each
/// other, and the periodic LRU prune runs off the write path entirely.
public final class DetailSnapshotCache: Sendable {
    public static let shared = DetailSnapshotCache()

    /// A no-op cache (no directory ⇒ never reads or writes). The default for the
    /// view model so tests and previews stay isolated and never touch disk;
    /// production explicitly opts into ``shared``.
    public static let ephemeral = DetailSnapshotCache(directory: nil)

    /// A point-in-time snapshot of a resolved detail page.
    public struct Snapshot: Codable, Sendable {
        public var item: MediaItem
        public var children: [MediaItem]
        public var seasonEpisodes: [String: [MediaItem]]
        public var sources: [MediaSourceRef]
        public var savedAt: Date

        public init(
            item: MediaItem,
            children: [MediaItem],
            seasonEpisodes: [String: [MediaItem]] = [:],
            sources: [MediaSourceRef] = [],
            savedAt: Date = Date()
        ) {
            self.item = item
            self.children = children
            self.seasonEpisodes = seasonEpisodes
            self.sources = sources
            self.savedAt = savedAt
        }
    }

    /// Schema-versioned directory. **Bump when `MediaItem`/`MediaSourceRef` coding
    /// changes** so a device with snapshots from an older shape starts fresh
    /// instead of failing to decode (decode failures are treated as a cache miss,
    /// so a stale schema just silently falls back to the network — but a bump also
    /// reclaims the orphaned files).
    private static let schemaDirName = "plozz-detail-cache-v2"
    private static let schemaDirPrefix = "plozz-detail-cache"

    private let directory: URL?
    private let maxEntries: Int
    private let maxBytes: Int
    private let maxAge: TimeInterval

    /// Concurrent queue for snapshot reads/writes: independent titles run in
    /// parallel, so a slow encode/write for one never blocks a read for another.
    /// `.userInitiated` because a snapshot read backs a user-visible revisit paint;
    /// writes are coalesced by the caller so this queue stays light.
    private let ioQueue = DispatchQueue(
        label: "com.thatcube.Plozz.DetailSnapshotCache.io",
        qos: .userInitiated,
        attributes: .concurrent
    )
    /// Serial low-priority queue for the LRU prune so directory scans stay off the
    /// critical write path (and never pile up concurrently).
    private let pruneQueue = DispatchQueue(
        label: "com.thatcube.Plozz.DetailSnapshotCache.prune",
        qos: .background
    )

    public init(
        directory: URL? = DetailSnapshotCache.defaultDirectory(),
        maxEntries: Int = 800,
        maxBytes: Int = 48 * 1024 * 1024,
        maxAge: TimeInterval = 60 * 60 * 24 * 30
    ) {
        self.directory = directory.map { $0.appendingPathComponent(Self.schemaDirName, isDirectory: true) }
        self.maxEntries = maxEntries
        self.maxBytes = max(0, maxBytes)
        self.maxAge = maxAge
        if let directory { Self.removeSupersededCaches(in: directory) }
        if self.directory != nil {
            pruneQueue.async { self.pruneIfNeeded() }
        }
    }

    /// The cached snapshot for `key`, or `nil` when there is no fresh entry (the
    /// caller should fetch from the network). A hit "touches" the file so the LRU
    /// prune keeps frequently-opened titles. Runs off the calling actor on the
    /// concurrent I/O queue.
    public func snapshot(for key: String) async -> Snapshot? {
        await withCheckedContinuation { continuation in
            ioQueue.async {
                continuation.resume(returning: self.readSnapshot(for: key))
            }
        }
    }

    private func readSnapshot(for key: String) -> Snapshot? {
        guard let url = fileURL(for: key),
              let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else {
            return nil
        }
        guard Date().timeIntervalSince(snapshot.savedAt) < maxAge else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return snapshot
    }

    /// Persists `snapshot` for `key`, then prunes the least-recently-used files if
    /// the store has grown past `maxEntries`. The write runs on the concurrent I/O
    /// queue; the prune is dispatched onto a separate background queue so it never
    /// blocks the write (or any concurrent read).
    public func store(_ snapshot: Snapshot, for key: String) async {
        await withCheckedContinuation { continuation in
            ioQueue.async {
                self.writeSnapshot(snapshot, for: key)
                continuation.resume()
            }
        }
    }

    private func writeSnapshot(_ snapshot: Snapshot, for key: String) {
        guard let directory, let url = fileURL(for: key),
              let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard (try? data.write(to: url, options: .atomic)) != nil else { return }
        pruneQueue.async { self.pruneIfNeeded() }
    }

    /// Drops the snapshot for `key` (used by tests / explicit invalidation).
    public func remove(for key: String) async {
        await withCheckedContinuation { continuation in
            ioQueue.async {
                if let url = self.fileURL(for: key) {
                    try? FileManager.default.removeItem(at: url)
                }
                continuation.resume()
            }
        }
    }

    private func fileURL(for key: String) -> URL? {
        guard let directory else { return nil }
        // A filesystem-safe, collision-free filename from the (arbitrary) key.
        let safe = Data(key.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        return directory.appendingPathComponent(safe).appendingPathExtension("json")
    }

#if DEBUG
    /// Test-only: awaits any LRU prune already scheduled by ``store(_:for:)``.
    ///
    /// `store` deliberately dispatches ``pruneIfNeeded()`` onto the serial
    /// ``pruneQueue`` *off* the write path (so a slow directory scan never blocks
    /// a write or a concurrent read — see the type header). That makes the prune
    /// asynchronous relative to `store`'s completion, so a test that inspects the
    /// cache directory immediately after storing races the prune and can observe
    /// the pre-prune file count.
    ///
    /// This is the deterministic join point. By the time an `await store(…)` has
    /// returned, its ``writeSnapshot(_:for:)`` has *already* enqueued that write's
    /// prune onto ``pruneQueue`` (the enqueue happens before the write's
    /// continuation resumes). Because ``pruneQueue`` is **serial**, a sentinel
    /// enqueued here runs strictly after every prune queued by prior completed
    /// stores — so awaiting it observes the settled, post-prune directory. Compiled
    /// only into test/debug builds; it changes no production behaviour.
    func awaitPendingPrune() async {
        await withCheckedContinuation { continuation in
            pruneQueue.async { continuation.resume() }
        }
    }
#endif

    private func pruneIfNeeded() {
        guard let directory else { return }
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys
        ) else { return }
        var entries = files.map { url -> (url: URL, date: Date, bytes: Int) in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return (
                url,
                values?.contentModificationDate ?? .distantPast,
                values?.fileSize ?? 0
            )
        }
        var totalBytes = entries.reduce(0) { $0 + $1.bytes }
        guard entries.count > maxEntries || totalBytes > maxBytes else { return }
        entries.sort { $0.date < $1.date }
        var remainingCount = entries.count
        for entry in entries where remainingCount > maxEntries || totalBytes > maxBytes {
            try? FileManager.default.removeItem(at: entry.url)
            remainingCount -= 1
            totalBytes = max(0, totalBytes - entry.bytes)
        }
    }

    private static func removeSupersededCaches(in parent: URL) {
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: parent, includingPropertiesForKeys: nil
        ) else { return }
        for dir in dirs where dir.lastPathComponent != schemaDirName
            && dir.lastPathComponent.hasPrefix(schemaDirPrefix) {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    public static func defaultDirectory() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    }
}
