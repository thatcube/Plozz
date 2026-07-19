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
    ///
    /// v3 also introduced per-content-identity **scoping**: snapshots live under
    /// `plozz-detail-cache-v3/<scope-digest>/…` so one profile / account / Plex
    /// Home-user identity can never read another's cached detail (which would leak
    /// the wrong sources or watch state). A nil scope maps to a single shared
    /// `default` subdirectory, preserving the unscoped behaviour for callers (tests,
    /// previews) that don't provide an identity.
    ///
    /// v4: `MediaSourceRef` gained a `kind` field and sources are now cross-kind
    /// sanitized — bumping evicts snapshots that froze a stale episode↔movie twin
    /// in `sources` from a pre-fix build.
    private static let schemaDirName = "plozz-detail-cache-v4"
    private static let schemaDirPrefix = "plozz-detail-cache"
    private static let defaultScopeComponent = "default"

    private let directory: URL?
    private let maxEntries: Int
    private let maxBytes: Int
    private let maxAge: TimeInterval
    typealias DirectoryContents = @Sendable (URL, [URLResourceKey]) -> [URL]?
    private let directoryContents: DirectoryContents

    /// Resolves the on-disk directory for a base caches directory and an optional
    /// scope digest: `<base>/plozz-detail-cache-v3/<scope-or-default>`.
    private static func resolvedDirectory(base: URL?, scope: String?) -> URL? {
        base.map {
            $0.appendingPathComponent(schemaDirName, isDirectory: true)
                .appendingPathComponent(scope ?? defaultScopeComponent, isDirectory: true)
        }
    }

    /// Concurrent queue for snapshot reads/writes: independent titles run in
    /// parallel, so a slow encode/write for one never blocks a read for another.
    /// `.userInitiated` because a snapshot read backs a user-visible revisit paint;
    /// writes are coalesced by the caller so this queue stays light.
    private let ioQueue = DispatchQueue(
        label: "com.thatcube.Plozz.DetailSnapshotCache.io",
        qos: .userInitiated,
        attributes: .concurrent
    )
    /// Owns the off-write-path LRU prune: a successful write asks it to schedule a
    /// prune, and a burst of writes coalesces into a single directory scan. The
    /// prune logic itself depends only on this cache's immutable configuration
    /// (`directory`/`maxEntries`/`maxBytes`/`directoryContents`), so it is passed to
    /// the coordinator as a self-free closure — no retain cycle, no locking.
    private let pruneCoordinator: DetailSnapshotPruneCoordinator

    public init(
        directory: URL? = DetailSnapshotCache.defaultDirectory(),
        scope: String? = nil,
        maxEntries: Int = 800,
        maxBytes: Int = 48 * 1024 * 1024,
        maxAge: TimeInterval = 60 * 60 * 24 * 30
    ) {
        let resolved = Self.resolvedDirectory(base: directory, scope: scope)
        let contents: DirectoryContents = { directory, keys in
            try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: keys
            )
        }
        self.directory = resolved
        self.maxEntries = maxEntries
        self.maxBytes = max(0, maxBytes)
        self.maxAge = maxAge
        self.directoryContents = contents
        self.pruneCoordinator = Self.makeCoordinator(
            directory: resolved,
            maxEntries: maxEntries,
            maxBytes: max(0, maxBytes),
            directoryContents: contents,
            debounce: .milliseconds(500)
        )
        if let directory { Self.removeSupersededCaches(in: directory) }
        if resolved != nil { pruneCoordinator.schedule() }
    }

    init(
        directory: URL?,
        scope: String? = nil,
        maxEntries: Int = 800,
        maxBytes: Int = 48 * 1024 * 1024,
        maxAge: TimeInterval = 60 * 60 * 24 * 30,
        debounce: DispatchTimeInterval = .milliseconds(500),
        directoryContents: @escaping DirectoryContents
    ) {
        let resolved = Self.resolvedDirectory(base: directory, scope: scope)
        self.directory = resolved
        self.maxEntries = maxEntries
        self.maxBytes = max(0, maxBytes)
        self.maxAge = maxAge
        self.directoryContents = directoryContents
        self.pruneCoordinator = Self.makeCoordinator(
            directory: resolved,
            maxEntries: maxEntries,
            maxBytes: max(0, maxBytes),
            directoryContents: directoryContents,
            debounce: debounce
        )
        if let directory { Self.removeSupersededCaches(in: directory) }
        if resolved != nil { pruneCoordinator.schedule() }
    }

    /// Builds a prune coordinator whose scan closure captures only this cache's
    /// immutable configuration, so the coordinator never retains the cache.
    private static func makeCoordinator(
        directory: URL?,
        maxEntries: Int,
        maxBytes: Int,
        directoryContents: @escaping DirectoryContents,
        debounce: DispatchTimeInterval
    ) -> DetailSnapshotPruneCoordinator {
        DetailSnapshotPruneCoordinator(debounce: debounce) {
            Self.pruneIfNeeded(
                directory: directory,
                maxEntries: maxEntries,
                maxBytes: maxBytes,
                directoryContents: directoryContents
            )
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
        pruneCoordinator.schedule()
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
    /// Test-only: awaits any LRU prune the ``DetailSnapshotPruneCoordinator`` has
    /// coalesced from prior ``store(_:for:)`` calls.
    ///
    /// `store` deliberately asks the coordinator to *schedule* (debounce) a prune
    /// off the write path, so the scan is asynchronous relative to `store`'s
    /// completion and a test that inspects the directory immediately after storing
    /// races the pending prune. Delegating to the coordinator's deterministic settle
    /// cancels the outstanding debounce timer, runs the coalesced prune now, and
    /// resumes — so by the time this returns the directory is settled. Compiled only
    /// into test/debug builds; it changes no production behaviour.
    func awaitPendingPrune() async {
        await pruneCoordinator.settleForTesting()
    }
#endif

    private static func pruneIfNeeded(
        directory: URL?,
        maxEntries: Int,
        maxBytes: Int,
        directoryContents: DirectoryContents
    ) {
        guard let directory else { return }
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let files = directoryContents(directory, keys) else { return }
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
