import CoreModels
import Foundation

/// One cached answer to "what is related to this title".
public struct RelatedTitlesRecord: Codable, Sendable, Equatable {
    /// Bump when the shape or the provider chain changes meaningfully: a record
    /// written earlier still satisfies its TTL, so it would be served — stale —
    /// until that expired days later.
    ///
    /// v2: every provider is now merged rather than the chain stopping at the first
    /// to fill the row. A v1 record for an anime holds AniList-only results, which
    /// no Shoko/Jellyfin library can verify by id, and would have kept that row
    /// empty for a week after the fix.
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var seedKey: String
    public var titles: [RelatedTitle]
    public var refreshedAt: Date

    public init(
        seedKey: String,
        titles: [RelatedTitle],
        refreshedAt: Date,
        schemaVersion: Int = RelatedTitlesRecord.currentSchemaVersion
    ) {
        self.seedKey = seedKey
        self.titles = titles
        self.refreshedAt = refreshedAt
        self.schemaVersion = schemaVersion
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, seedKey, titles, refreshedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seedKey = try c.decode(String.self, forKey: .seedKey)
        titles = (try? c.decode([RelatedTitle].self, forKey: .titles)) ?? []
        refreshedAt = (try? c.decode(Date.self, forKey: .refreshedAt)) ?? .distantPast
        schemaVersion = (try? c.decode(Int.self, forKey: .schemaVersion)) ?? 0
    }

    /// Related titles barely move, so this is cached hard — a week for an answer,
    /// a day for an empty one (a title too obscure today may be covered later).
    ///
    /// An older schema is always due, so a chain change takes effect on the next
    /// open rather than a week later.
    public func isRefreshDue(now: Date) -> Bool {
        guard schemaVersion >= Self.currentSchemaVersion else { return true }
        let ttl: TimeInterval = titles.isEmpty ? 86_400 : 604_800
        return now.timeIntervalSince(refreshedAt) >= ttl
    }
}

/// Disk-backed cache of related titles, one record per seed.
///
/// Mirrors ``SeriesScheduleStore``: a small in-memory map persisted atomically, so
/// a detail page can render its Related row with **zero network** on a revisit.
public actor RelatedTitlesStore {
    public static let shared = RelatedTitlesStore()

    private var records: [String: RelatedTitlesRecord] = [:]
    private let directory: URL?
    private let fileURL: URL?
    private let maxRecords: Int
    private var loaded = false

    private static let fileName = "plozz-related-titles-v1.json"
    private static let filePrefix = "plozz-related-titles"

    public init(
        directory: URL? = RelatedTitlesStore.defaultDirectory(),
        maxRecords: Int = 2000
    ) {
        self.directory = directory
        self.fileURL = directory?.appendingPathComponent(Self.fileName)
        self.maxRecords = max(1, maxRecords)
    }

    public func record(for key: String) -> RelatedTitlesRecord? {
        loadIfNeeded()
        return records[key]
    }

    public func store(_ record: RelatedTitlesRecord) {
        loadIfNeeded()
        records[record.seedKey] = record
        evictIfNeeded()
        persist()
    }

    public func clear() {
        loadIfNeeded()
        records = [:]
        persist()
    }

    private func evictIfNeeded() {
        guard records.count > maxRecords else { return }
        let sorted = records.values.sorted { $0.refreshedAt < $1.refreshedAt }
        for record in sorted.prefix(records.count - maxRecords) {
            records[record.seedKey] = nil
        }
    }

    private func loadIfNeeded() {
        if loaded { return }
        loaded = true
        guard let directory, let fileURL else { return }
        // A version bump orphans its predecessors; sweep them so they don't sit in
        // Caches forever.
        if let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for file in files where file.lastPathComponent != Self.fileName
                && file.lastPathComponent.hasPrefix(Self.filePrefix)
                && file.pathExtension == "json" {
                try? FileManager.default.removeItem(at: file)
            }
        }
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: RelatedTitlesRecord].self, from: data)
        else { return }
        records = decoded
    }

    private func persist() {
        guard let fileURL else { return }
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    public static func defaultDirectory() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    }
}
