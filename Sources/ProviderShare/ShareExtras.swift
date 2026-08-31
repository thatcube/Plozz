import Foundation
import SQLite3
import CoreModels

enum ShareExtraFolderKind: Sendable, Equatable {
    case typed(MediaExtraKind)
    case generic(MediaExtraKind)
    case guardedAlias

    var defaultKind: MediaExtraKind {
        switch self {
        case .typed(let kind), .generic(let kind): kind
        case .guardedAlias: .other
        }
    }

    var permitsTypedChildren: Bool {
        if case .generic = self { return true }
        return false
    }
}

struct ShareExtraTraversal: Codable, Hashable, Sendable {
    var ownerPath: String
    var ownerFileRelPath: String?
    var defaultKind: MediaExtraKind
    var permitsTypedChildren: Bool
}

struct CatalogExtraCandidate: Sendable, Equatable {
    var relPath: String
    var parentDir: String
    var basename: String
    var size: Int64
    var modifiedAt: Date
    var kind: MediaExtraKind
    var title: String
    var ownerPath: String
    var ownerFileRelPath: String?

    var supportsResume: Bool {
        kind != .trailer && kind != .sample
    }

    var canonicalPath: String {
        ShareExtraDiscoveryPolicy.canonicalPath(relPath)
    }
}

enum ShareExtraDiscoveryPolicy {
    struct TerminalSuffix: Sendable, Equatable {
        var kind: MediaExtraKind
        var baseStemIdentity: String?
    }

    private static let typedFolders: [String: MediaExtraKind] = [
        "trailers": .trailer,
        "featurettes": .featurette,
        "behind the scenes": .behindTheScenes,
        "deleted scenes": .deletedScene,
        "interviews": .interview,
        "scenes": .scene,
        "shorts": .short,
        "other": .other,
    ]

    private static let genericFolders: [String: MediaExtraKind] = [
        "extras": .other,
        "clips": .scene,
        "samples": .sample,
    ]

    private static let guardedAliases: Set<String> = [
        "bonus", "bonus content", "bonus features", "special features", "xtras",
    ]

    private static let suffixes: [String: MediaExtraKind] = [
        "behindthescenes": .behindTheScenes,
        "deletedscenes": .deletedScene,
        "deletedscene": .deletedScene,
        "deleted": .deletedScene,
        "featurettes": .featurette,
        "featurette": .featurette,
        "interviews": .interview,
        "interview": .interview,
        "trailers": .trailer,
        "trailer": .trailer,
        "samples": .sample,
        "sample": .sample,
        "scenes": .scene,
        "scene": .scene,
        "clips": .scene,
        "clip": .scene,
        "shorts": .short,
        "short": .short,
        "extras": .other,
        "extra": .other,
        "other": .other,
    ]

    static func folderKind(_ name: String) -> ShareExtraFolderKind? {
        let key = folderIdentity(name)
        if let kind = typedFolders[key] { return .typed(kind) }
        if let kind = genericFolders[key] { return .generic(kind) }
        if guardedAliases.contains(key) { return .guardedAlias }
        return nil
    }

    static func terminalSuffix(inFileName name: String) -> TerminalSuffix? {
        let stem = ShareMediaParser.videoStem(name)
        let folded = stem
            .precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        var matches: [(offset: String.Index, kind: MediaExtraKind)] = []
        for index in folded.indices where folded[index] == "-" || folded[index] == "." || folded[index] == "_" {
            let tailStart = folded.index(after: index)
            let tail = folded[tailStart...]
            guard tail.allSatisfy({
                $0.isLetter || $0.isWhitespace || $0 == "-" || $0 == "." || $0 == "_"
            }) else { continue }
            let identity = tail.filter(\.isLetter)
            if let kind = suffixes[identity] {
                matches.append((index, kind))
            }
        }
        guard let match = matches.min(by: { $0.offset < $1.offset }) else { return nil }
        let base = stemIdentity(String(folded[..<match.offset]))
        guard !base.isEmpty else { return nil }
        return TerminalSuffix(kind: match.kind, baseStemIdentity: base)
    }

    static func stemIdentity(_ value: String) -> String {
        identityTokens(value).joined(separator: " ")
    }

    static func movieFolderProvesOwner(
        _ folder: String,
        titleKey: String,
        year: Int?
    ) -> Bool {
        let folderKey = ShareCatalogID.seriesKey(fromTitle: folder)
        if folderKey == titleKey { return true }
        guard let year else { return false }
        return folderKey == "\(titleKey)-\(year)"
    }

    static func canonicalPath(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
            .joined(separator: "/")
            .precomposedStringWithCanonicalMapping
    }

