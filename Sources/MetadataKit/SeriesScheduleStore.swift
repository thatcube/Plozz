import Foundation
import CoreModels

/// One persisted schedule record per series: the latest known upcoming episode (or a
/// remembered "no upcoming" negative), plus when it was resolved and when the passive
/// resolver should refresh it.
///
/// Kept deliberately small (one row per series) so the whole map is cheap to keep in
/// memory and serialize, and so Home can render from it with **zero network**.
public struct SeriesScheduleRecord: Codable, Sendable, Equatable {
    /// The shape this record was written with. **Bump when a new field is added**
    /// that existing records can't supply: a record written before the field exists
    /// still satisfies its TTL, so it would otherwise be served — missing the new
    /// data — until the TTL expired hours later. `isRefreshDue` treats anything
    /// below `currentSchemaVersion` as due immediately.
    ///
    /// v2 added `upcomingEpisodes` + `cadence`. v3 re-resolves them: v2 records were
    /// written while TheTVDB's own enrichment cache still held pre-list responses,
    /// so they carry the new fields but empty. v4 picks up TVmaze's listing, which
    /// covers series with no known TheTVDB id.
    public static let currentSchemaVersion = 5

    /// The schema version this record was written with; `1` for records persisted
    /// before the field existed.
    public var schemaVersion: Int

    /// The stable per-series cache key (``MetadataQuery/enrichmentCacheKey`` of the
    /// series query) this record was stored under.
    public var seriesKey: String
    /// The next known episode, or `nil` for a remembered "no upcoming episode".
    ///
    /// Always the first element of ``upcomingEpisodes`` when that is non-empty, so
    /// existing single-episode readers keep working unchanged.
    public var upcomingEpisode: UpcomingEpisode?
    /// Every known future episode, oldest first — so a series with nine unreleased
    /// episodes can list all nine rather than only the next.
    ///
    /// Empty for a provider that reports only a single next episode (AniList,
    /// TVmaze), and for records persisted before this field existed. Readers that
    /// want "just the next one" should keep using ``upcomingEpisode``.
    public var upcomingEpisodes: [UpcomingEpisode]
    /// The series' stated release cadence, when a provider reports one. Never
    /// inferred from air-date spacing — see ``AirCadence``.
    public var cadence: AirCadence?
    /// Whether the series is known to have ended (drives the longer "no upcoming"
    /// TTL). Best-effort; defaults to `false`.
    public var seriesEnded: Bool
    /// When this record was last resolved from a provider.
    public var refreshedAt: Date
    /// When the passive resolver should next refresh this record. Does **not** hide
    /// the record from readers — Home always renders the stored value; this only tells
    /// the resolver when a network refresh is due.
    public var refreshDueAt: Date

    public init(
        seriesKey: String,
        upcomingEpisode: UpcomingEpisode?,
        upcomingEpisodes: [UpcomingEpisode] = [],
        cadence: AirCadence? = nil,
        seriesEnded: Bool = false,
        refreshedAt: Date,
        refreshDueAt: Date,
        schemaVersion: Int = SeriesScheduleRecord.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.seriesKey = seriesKey
        self.upcomingEpisode = upcomingEpisode
        self.upcomingEpisodes = upcomingEpisodes
        self.cadence = cadence
        self.seriesEnded = seriesEnded
        self.refreshedAt = refreshedAt
        self.refreshDueAt = refreshDueAt
    }

    /// Decoded explicitly so records written before the list/cadence existed still
    /// load — they simply carry no list and no cadence until their next refresh.
    /// Swift's synthesized decoder would reject them for the missing keys, and a
    /// store-file version bump would needlessly discard every good record.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Absent means "written before versioning existed" — i.e. version 1.
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        seriesKey = try c.decode(String.self, forKey: .seriesKey)
        upcomingEpisode = try c.decodeIfPresent(UpcomingEpisode.self, forKey: .upcomingEpisode)
        upcomingEpisodes = try c.decodeIfPresent([UpcomingEpisode].self, forKey: .upcomingEpisodes) ?? []
        cadence = try c.decodeIfPresent(AirCadence.self, forKey: .cadence)
        seriesEnded = try c.decodeIfPresent(Bool.self, forKey: .seriesEnded) ?? false
        refreshedAt = try c.decode(Date.self, forKey: .refreshedAt)
        refreshDueAt = try c.decode(Date.self, forKey: .refreshDueAt)
    }

    /// Whether the passive resolver should refresh this record from the network.
    ///
    /// A record written under an older schema is always due: it satisfies its TTL but
    /// cannot supply fields that didn't exist when it was written, so serving it
    /// would leave the new data missing for hours.
    public func isRefreshDue(now: Date = Date()) -> Bool {
        schemaVersion < Self.currentSchemaVersion || refreshDueAt <= now
    }
}

