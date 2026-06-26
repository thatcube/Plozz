import Foundation

/// Persistent, on-disk cache of the **combined, de-duplicated** Music landing
/// page. Lets a revisited (or relaunched) Music tab paint its rails instantly
/// from the last-known merged snapshot while the live fetch refreshes it in the
/// background (stale-while-revalidate), exactly like `DetailSnapshotCache` does
/// for detail pages.
///
/// The snapshot stores the **already-merged** unified-library content, and the
/// cache key incorporates the **visible music-library set**, so flipping a
/// library toggle invalidates the stale snapshot instead of painting hidden
/// content.
///
/// Concurrency: holds no mutable state — every method only reads the immutable
/// configuration and touches the filesystem (its own synchronization domain via
/// atomic writes). A plain `Sendable` class, not an `actor`, so independent
/// reads/writes never serialize on a single executor; blocking file I/O runs on
/// a concurrent background queue and the LRU prune runs off the write path.
public final class MusicLandingCache: Sendable {
    public static let shared = MusicLandingCache()

    /// A no-op cache (no directory ⇒ never reads or writes). The default for the
    /// view model so tests and previews stay isolated and never touch disk.
    public static let ephemeral = MusicLandingCache(directory: nil)

    /// A point-in-time snapshot of the merged landing content.
    public struct Snapshot: Codable, Sendable, Equatable {
        public var recentlyPlayed: [RecentlyPlayedItem]
        public var albums: [MusicAlbum]
        public var artists: [MusicArtist]
        public var playlists: [MusicPlaylist]
        public var savedAt: Date

        public init(
            recentlyPlayed: [RecentlyPlayedItem] = [],
            albums: [MusicAlbum] = [],
            artists: [MusicArtist] = [],
            playlists: [MusicPlaylist] = [],
            savedAt: Date = Date()
        ) {
            self.recentlyPlayed = recentlyPlayed
            self.albums = albums
            self.artists = artists
            self.playlists = playlists
            self.savedAt = savedAt
        }

        public var isEmpty: Bool {
            recentlyPlayed.isEmpty && albums.isEmpty && artists.isEmpty && playlists.isEmpty
        }
    }

    /// Schema-versioned directory. **Bump when the music models' coding changes**
    /// so a device with snapshots from an older shape starts fresh (decode
    /// failures are treated as a miss; a bump also reclaims orphaned files).
    private static let schemaDirName = "plozz-music-landing-cache-v2"
    private static let schemaDirPrefix = "plozz-music-landing-cache"

    private let directory: URL?
    private let maxEntries: Int
    private let maxAge: TimeInterval

    private let ioQueue = DispatchQueue(
        label: "com.thatcube.Plozz.MusicLandingCache.io",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private let pruneQueue = DispatchQueue(
        label: "com.thatcube.Plozz.MusicLandingCache.prune",
        qos: .background
    )

    public init(
        directory: URL? = MusicLandingCache.defaultDirectory(),
        maxEntries: Int = 32,
        maxAge: TimeInterval = 60 * 60 * 24 * 14
    ) {
        self.directory = directory.map { $0.appendingPathComponent(Self.schemaDirName, isDirectory: true) }
        self.maxEntries = maxEntries
        self.maxAge = maxAge
        if let directory { Self.removeSupersededCaches(in: directory) }
    }

    /// A stable cache key for the unified landing content scoped to a specific
    /// **visible** music-library set, so toggling a library yields a different key
    /// (and thus invalidates the stale combined snapshot). Order-independent.
    public static func key(visibleLibraryIDs: [String: [String]]) -> String {
        let parts = visibleLibraryIDs
            .flatMap { account, libs in libs.map { "\(account):\($0)" } }
            .sorted()
        return parts.isEmpty ? "all" : parts.joined(separator: "|")
    }

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
        let safe = Data(key.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        return directory.appendingPathComponent(safe).appendingPathExtension("json")
    }

    private func pruneIfNeeded() {
        guard let directory else { return }
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys
        ), files.count > maxEntries else { return }
        let sorted = files.sorted { lhs, rhs in
            let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return l < r
        }
        for file in sorted.prefix(files.count - maxEntries) {
            try? FileManager.default.removeItem(at: file)
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