    static func title(forFileName name: String, fallbackKind: MediaExtraKind) -> String {
        let stem = ShareMediaParser.videoStem(name)
        let cleaned = identityTokens(stem)
            .map { token in
                guard let first = token.first else { return token }
                return String(first).uppercased() + token.dropFirst()
            }
            .joined(separator: " ")
        return cleaned.isEmpty ? defaultTitle(for: fallbackKind) : cleaned
    }

    static func resumeBehavior(forItemID itemID: String) -> Bool? {
        guard let relPath = ShareCatalogID.relPath(forFileID: itemID) else { return nil }
        if let suffix = terminalSuffix(inFileName: (relPath as NSString).lastPathComponent) {
            return suffix.kind != .trailer && suffix.kind != .sample
        }
        for component in relPath.split(separator: "/").dropLast().reversed() {
            guard let folder = folderKind(String(component)) else { continue }
            let kind = folder.defaultKind
            return kind != .trailer && kind != .sample
        }
        return nil
    }

    static func isRecognizedExtraItemID(_ itemID: String) -> Bool {
        resumeBehavior(forItemID: itemID) != nil
    }

    static func isExplicitCollectionPath(_ path: String) -> Bool {
        let components = path.split(separator: "/").map(String.init)
        guard components.count >= 2 else { return false }
        let parent = folderIdentity(components[components.count - 2])
        return parent == "collection" || parent == "collections"
    }

    private static func folderIdentity(_ value: String) -> String {
        identityTokens(value).joined(separator: " ")
    }

    private static func identityTokens(_ value: String) -> [String] {
        let folded = value
            .precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return folded
            .split { character in
                character.isWhitespace || character == "." || character == "-" || character == "_"
            }
            .map(String.init)
    }

    private static func defaultTitle(for kind: MediaExtraKind) -> String {
        switch kind {
        case .trailer: return "Trailer"
        case .featurette: return "Featurette"
        case .behindTheScenes: return "Behind the Scenes"
        case .deletedScene: return "Deleted Scene"
        case .interview: return "Interview"
        case .scene, .sceneOrSample: return "Scene"
        case .sample: return "Sample"
        case .musicPerformance: return "Music & Performance"
        case .short: return "Short"
        case .other, .unknown: return "Extra"
        }
    }
}

struct ShareExtraRepository {
    private struct AssetFact {
        var relPath: String
        var kind: CatalogAssetKind
        var title: String
        var seriesTitle: String?
        var seriesKey: String?
        var season: Int?
        var episode: Int?
        var movieKey: String?
        var movieTitleKey: String?
        var movieGroupKey: String?
        var metadataRoot: String?
    }

    private struct Owner {
        var id: String
        var kind: MediaExtraOwnerKind
        var title: String
    }

    private struct PendingOwner {
        var canonicalPath: String
        var ownerPath: String
        var ownerFileRelPath: String?
    }

    let connection: CatalogConnection
    private var db: OpaquePointer? { connection.db }

    func upsert(_ candidates: [CatalogExtraCandidate], scanID: Int64) -> Bool {
        guard let db, !candidates.isEmpty else { return true }
        var statement: OpaquePointer?
        let sql = """
        INSERT INTO extras(
          canonical_path, rel_path, parent_dir, basename, size, modified_at,
          last_scan, kind, title, supports_resume, owner_path, owner_file_rel_path
        ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(canonical_path) DO UPDATE SET
          rel_path=excluded.rel_path,
          parent_dir=excluded.parent_dir,
          basename=excluded.basename,
          size=excluded.size,
          modified_at=excluded.modified_at,
          last_scan=excluded.last_scan,
          kind=excluded.kind,
          title=excluded.title,
          supports_resume=excluded.supports_resume,
          owner_path=excluded.owner_path,
          owner_file_rel_path=excluded.owner_file_rel_path;
        """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return false }
        defer { sqlite3_finalize(statement) }