/// The TTL rules for schedule records (Step 8 plan): a positive record refreshes at
/// the sooner of 6h or shortly after the known air time (so the next episode is
/// picked up once the current one airs); a "no upcoming" negative refreshes after 3
/// days for a continuing series or 30 days for an ended one.
public enum SeriesScheduleTTLPolicy {
    public static let positiveMax: TimeInterval = 6 * 60 * 60
    /// How long after a known air time the resolver becomes due, to advance to the
    /// following episode once the current one has aired.
    public static let postAirRefresh: TimeInterval = 6 * 60 * 60
    public static let negativeContinuing: TimeInterval = 3 * 24 * 60 * 60
    public static let negativeEnded: TimeInterval = 30 * 24 * 60 * 60

    /// When a record resolved at `refreshedAt` should next be refreshed.
    public static func refreshDue(
        upcomingEpisode: UpcomingEpisode?,
        seriesEnded: Bool,
        refreshedAt: Date
    ) -> Date {
        guard let upcoming = upcomingEpisode else {
            return refreshedAt.addingTimeInterval(seriesEnded ? negativeEnded : negativeContinuing)
        }
        let cap = refreshedAt.addingTimeInterval(positiveMax)
        let afterAir = upcoming.airDate.addingTimeInterval(postAirRefresh)
        return min(cap, afterAir)
    }
}

/// Persistent, on-disk store of one ``SeriesScheduleRecord`` per series.
///
/// Modeled on ``MetadataDiskCache`` (versioned JSON file in Caches, atomic writes)
/// but typed for schedule records and read-through: readers get the stored record
/// regardless of freshness (Home renders it with no network); the *resolver* consults
/// ``SeriesScheduleRecord/isRefreshDue(now:)`` to decide when to hit the network.
public actor SeriesScheduleStore {
    public static let shared = SeriesScheduleStore()

    private var records: [String: SeriesScheduleRecord] = [:]
    private let directory: URL?
    private let fileURL: URL?
    /// Safety cap so a pathological library can't grow the map without bound. Oldest
    /// records (by refreshedAt) are evicted first.
    private let maxRecords: Int
    private var loaded = false

    private static let fileName = "plozz-series-schedule-v1.json"
    private static let filePrefix = "plozz-series-schedule"

    public init(
        directory: URL? = SeriesScheduleStore.defaultDirectory(),
        maxRecords: Int = 4000
    ) {
        self.directory = directory
        self.fileURL = directory?.appendingPathComponent(Self.fileName)
        self.maxRecords = max(1, maxRecords)
    }

    /// The stored record for `key`, if any — regardless of freshness.
    public func record(for key: String) -> SeriesScheduleRecord? {
        loadIfNeeded()
        return records[key]
    }

    /// Every stored record (for Home rows). Cheap: the map is small and in-memory.
    public func allRecords() -> [SeriesScheduleRecord] {
        loadIfNeeded()
        return Array(records.values)
    }

    /// Stores (replaces) a record and persists the map atomically.
    public func store(_ record: SeriesScheduleRecord) {
        loadIfNeeded()
        records[record.seriesKey] = record
        evictIfNeeded()
        persist()
    }

    /// Drops every stored record (settings "clear cache").
    public func clear() {
        loadIfNeeded()
        records = [:]
        persist()
    }

    private func evictIfNeeded() {
        guard records.count > maxRecords else { return }
        let sorted = records.values.sorted { $0.refreshedAt < $1.refreshedAt }
        for record in sorted.prefix(records.count - maxRecords) {
            records[record.seriesKey] = nil
        }
    }

    private func loadIfNeeded() {
        if loaded { return }
        loaded = true
        guard let directory, let fileURL else { return }
        // A version bump leaves predecessors orphaned; sweep them like MetadataDiskCache.
        if let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for file in files where file.lastPathComponent != Self.fileName
                && file.lastPathComponent.hasPrefix(Self.filePrefix)
                && file.pathExtension == "json" {
                try? FileManager.default.removeItem(at: file)
            }
        }
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: SeriesScheduleRecord].self, from: data) else {
            return
        }
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
