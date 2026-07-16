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

    private struct Entry: Codable {
        /// `nil` is a remembered negative result.
        let url: String?
        let expires: Date
    }

    private var entries: [String: Entry] = [:]
    private let fileURL: URL?
    private let positiveTTL: TimeInterval
    private let negativeTTL: TimeInterval
    private let maxBytes: Int
    private var loaded = false
    private var dirty = false

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
        self.fileURL = directory?.appendingPathComponent(Self.cacheFileName)
        self.positiveTTL = positiveTTL
        self.negativeTTL = negativeTTL
        self.maxBytes = max(0, maxBytes)
        if let directory { Self.removeSupersededCaches(in: directory) }
    }

    /// Deletes any older-versioned cache files so each schema bump self-cleans its
    /// predecessor rather than leaving small orphans for the OS to reclaim.
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

    /// Looks up a cached result for `key`.
    /// - Returns: `.some(url)` for a fresh positive hit, `.some(nil)` for a fresh
    ///   remembered negative, and `nil` when there is no fresh entry (caller should
    ///   resolve from the network).
    public func cached(_ key: String) -> URL?? {
        loadIfNeeded()
        guard let entry = entries[key], entry.expires > Date() else { return nil }
        guard let raw = entry.url else { return .some(nil) }
        return .some(URL(string: raw))
    }

    /// Stores a resolved result (positive or negative) for `key`.
    public func store(_ url: URL?, for key: String) {
        loadIfNeeded()
        let ttl = url == nil ? negativeTTL : positiveTTL
        entries[key] = Entry(url: url?.absoluteString, expires: Date().addingTimeInterval(ttl))
        dirty = true
        persist()
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) else {
            return
        }
        // Drop already-expired entries on load so the file doesn't grow unbounded.
        let now = Date()
        entries = decoded.filter { $0.value.expires > now }
        if data.count > maxBytes {
            dirty = true
            persist()
        }
    }

    private func persist() {
        guard dirty, let fileURL else { return }
        dirty = false
        guard let data = encodedDataPruningToBudget() else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func encodedDataPruningToBudget() -> Data? {
        let encoder = JSONEncoder()
        guard var data = try? encoder.encode(entries) else { return nil }
        guard data.count > maxBytes else { return data }
        let oldestFirst = entries.sorted { $0.value.expires < $1.value.expires }
        var index = 0
        while data.count > maxBytes, index < oldestFirst.count {
            let batchEnd = min(
                oldestFirst.count,
                index + max(1, oldestFirst.count / 10)
            )
            for entry in oldestFirst[index..<batchEnd] {
                entries[entry.key] = nil
            }
            index = batchEnd
            guard let encoded = try? encoder.encode(entries) else { return nil }
            data = encoded
        }
        return data
    }

    public static func defaultDirectory() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    }
}