        var byCanonical: [String: CatalogExtraCandidate] = [:]
        for candidate in candidates.sorted(by: { $0.relPath < $1.relPath }) {
            if byCanonical[candidate.canonicalPath] == nil {
                byCanonical[candidate.canonicalPath] = candidate
            }
        }
        for candidate in byCanonical.values.sorted(by: { $0.canonicalPath < $1.canonicalPath }) {
            sqlite3_reset(statement)
            CatalogConnection.bindText(statement, 1, candidate.canonicalPath)
            CatalogConnection.bindText(statement, 2, candidate.relPath)
            CatalogConnection.bindText(statement, 3, candidate.parentDir)
            CatalogConnection.bindText(statement, 4, candidate.basename)
            sqlite3_bind_int64(statement, 5, candidate.size)
            sqlite3_bind_double(statement, 6, candidate.modifiedAt.timeIntervalSince1970)
            sqlite3_bind_int64(statement, 7, scanID)
            CatalogConnection.bindText(statement, 8, candidate.kind.rawValue)
            CatalogConnection.bindText(statement, 9, candidate.title)
            sqlite3_bind_int(statement, 10, candidate.supportsResume ? 1 : 0)
            CatalogConnection.bindText(statement, 11, candidate.ownerPath)
            CatalogConnection.bindOptText(statement, 12, candidate.ownerFileRelPath)
            guard sqlite3_step(statement) == SQLITE_DONE else { return false }
        }
        return true
    }

    func finalizeCleanScan(scanID: Int64) -> Bool {
        guard deleteStale(scanID: scanID) else { return false }
        return resolveOwners(deleteUnresolved: true)
    }

    func resolveOwners(deleteUnresolved: Bool) -> Bool {
        guard let db else { return false }
        var pending: [PendingOwner] = []
        connection.query("""
        SELECT canonical_path, owner_path, owner_file_rel_path
        FROM extras ORDER BY canonical_path;
        """) { statement in
            guard let canonicalPath = CatalogConnection.columnText(statement, 0),
                  let ownerPath = CatalogConnection.columnText(statement, 1) else { return }
            pending.append(PendingOwner(
                canonicalPath: canonicalPath,
                ownerPath: ownerPath,
                ownerFileRelPath: CatalogConnection.columnText(statement, 2)
            ))
        }

        var update: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
        UPDATE extras SET owner_id=?, owner_kind=?, owner_title=?
        WHERE canonical_path=?;
        """, -1, &update, nil) == SQLITE_OK, let update else { return false }
        defer { sqlite3_finalize(update) }

        var delete: OpaquePointer?
        if deleteUnresolved {
            guard sqlite3_prepare_v2(
                db,
                "DELETE FROM extras WHERE canonical_path=?;",
                -1,
                &delete,
                nil
            ) == SQLITE_OK else { return false }
        }
        defer { sqlite3_finalize(delete) }

        for candidate in pending {
            guard let owner = resolveOwner(
                ownerPath: candidate.ownerPath,
                ownerFileRelPath: candidate.ownerFileRelPath
            ) else {
                guard deleteUnresolved, let delete else { continue }
                sqlite3_reset(delete)
                CatalogConnection.bindText(delete, 1, candidate.canonicalPath)
                guard sqlite3_step(delete) == SQLITE_DONE else { return false }
                continue
            }
            sqlite3_reset(update)
            CatalogConnection.bindText(update, 1, owner.id)
            CatalogConnection.bindText(update, 2, owner.kind.rawValue)
            CatalogConnection.bindText(update, 3, owner.title)
            CatalogConnection.bindText(update, 4, candidate.canonicalPath)
            guard sqlite3_step(update) == SQLITE_DONE else { return false }
        }
        return true
    }

    func removeResolvedAssetRows() -> Bool {
        connection.runUpdate("""
        DELETE FROM assets
        WHERE rel_path IN (
          SELECT rel_path FROM extras WHERE owner_id IS NOT NULL
        );
        """, bind: { _ in })
    }

    func extras(ownerID: String) -> [MediaExtra] {
        var result: [MediaExtra] = []
        connection.query("""
        SELECT rel_path, title, kind, supports_resume, owner_id, owner_kind, owner_title
        FROM extras
        WHERE owner_id=?
        ORDER BY
          CASE kind
            WHEN 'trailer' THEN 0
            WHEN 'featurette' THEN 1
            WHEN 'behindTheScenes' THEN 2
            WHEN 'deletedScene' THEN 3
            WHEN 'interview' THEN 4
            WHEN 'scene' THEN 5
            WHEN 'sample' THEN 5
            WHEN 'short' THEN 7
            ELSE 8
          END,
          title COLLATE NOCASE,
          canonical_path;
        """, bind: {
            CatalogConnection.bindText($0, 1, ownerID)
        }) { statement in
            if let extra = materialize(statement) { result.append(extra) }
        }
        return MediaExtra.ordered(result)
    }

    func extra(fileID: String) -> MediaExtra? {
        guard let relPath = ShareCatalogID.relPath(forFileID: fileID) else { return nil }
        let canonicalPath = ShareExtraDiscoveryPolicy.canonicalPath(relPath)
        var result: MediaExtra?
        connection.query("""
        SELECT rel_path, title, kind, supports_resume, owner_id, owner_kind, owner_title
        FROM extras WHERE canonical_path=? LIMIT 1;
        """, bind: {
            CatalogConnection.bindText($0, 1, canonicalPath)
        }) { statement in
            result = materialize(statement)
        }
        return result
    }

    func count() -> Int {
        var result = 0
        connection.query("SELECT COUNT(*) FROM extras;") {
            result = Int(sqlite3_column_int64($0, 0))
        }
        return result
    }

    private func materialize(_ statement: OpaquePointer?) -> MediaExtra? {
        guard let relPath = CatalogConnection.columnText(statement, 0),
              let title = CatalogConnection.columnText(statement, 1),
              let kindText = CatalogConnection.columnText(statement, 2),
              let ownerID = CatalogConnection.columnText(statement, 4),
              let ownerKindText = CatalogConnection.columnText(statement, 5)
        else { return nil }
        let kind = MediaExtraKind(rawProviderValue: kindText)
        let ownerKind: MediaExtraOwnerKind
        switch ownerKindText {
        case MediaExtraOwnerKind.movie.rawValue: ownerKind = .movie
        case MediaExtraOwnerKind.series.rawValue: ownerKind = .series
        case MediaExtraOwnerKind.season.rawValue: ownerKind = .season
        case MediaExtraOwnerKind.episode.rawValue: ownerKind = .episode
        case MediaExtraOwnerKind.collection.rawValue: ownerKind = .collection
        default: ownerKind = .other
        }
        return MediaExtra(
            item: MediaItem(id: ShareCatalogID.file(relPath), title: title, kind: .video),
            kind: kind,
            rawProviderType: kindText,
            owner: MediaExtraOwner(
                id: ownerID,
                kind: ownerKind,
                title: CatalogConnection.columnText(statement, 6)
            ),
            supportsResume: sqlite3_column_int(statement, 3) != 0
        )
    }

    private func deleteStale(scanID: Int64) -> Bool {
        connection.runUpdate("DELETE FROM extras WHERE last_scan <> ?;") {
            sqlite3_bind_int64($0, 1, scanID)
        }
    }

    private func resolveOwner(ownerPath: String, ownerFileRelPath: String?) -> Owner? {
        if let ownerFileRelPath,
           let asset = asset(relPath: ownerFileRelPath) {
            return owner(for: asset)
        }

        let direct = directAssets(in: ownerPath)
        let directMovies = direct.filter { $0.kind == .movie }
        let directEpisodes = direct.filter { $0.kind == .episode }
        let series = seriesOwners(metadataRoot: ownerPath)

        let folderName = ownerPath.split(separator: "/").last.map(String.init)
        if let season = ShareMediaParser.seasonNumber(fromFolder: folderName) {
            guard directMovies.isEmpty else { return nil }
            let matching = directEpisodes.filter { $0.season == season && $0.seriesKey != nil }
            let keys = Set(matching.compactMap(\.seriesKey))
            guard keys.count == 1, let key = keys.first else { return nil }
            return Owner(
                id: ShareCatalogID.season(key, season),
                kind: .season,
                title: season == 0 ? "Specials" : "Season \(season)"
            )
        }

        if directMovies.isEmpty, series.count == 1, let seriesOwner = series.first {
            return seriesOwner
        }

        let movieOwners = Dictionary(
            grouping: directMovies.compactMap { asset -> (String, AssetFact)? in
                resolvedMovieKey(asset).map { ($0, asset) }
            },
            by: \.0
        ).mapValues { $0.map(\.1) }
        if directEpisodes.isEmpty,
           series.isEmpty,
           movieOwners.count == 1,
           let (key, rows) = movieOwners.first,
           directoryProvesMovie(ownerPath, rows: rows) {
            return Owner(
                id: ShareCatalogID.movie(key),
                kind: .movie,
                title: rows.map(\.title).sorted().first ?? key
            )
        }

        if directMovies.isEmpty, series.isEmpty, directEpisodes.count == 1,
           let episode = directEpisodes.first {
            return Owner(
                id: ShareCatalogID.file(episode.relPath),
                kind: .episode,
                title: episode.title
            )
        }

        if direct.isEmpty, series.isEmpty,
           ShareExtraDiscoveryPolicy.isExplicitCollectionPath(ownerPath),
           let title = ownerPath.split(separator: "/").last.map(String.init) {
            return Owner(id: "d:\(ownerPath)", kind: .collection, title: title)
        }
        return nil
    }

    private func owner(for asset: AssetFact) -> Owner? {
        switch asset.kind {
        case .movie:
            guard let key = resolvedMovieKey(asset) else { return nil }
            return Owner(id: ShareCatalogID.movie(key), kind: .movie, title: asset.title)
        case .episode:
            return Owner(
                id: ShareCatalogID.file(asset.relPath),
                kind: .episode,
                title: asset.title
            )
        }
    }

    private func directoryProvesMovie(_ ownerPath: String, rows: [AssetFact]) -> Bool {
        guard !ownerPath.isEmpty,
              let folder = ownerPath.split(separator: "/").last.map(String.init) else {
            return false
        }
        return rows.contains { row in
            guard let titleKey = row.movieTitleKey else { return false }
            return ShareExtraDiscoveryPolicy.movieFolderProvesOwner(
                folder,
                titleKey: titleKey,
                year: row.movieKey.flatMap { key in
                    key.split(separator: "-").last.flatMap { Int($0) }
                }
            )
        }
    }

    private func resolvedMovieKey(_ asset: AssetFact) -> String? {
        asset.movieGroupKey ?? asset.movieKey
    }

    private func seriesOwners(metadataRoot: String) -> [Owner] {
        var grouped: [String: [String]] = [:]
        connection.query("""
        SELECT series_key, series_title
        FROM assets
        WHERE kind='episode' AND metadata_root=? AND series_key IS NOT NULL;
        """, bind: {
            CatalogConnection.bindText($0, 1, metadataRoot)
        }) { statement in
            guard let key = CatalogConnection.columnText(statement, 0) else { return }
            grouped[key, default: []].append(
                CatalogConnection.columnText(statement, 1) ?? key
            )
        }
        return grouped.map { key, titles in
            Owner(
                id: ShareCatalogID.series(key),
                kind: .series,
                title: titles.sorted().first ?? key
            )
        }
    }

    private func asset(relPath: String) -> AssetFact? {
        var result: AssetFact?
        connection.query("""
        SELECT rel_path, kind, title, series_title, series_key, season, episode,
               movie_key, movie_title_key, movie_group_key, metadata_root
        FROM assets WHERE rel_path=? LIMIT 1;
        """, bind: {
            CatalogConnection.bindText($0, 1, relPath)
        }) { statement in
            result = materializeAsset(statement)
        }
        return result
    }

    private func directAssets(in directory: String) -> [AssetFact] {
        var result: [AssetFact] = []
        let sql: String
        let prefix = directory.isEmpty ? "" : "\(directory)/"
        if directory.isEmpty {
            sql = """
            SELECT rel_path, kind, title, series_title, series_key, season, episode,
                   movie_key, movie_title_key, movie_group_key, metadata_root
            FROM assets
            WHERE instr(rel_path, '/')=0
              AND NOT EXISTS (
                SELECT 1 FROM extras WHERE extras.rel_path=assets.rel_path
              );
            """
        } else {
            sql = """
            SELECT rel_path, kind, title, series_title, series_key, season, episode,
                   movie_key, movie_title_key, movie_group_key, metadata_root
            FROM assets
            WHERE substr(rel_path, 1, length(?))=?
              AND NOT EXISTS (
                SELECT 1 FROM extras WHERE extras.rel_path=assets.rel_path
              );
            """
        }
        connection.query(sql, bind: { statement in
            guard !directory.isEmpty else { return }
            CatalogConnection.bindText(statement, 1, prefix)
            CatalogConnection.bindText(statement, 2, prefix)
        }) { statement in
            guard let asset = materializeAsset(statement),
                  parentDirectory(of: asset.relPath) == directory else { return }
            result.append(asset)
        }
        return result
    }

    private func materializeAsset(_ statement: OpaquePointer?) -> AssetFact? {
        guard let relPath = CatalogConnection.columnText(statement, 0),
              let kindText = CatalogConnection.columnText(statement, 1),
              let kind = CatalogAssetKind(rawValue: kindText),
              let title = CatalogConnection.columnText(statement, 2)
        else { return nil }
        return AssetFact(
            relPath: relPath,
            kind: kind,
            title: title,
            seriesTitle: CatalogConnection.columnText(statement, 3),
            seriesKey: CatalogConnection.columnText(statement, 4),
            season: CatalogConnection.columnOptInt(statement, 5),
            episode: CatalogConnection.columnOptInt(statement, 6),
            movieKey: CatalogConnection.columnText(statement, 7),
            movieTitleKey: CatalogConnection.columnText(statement, 8),
            movieGroupKey: CatalogConnection.columnText(statement, 9),
            metadataRoot: CatalogConnection.columnText(statement, 10)
        )
    }

    private func parentDirectory(of path: String) -> String {
        guard let separator = path.lastIndex(of: "/") else { return "" }
        return String(path[..<separator])
    }
}
