import Foundation
import CoreModels

/// In-memory, lazily-populated index of a scanned SMB share for slice (a).
///
/// A media share has no server to compute libraries / continue-watching / detail,
/// so we scan the files once (depth- and count-capped) and synthesise a small
/// library tree: two libraries (Movies, TV), series → seasons → episodes, and
/// flat movies. Everything the `MediaProvider` returns is derived from here.
///
/// The scan is cached for the life of the provider instance (the registry keeps
/// one provider per account), so browsing after the first load is instant. A
/// real refresh / mtime-diff and a persistent cache come in a later phase.
actor ShareLibraryStore {
    static let moviesLibraryID = "lib:movies"
    static let tvLibraryID = "lib:tv"

    private let browser: SMBShareBrowser
    private let serverName: String

    // Raw scanned model.
    private struct EpisodeNode {
        var id: String        // "e:<relpath>"
        var path: String      // share-relative
        var season: Int
        var episode: Int
        var title: String?
        var modifiedAt: Date
    }
    private struct SeriesNode {
        var key: String       // lowercased series name
        var name: String
        var seasons: [Int: [EpisodeNode]] = [:]
        var modifiedAt: Date = .distantPast
    }
    private struct MovieNode {
        var id: String        // "m:<relpath>"
        var path: String
        var title: String
        var year: Int?
        var modifiedAt: Date
    }

    private var movies: [MovieNode] = []
    private var series: [String: SeriesNode] = [:]
    private var pathByID: [String: String] = [:]
    private var scanTask: Task<Void, Error>?

    // Scan caps so a huge NAS can't wedge the first browse.
    private let maxDepth = 8
    private let maxFiles = 8000

    init(browser: SMBShareBrowser, serverName: String) {
        self.browser = browser
        self.serverName = serverName
    }

    /// Run the scan at most once; concurrent callers await the same task.
    private func ensureScanned() async throws {
        if let scanTask { return try await scanTask.value }
        let task = Task { try await scan() }
        scanTask = task
        do { try await task.value } catch { scanTask = nil; throw error }
    }

    private func scan() async throws {
        var fileCount = 0
        // Iterative DFS over directories. Each stack entry carries the path and
        // the folder name to use as the "series hint" (grandparent when the
        // immediate parent is a Season folder).
        struct Dir { var path: String; var name: String; var depth: Int }
        var stack: [Dir] = [Dir(path: "", name: "", depth: 0)]

        while let dir = stack.popLast() {
            if fileCount >= maxFiles { break }
            let entries: [SMBShareBrowser.Entry]
            do { entries = try await browser.listDirectory(dir.path) }
            catch { continue } // skip unreadable dirs, keep scanning the rest

            for entry in entries {
                let childPath = dir.path.isEmpty ? entry.name : "\(dir.path)/\(entry.name)"
                if entry.isDirectory {
                    if dir.depth < maxDepth {
                        stack.append(Dir(path: childPath, name: entry.name, depth: dir.depth + 1))
                    }
                } else if ShareMediaParser.isVideoFile(entry.name) {
                    fileCount += 1
                    ingest(fileName: entry.name, relPath: childPath,
                           parentFolder: seriesHint(path: dir.path, folderName: dir.name),
                           modifiedAt: entry.modifiedAt)
                    if fileCount >= maxFiles { break }
                }
            }
        }
    }

    /// A "Season 01"/"S01" folder isn't the show name — its parent usually is.
    /// The scanner doesn't track grandparents cheaply, so when the immediate
    /// folder looks like a season we hand the parser `nil` and let it fall back
    /// to the filename (which typically still carries the show for such layouts).
    private func seriesHint(path: String, folderName: String) -> String? {
        if folderName.range(of: #"^[Ss](eason)?\s*\.?_?\d+$"#, options: .regularExpression) != nil {
            // Grandparent = the path component before the season folder.
            let comps = path.split(separator: "/").map(String.init)
            if comps.count >= 2 { return comps[comps.count - 2] }
            return nil
        }
        return folderName.isEmpty ? nil : folderName
    }

    private func ingest(fileName: String, relPath: String, parentFolder: String?, modifiedAt: Date) {
        switch ShareMediaParser.classify(fileName: fileName, parentFolder: parentFolder) {
        case .movie(let movie):
            let id = "m:\(relPath)"
            movies.append(MovieNode(id: id, path: relPath, title: movie.title,
                                    year: movie.year, modifiedAt: modifiedAt))
            pathByID[id] = relPath
        case .episode(let ep):
            let key = ep.series.lowercased()
            let id = "e:\(relPath)"
            var node = series[key] ?? SeriesNode(key: key, name: ep.series)
            node.seasons[ep.season, default: []].append(
                EpisodeNode(id: id, path: relPath, season: ep.season,
                            episode: ep.episode, title: ep.title, modifiedAt: modifiedAt))
            node.modifiedAt = max(node.modifiedAt, modifiedAt)
            series[key] = node
            pathByID[id] = relPath
        }
    }

    // MARK: - Public read API (all trigger a lazy scan)

    func libraries() async throws -> [MediaLibrary] {
        try await ensureScanned()
        var result: [MediaLibrary] = []
        if !movies.isEmpty {
            result.append(MediaLibrary(id: Self.moviesLibraryID, title: "Movies", kind: .movie))
        }
        if !series.isEmpty {
            result.append(MediaLibrary(id: Self.tvLibraryID, title: "TV Shows", kind: .series))
        }
        return result
    }

    /// The share-relative path backing a playable item id, or nil for containers.
    func path(forItemID id: String) async throws -> String? {
        try await ensureScanned()
        return pathByID[id]
    }

    func movieItems(sorted: Bool = true) async throws -> [MediaItem] {
        try await ensureScanned()
        let nodes = sorted ? movies.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending } : movies
        return nodes.map { movieItem($0) }
    }

    func seriesItems() async throws -> [MediaItem] {
        try await ensureScanned()
        return series.values
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { seriesItem($0) }
    }

    func seasons(ofSeriesID id: String) async throws -> [MediaItem] {
        try await ensureScanned()
        guard let node = seriesNode(forID: id) else { return [] }
        return node.seasons.keys.sorted().map { seasonItem(series: node, season: $0) }
    }

    func episodes(ofSeasonID id: String) async throws -> [MediaItem] {
        try await ensureScanned()
        // id == "z:<seriesKey>/<season>"
        guard id.hasPrefix("z:") else { return [] }
        let body = String(id.dropFirst(2))
        guard let slash = body.lastIndex(of: "/"),
              let season = Int(body[body.index(after: slash)...]) else { return [] }
        let key = String(body[..<slash])
        guard let node = series[key], let eps = node.seasons[season] else { return [] }
        return eps.sorted { $0.episode < $1.episode }.map { episodeItem(series: node, ep: $0) }
    }

    func item(id: String) async throws -> MediaItem? {
        try await ensureScanned()
        if id.hasPrefix("m:") { return movies.first { $0.id == id }.map(movieItem) }
        if id.hasPrefix("s:") { return seriesNode(forID: id).map(seriesItem) }
        if id.hasPrefix("z:") {
            let body = String(id.dropFirst(2))
            guard let slash = body.lastIndex(of: "/"),
                  let season = Int(body[body.index(after: slash)...]) else { return nil }
            let key = String(body[..<slash])
            guard let node = series[key] else { return nil }
            return seasonItem(series: node, season: season)
        }
        if id.hasPrefix("e:") {
            for node in series.values {
                for eps in node.seasons.values {
                    if let ep = eps.first(where: { $0.id == id }) {
                        return episodeItem(series: node, ep: ep)
                    }
                }
            }
        }
        return nil
    }

    func search(query: String, limit: Int) async throws -> [MediaItem] {
        try await ensureScanned()
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        var out: [MediaItem] = []
        out += movies.filter { $0.title.localizedCaseInsensitiveContains(q) }.map(movieItem)
        out += series.values.filter { $0.name.localizedCaseInsensitiveContains(q) }.map(seriesItem)
        return Array(out.prefix(limit))
    }

    // MARK: - Model → MediaItem

    private func seriesNode(forID id: String) -> SeriesNode? {
        guard id.hasPrefix("s:") else { return nil }
        return series[String(id.dropFirst(2))]
    }

    private func movieItem(_ n: MovieNode) -> MediaItem {
        MediaItem(id: n.id, title: n.title, kind: .movie, productionYear: n.year,
                  lastPlayedAt: nil)
    }

    private func seriesItem(_ n: SeriesNode) -> MediaItem {
        MediaItem(id: "s:\(n.key)", title: n.name, kind: .series)
    }

    private func seasonItem(series n: SeriesNode, season: Int) -> MediaItem {
        MediaItem(id: "z:\(n.key)/\(season)", title: "Season \(season)", kind: .season,
                  parentTitle: n.name, seasonNumber: season, seriesID: "s:\(n.key)")
    }

    private func episodeItem(series n: SeriesNode, ep: EpisodeNode) -> MediaItem {
        let title = ep.title ?? "Episode \(ep.episode)"
        return MediaItem(id: ep.id, title: title, kind: .episode,
                         parentTitle: n.name, seasonNumber: ep.season, episodeNumber: ep.episode,
                         seriesID: "s:\(n.key)", seasonID: "z:\(n.key)/\(ep.season)")
    }
}
