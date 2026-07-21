#if os(iOS)
import CoreModels
import Foundation
import MediaDownloads

/// A view-friendly, grouped projection of the flat download registry.
///
/// The registry stores one `DownloadedMediaRecord` per item. For a browsable
/// Downloads library we want standalone **movies** as top-level rows and every
/// **show** collapsed into a single row that drills into its seasons/episodes —
/// so a 300-episode grab is one entry to manage, not 300. Grouping keys off the
/// enriched snapshot (`seriesID`/`seriesTitle`/`seasonNumber`) when present and
/// falls back to the durable season `groupID` for records pinned before snapshot
/// enrichment, so legacy downloads still cluster and stay removable as a unit.
struct PlozziOSDownloadLibrary {
    var movies: [PlozziOSDownloadedMovie]
    var shows: [PlozziOSDownloadedShow]

    var isEmpty: Bool { movies.isEmpty && shows.isEmpty }

    /// Top-level entries (movies + shows) ordered by most-recent activity so a
    /// fresh download surfaces at the top.
    var entries: [PlozziOSDownloadEntry] {
        let movieEntries = movies.map(PlozziOSDownloadEntry.movie)
        let showEntries = shows.map(PlozziOSDownloadEntry.show)
        return (movieEntries + showEntries)
            .sorted { $0.mostRecentActivity > $1.mostRecentActivity }
    }

    var totalBytes: Int64 {
        movies.reduce(0) { $0 + $1.record.bytesDownloaded }
            + shows.reduce(0) { $0 + $1.totalBytes }
    }
}

enum PlozziOSDownloadEntry: Identifiable {
    case movie(PlozziOSDownloadedMovie)
    case show(PlozziOSDownloadedShow)

    var id: String {
        switch self {
        case let .movie(movie): "movie:\(movie.id)"
        case let .show(show): "show:\(show.id)"
        }
    }

    var mostRecentActivity: Date {
        switch self {
        case let .movie(movie): movie.record.updatedAt
        case let .show(show): show.mostRecentActivity
        }
    }
}

struct PlozziOSDownloadedMovie: Identifiable {
    let record: DownloadedMediaRecord
    var id: String { record.identityKey }
}

struct PlozziOSDownloadedShow: Identifiable {
    let id: String
    let title: String
    let seasons: [PlozziOSDownloadedSeason]

    var records: [DownloadedMediaRecord] { seasons.flatMap(\.records) }
    var episodeCount: Int { records.count }
    var totalBytes: Int64 { records.reduce(0) { $0 + $1.bytesDownloaded } }
    var mostRecentActivity: Date {
        records.map(\.updatedAt).max() ?? .distantPast
    }

    /// The record whose pinned artwork best represents the show in a row.
    var artworkRecord: DownloadedMediaRecord? {
        records.first { $0.snapshot.artworkFileName != nil } ?? records.first
    }
}

struct PlozziOSDownloadedSeason: Identifiable {
    let id: String
    let seasonNumber: Int?
    let title: String
    let records: [DownloadedMediaRecord]

    var totalBytes: Int64 { records.reduce(0) { $0 + $1.bytesDownloaded } }
    var episodeCount: Int { records.count }
}

