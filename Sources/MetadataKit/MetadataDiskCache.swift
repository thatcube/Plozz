import Foundation

/// Persistent, on-disk cache of *resolved artwork URLs* (not image bytes — those
/// stay in `URLCache`/`ArtworkImageCache`).
///
/// Why this matters for scale: a resolved URL is the expensive part (a title
/// search + an images lookup, 1–2 third-party API calls). Caching the *result*
/// across app launches means a user's library is enriched with a small one-time
/// burst of calls, then effectively zero — so even the per-IP keyless APIs are
/// touched lightly, and the optional TMDb proxy sees almost no upstream traffic.
///
/// Negative results are cached too (with a shorter TTL) so a title nothing could
/// resolve isn't re-queried on every scroll.
public actor MetadataDiskCache {
    public static let shared = MetadataDiskCache()

    struct Entry: Codable, Sendable {
        /// `nil` is a remembered negative result.
        let url: String?
        let expires: Date
    }

    protocol FileIO: Sendable {
        func removeSupersededCaches(
            in directory: URL,
            currentFileName: String,
            filePrefix: String
        )
        func read(from url: URL) -> Data?
        func write(_ data: Data, to url: URL)
    }

    protocol Coding: Sendable {
        func decode(_ data: Data) -> [String: Entry]?
        func encode(_ entries: [String: Entry]) -> Data?
    }

    private struct FoundationFileIO: FileIO {
        func removeSupersededCaches(
            in directory: URL,
            currentFileName: String,
            filePrefix: String
        ) {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil
            ) else { return }
            for file in files where file.lastPathComponent != currentFileName
                && file.lastPathComponent.hasPrefix(filePrefix)
                && file.pathExtension == "json" {
                try? FileManager.default.removeItem(at: file)
            }
        }

        func read(from url: URL) -> Data? {
            try? Data(contentsOf: url)
        }

        func write(_ data: Data, to url: URL) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private struct JSONCoding: Coding {
        func decode(_ data: Data) -> [String: Entry]? {
            try? JSONDecoder().decode([String: Entry].self, from: data)
        }

        func encode(_ entries: [String: Entry]) -> Data? {
            try? JSONEncoder().encode(entries)
        }
    }

    private var entries: [String: Entry] = [:]
    private let directory: URL?
    private let fileURL: URL?
    private let positiveTTL: TimeInterval
    private let negativeTTL: TimeInterval
    private let maxBytes: Int
    private let io: MetadataCacheFileIO
    private var loaded = false
    /// The single in-flight initial load. Concurrent `cached`/`store` callers all
    /// await this one task and its result is applied to the actor exactly once.
    private var loadTask: Task<MetadataCacheFileIO.LoadResult, Never>?
    /// Monotonically increasing snapshot revision. Every mutation bumps it; the
    /// I/O executor uses it to keep writes ordered and to let the actor reconcile
    /// budget evictions only when its state has not moved on.
    private var revision = 0

    /// The on-disk cache filename carries a schema version. **Bump this whenever
    /// the provider set or chain order changes**: resolved URLs (including
    /// remembered *negatives*, which have only a 3-day TTL) are keyed without any
    /// provider fingerprint, so a device that cached `nil` for a hero/logo before a
    /// new provider existed would otherwise keep showing nothing until the entry
    /// expired. A version bump starts a fresh file, giving the new providers a
    /// clean shot immediately on every device. (v2: added keyless Wikidata +
    /// Wikipedia artwork providers. v3: added the bundled TheTVDB backdrop + poster
    /// tiers to the hero/poster chains — without this bump, negatives cached before
    /// TheTVDB existed would suppress it for up to the 3-day negative TTL.)
    private static let cacheFileName = "plozz-metadata-cache-v3.json"
    /// Matches every versioned cache file (current and superseded) so a bump can
    /// delete its predecessors instead of orphaning them on disk.
    private static let cacheFilePrefix = "plozz-metadata-cache"

    public init(
        directory: URL? = MetadataDiskCache.defaultDirectory(),
        positiveTTL: TimeInterval = 60 * 60 * 24 * 30,
        negativeTTL: TimeInterval = 60 * 60 * 24 * 3,
        maxBytes: Int = 16 * 1024 * 1024
    ) {
        self.directory = directory
        self.fileURL = directory?.appendingPathComponent(Self.cacheFileName)
        self.positiveTTL = positiveTTL
        self.negativeTTL = negativeTTL
        self.maxBytes = max(0, maxBytes)
        self.io = MetadataCacheFileIO(fileIO: FoundationFileIO(), coding: JSONCoding())
    }

    init(
        directory: URL?,
        positiveTTL: TimeInterval = 60 * 60 * 24 * 30,
        negativeTTL: TimeInterval = 60 * 60 * 24 * 3,
        maxBytes: Int = 16 * 1024 * 1024,
        fileIO: any FileIO,
        coding: any Coding
    ) {
        self.directory = directory
        self.fileURL = directory?.appendingPathComponent(Self.cacheFileName)
        self.positiveTTL = positiveTTL
        self.negativeTTL = negativeTTL
        self.maxBytes = max(0, maxBytes)
        self.io = MetadataCacheFileIO(fileIO: fileIO, coding: coding)
    }

    /// Looks up a cached result for `key`.
    /// - Returns: `.some(url)` for a fresh positive hit, `.some(nil)` for a fresh
    ///   remembered negative, and `nil` when there is no fresh entry (caller should
    ///   resolve from the network).
    public func cached(_ key: String) async -> URL?? {
        await loadIfNeeded()
        guard let entry = entries[key], entry.expires > Date() else { return nil }
        guard let raw = entry.url else { return .some(nil) }
        return .some(URL(string: raw))
    }

    /// Stores a resolved result (positive or negative) for `key`.
    public func store(_ url: URL?, for key: String) async {
        await loadIfNeeded()
        let ttl = url == nil ? negativeTTL : positiveTTL
        entries[key] = Entry(url: url?.absoluteString, expires: Date().addingTimeInterval(ttl))
        revision += 1
        await persist()
    }

    /// Performs (or joins) the one-time load off the actor executor. Cleanup and
    /// the current-file read happen on the I/O queue; the decoded result is
    /// applied to actor state exactly once even under concurrent callers.
    private func loadIfNeeded() async {
        if loaded { return }
        let task: Task<MetadataCacheFileIO.LoadResult, Never>
        if let existing = loadTask {
            task = existing
        } else {
            let io = self.io
            let directory = self.directory
            let fileURL = self.fileURL
            let maxBytes = self.maxBytes
            let name = Self.cacheFileName
            let prefix = Self.cacheFilePrefix
            task = Task {
                await io.firstLoad(
                    directory: directory,
                    fileURL: fileURL,
                    currentFileName: name,
                    filePrefix: prefix,
                    maxBytes: maxBytes
                )
            }
            loadTask = task
        }
        let result = await task.value
        guard !loaded else { return }
        loaded = true
        loadTask = nil
        entries = result.entries
        // An oversized legacy file is pruned once, immediately after load.
        if result.wasOversized {
            revision += 1
            await persist()
        }
    }

    /// Submits the current snapshot to the serial I/O executor and reconciles any
    /// budget eviction back into actor state — but only if no newer mutation has
    /// happened since (otherwise the newer snapshot's own write owns pruning).
    private func persist() async {
        guard let fileURL else { return }
        let rev = revision
        let snapshot = entries
        let result = await io.write(
            snapshot: snapshot,
            revision: rev,
            fileURL: fileURL,
            maxBytes: maxBytes
        )
        guard result.didWrite, !result.evicted.isEmpty, revision == rev else { return }
        for key in result.evicted { entries[key] = nil }
    }

    public static func defaultDirectory() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    }
}
