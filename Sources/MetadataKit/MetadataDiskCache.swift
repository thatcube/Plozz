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
    private var loaded = false
    private var dirty = false

    public init(
        directory: URL? = MetadataDiskCache.defaultDirectory(),
        positiveTTL: TimeInterval = 60 * 60 * 24 * 30,
        negativeTTL: TimeInterval = 60 * 60 * 24 * 3
    ) {
        self.fileURL = directory?.appendingPathComponent("plozz-metadata-cache.json")
        self.positiveTTL = positiveTTL
        self.negativeTTL = negativeTTL
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
    }

    private func persist() {
        guard dirty, let fileURL else { return }
        dirty = false
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    public static func defaultDirectory() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    }
}