extension PlozziOSDownloadLibrary {
    /// Groups a flat record list into movies + shows → seasons → episodes.
    static func make(from records: [DownloadedMediaRecord]) -> PlozziOSDownloadLibrary {
        var movieRecords: [DownloadedMediaRecord] = []
        var episodeRecords: [DownloadedMediaRecord] = []

        for record in records {
            switch record.snapshot.kind {
            case .episode, .series, .season:
                episodeRecords.append(record)
            default:
                movieRecords.append(record)
            }
        }

        let movies = movieRecords
            .sorted { $0.updatedAt > $1.updatedAt }
            .map(PlozziOSDownloadedMovie.init)

        // Group episodes into shows by a stable series key, preserving insertion
        // order so the first-seen title/label wins for the group.
        var showOrder: [String] = []
        var showBuckets: [String: [DownloadedMediaRecord]] = [:]
        for record in episodeRecords {
            let key = seriesKey(for: record)
            if showBuckets[key] == nil {
                showBuckets[key] = []
                showOrder.append(key)
            }
            showBuckets[key]?.append(record)
        }

        let shows = showOrder.compactMap { key -> PlozziOSDownloadedShow? in
            guard let bucket = showBuckets[key], !bucket.isEmpty else { return nil }
            return makeShow(key: key, records: bucket)
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

        return PlozziOSDownloadLibrary(movies: movies, shows: shows)
    }

    private static func seriesKey(for record: DownloadedMediaRecord) -> String {
        if let seriesID = record.snapshot.seriesID, !seriesID.isEmpty {
            return "series:\(seriesID)"
        }
        if let seriesTitle = record.snapshot.seriesTitle,
           !seriesTitle.trimmingCharacters(in: .whitespaces).isEmpty {
            return "seriestitle:\(seriesTitle.lowercased())"
        }
        if let groupID = record.groupID, !groupID.isEmpty {
            return "group:\(groupID)"
        }
        return "single:\(record.identityKey)"
    }

    private static func makeShow(
        key: String,
        records: [DownloadedMediaRecord]
    ) -> PlozziOSDownloadedShow {
        let title = records
            .compactMap { snapshotSeriesTitle($0) }
            .first ?? "Downloaded Episodes"

        // Season key: prefer the snapshot's season number; fall back to the
        // durable season `groupID` so legacy episodes still bucket per season.
        var seasonOrder: [String] = []
        var seasonBuckets: [String: [DownloadedMediaRecord]] = [:]
        for record in records {
            let seasonKey = seasonKey(for: record)
            if seasonBuckets[seasonKey] == nil {
                seasonBuckets[seasonKey] = []
                seasonOrder.append(seasonKey)
            }
            seasonBuckets[seasonKey]?.append(record)
        }

        let seasons = seasonOrder.compactMap { seasonKey -> PlozziOSDownloadedSeason? in
            guard let bucket = seasonBuckets[seasonKey], !bucket.isEmpty else {
                return nil
            }
            return makeSeason(key: seasonKey, records: bucket)
        }
        .sorted { lhs, rhs in
            switch (lhs.seasonNumber, rhs.seasonNumber) {
            case let (l?, r?): return l < r
            case (nil, _?): return false
            case (_?, nil): return true
            case (nil, nil):
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title)
                    == .orderedAscending
            }
        }

        return PlozziOSDownloadedShow(id: key, title: title, seasons: seasons)
    }

    private static func makeSeason(
        key: String,
        records: [DownloadedMediaRecord]
    ) -> PlozziOSDownloadedSeason {
        let seasonNumber = records.compactMap { $0.snapshot.seasonNumber }.first
        let title: String
        if let seasonNumber {
            title = "Season \(seasonNumber)"
        } else {
            title = "Episodes"
        }
        let sorted = records.sorted { lhs, rhs in
            switch (lhs.snapshot.episodeNumber, rhs.snapshot.episodeNumber) {
            case let (l?, r?): return l < r
            case (nil, _?): return false
            case (_?, nil): return true
            case (nil, nil):
                return lhs.snapshot.title.localizedCaseInsensitiveCompare(
                    rhs.snapshot.title
                ) == .orderedAscending
            }
        }
        return PlozziOSDownloadedSeason(
            id: key,
            seasonNumber: seasonNumber,
            title: title,
            records: sorted
        )
    }

    private static func seasonKey(for record: DownloadedMediaRecord) -> String {
        if let seasonNumber = record.snapshot.seasonNumber {
            return "season:\(seasonNumber)"
        }
        if let groupID = record.groupID, !groupID.isEmpty {
            return "group:\(groupID)"
        }
        return "loose"
    }

    private static func snapshotSeriesTitle(
        _ record: DownloadedMediaRecord
    ) -> String? {
        guard let title = record.snapshot.seriesTitle?
            .trimmingCharacters(in: .whitespaces),
            !title.isEmpty else {
            return nil
        }
        return title
    }
}
#endif
