import Foundation

/// Process-wide memo of trailer resolution outcomes, keyed by library item id.
///
/// Resolving a playable trailer is expensive (YouTube extraction + a byte-reach
/// check, and sometimes a keyless search). Without a cache, every visit to a
/// detail page — and every re-focus that reloads it — pays that cost again, which
/// is the main reason the Trailer button used to take 5–10s to appear. Caching
/// the *outcome* makes a revisited page resolve its button instantly, and lets a
/// background verification done once stick for the session.
///
/// Only the keyless-trailer *decision* is cached (a working YouTube id, or "no
/// playable trailer"); local server trailers aren't cached because they're cheap
/// (no network) and provider-owned. Thread-safe so a background verification task
/// can record into it.
public final class TrailerResolutionCache: @unchecked Sendable {
    public enum Outcome: Equatable, Codable {
        /// A YouTube video id verified (or optimistically chosen) as the trailer.
        case working(String)
        /// No playable trailer exists for this item — hide the button.
        case none
    }

    /// Process-wide, **disk-persistent** cache so the Trailer button resolves
    /// instantly even on the first visit after a cold app launch.
    public static let shared = TrailerResolutionCache(directory: TrailerResolutionCache.defaultDirectory())

    private struct Entry: Codable {
        let outcome: Outcome
        let expires: Date
    }

    private let lock = NSLock()
    private var store: [String: Entry] = [:]
    private let fileURL: URL?
    private let ttl: TimeInterval
    private var loaded = false

    /// Schema-versioned filename; bump if `Outcome` coding changes.
    private static let cacheFileName = "plozz-trailer-cache-v1.json"

    /// In-memory only (no persistence) — the default for tests so instances stay
    /// isolated. Use `.shared` (or `init(directory:)`) for the persistent cache.
    public init() {
        self.fileURL = nil
        self.ttl = 60 * 60 * 24 * 30
    }

    /// Disk-persistent cache rooted at `directory`.
    public init(directory: URL?, ttl: TimeInterval = 60 * 60 * 24 * 30) {
        self.fileURL = directory?.appendingPathComponent(Self.cacheFileName)
        self.ttl = ttl
    }

    public func outcome(for itemID: String) -> Outcome? {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        guard let entry = store[itemID], entry.expires > Date() else { return nil }
        return entry.outcome
    }

    public func record(_ outcome: Outcome, for itemID: String) {
        lock.lock()
        loadIfNeeded()
        store[itemID] = Entry(outcome: outcome, expires: Date().addingTimeInterval(ttl))
        let snapshot = store
        let url = fileURL
        lock.unlock()
        persist(snapshot, to: url)
    }

    /// Drops a cached outcome (used by tests to isolate cases).
    public func reset(_ itemID: String) {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        store[itemID] = nil
    }

    /// Must be called with `lock` held.
    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) else {
            return
        }
        let now = Date()
        store = decoded.filter { $0.value.expires > now }
    }

    private func persist(_ snapshot: [String: Entry], to url: URL?) {
        guard let url, let data = try? JSONEncoder().encode(snapshot) else { return }
        // Off the critical path: a background write never blocks trailer recording.
        DispatchQueue.global(qos: .utility).async {
            try? data.write(to: url, options: .atomic)
        }
    }

    public static func defaultDirectory() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    }
}
