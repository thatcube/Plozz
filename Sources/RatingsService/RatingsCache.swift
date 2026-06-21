import Foundation
import CoreModels

/// Thread-safe, TTL-based cache of external ratings keyed by a stable id
/// (typically the IMDb id). Keeps OMDb lookups well within the free-tier daily
/// limit by serving repeat detail views from memory (and, optionally, disk).
public actor RatingsCache {
    struct Entry: Codable {
        var ratings: [ExternalRating]
        var storedAt: Date
    }

    private var entries: [String: Entry] = [:]
    private let ttl: TimeInterval
    private let now: @Sendable () -> Date
    private let diskURL: URL?
    private var didLoadFromDisk = false

    public init(
        ttl: TimeInterval = 60 * 60 * 24 * 7,
        diskURL: URL? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.ttl = ttl
        self.diskURL = diskURL
        self.now = now
    }

    /// Returns cached ratings for `key` when present and still fresh; otherwise
    /// `nil`. Expired entries are evicted.
    public func ratings(forKey key: String) -> [ExternalRating]? {
        loadFromDiskIfNeeded()
        guard let entry = entries[key] else { return nil }
        if now().timeIntervalSince(entry.storedAt) > ttl {
            entries[key] = nil
            return nil
        }
        return entry.ratings
    }

    /// Stores `ratings` for `key`, stamping it with the current time.
    public func store(_ ratings: [ExternalRating], forKey key: String) {
        loadFromDiskIfNeeded()
        entries[key] = Entry(ratings: ratings, storedAt: now())
        persistToDisk()
    }

    // MARK: Disk persistence (best-effort)

    private func loadFromDiskIfNeeded() {
        guard !didLoadFromDisk else { return }
        didLoadFromDisk = true
        guard let diskURL, let data = try? Data(contentsOf: diskURL) else { return }
        if let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = decoded
        }
    }

    private func persistToDisk() {
        guard let diskURL else { return }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: diskURL, options: .atomic)
    }
}
