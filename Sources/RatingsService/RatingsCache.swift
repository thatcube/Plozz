import Foundation
import CoreModels

/// Thread-safe, TTL-based cache of external ratings keyed by a stable id
/// (typically the IMDb id). Keeps OMDb lookups well within the free-tier daily
/// limit by serving repeat detail views from memory (and, optionally, disk).
public actor RatingsCache {
    /// Bump when the *fetch/validation logic* changes in a way that can make a
    /// previously-cached result wrong (not just the data shape). Entries stamped
    /// with an older version are treated as stale on read, so an app update that
    /// tightens matching (e.g. the AniList year-corroboration that rejects an
    /// anime score mis-stamped onto a live-action film) re-fetches instead of
    /// serving the poisoned cache for up to the TTL.
    static let currentSchemaVersion = 1

    struct Entry: Codable {
        var ratings: [ExternalRating]
        var storedAt: Date
        /// Absent on entries written before versioning — treated as stale.
        var version: Int?
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
    /// `nil`. Expired **or stale-schema** entries are evicted.
    public func ratings(forKey key: String) -> [ExternalRating]? {
        loadFromDiskIfNeeded()
        guard let entry = entries[key] else { return nil }
        if entry.version != Self.currentSchemaVersion {
            entries[key] = nil
            return nil
        }
        if now().timeIntervalSince(entry.storedAt) > ttl {
            entries[key] = nil
            return nil
        }
        return entry.ratings
    }

    /// Stores `ratings` for `key`, stamping it with the current time and schema
    /// version.
    public func store(_ ratings: [ExternalRating], forKey key: String) {
        loadFromDiskIfNeeded()
        entries[key] = Entry(
            ratings: ratings,
            storedAt: now(),
            version: Self.currentSchemaVersion
        )
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
