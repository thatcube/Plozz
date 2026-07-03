import Foundation
import CoreModels
import CoreNetworking

/// Lazy folder browser over an SMB share.
///
/// A general-purpose file share (unlike Plex/Jellyfin) has no notion of
/// "libraries", curated metadata, or a clean movie/episode split — the root
/// holds whatever the user put there (Movies, TV Shows, Downloads, Photos, …).
/// Trying to recursively scan-and-classify everything produced thousands of
/// bogus "movies" from non-media folders. So instead — exactly like Infuse's
/// Files mode, VLC, or Kodi's file view — we present the **real directory tree**
/// and let the user navigate it. Each directory is listed on demand (one network
/// round-trip per folder the user actually opens); nothing is walked eagerly.
///
/// Item id scheme (share-relative path, no leading slash):
///   * root container  → `Self.rootLibraryID`
///   * a sub-folder     → `"d:<relpath>"`   (kind `.folder`, navigable)
///   * a playable file  → `"f:<relpath>"`   (kind `.video`, playable)
actor ShareLibraryStore {
    /// The single synthetic "library" a share exposes: its root folder. Browsing
    /// it lists the real top-level folders/files, and the user drills in from
    /// there. Home aggregation can show this instantly (no network) — the listing
    /// only happens when the row is actually opened.
    static let rootLibraryID = "share:root"

    private let browser: SMBShareBrowser
    private let serverName: String

    init(browser: SMBShareBrowser, serverName: String) {
        self.browser = browser
        self.serverName = serverName
    }

    // MARK: - Libraries

    /// A share presents exactly one browsable "library": its root folder. Kept as
    /// `.folder` so the browse UI treats every entry as navigable/​playable by its
    /// own kind rather than forcing a movie/series split.
    func libraries() -> [MediaLibrary] {
        [MediaLibrary(id: Self.rootLibraryID, title: serverName, kind: .folder)]
    }

    // MARK: - Directory listing (lazy, one folder per call)

    /// List a container (root or a `"d:<relpath>"` folder) as MediaItems:
    /// sub-folders become navigable `.folder` items, playable files become
    /// `.video` items, everything else (photos, docs, `.DS_Store`, …) is hidden.
    /// Folders sort first, then files, both case-insensitively by name.
    func entries(forContainerID id: String) async throws -> [MediaItem] {
        let relPath = Self.relativePath(forContainerID: id)
        guard let relPath else { return [] }
        let entries = try await browser.listDirectory(relPath)

        var folders: [MediaItem] = []
        var videos: [MediaItem] = []
        for entry in entries {
            let childPath = relPath.isEmpty ? entry.name : "\(relPath)/\(entry.name)"
            if entry.isDirectory {
                folders.append(folderItem(relPath: childPath, name: entry.name))
            } else if ShareMediaParser.isVideoFile(entry.name) {
                videos.append(videoItem(relPath: childPath, name: entry.name))
            }
        }
        folders.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        videos.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        return folders + videos
    }

    // MARK: - Item / path lookup (derived from the id — no network)

    /// Reconstruct a MediaItem straight from its id. Folder/root/video ids all
    /// encode their share-relative path, so this needs no scan and no cache — the
    /// title is just the last path component (or the share name for the root).
    func item(id: String) -> MediaItem? {
        if id == Self.rootLibraryID {
            return folderItem(relPath: "", name: serverName)
        }
        if id.hasPrefix("d:") {
            let relPath = String(id.dropFirst(2))
            return folderItem(relPath: relPath, name: Self.lastComponent(relPath))
        }
        if id.hasPrefix("f:") {
            let relPath = String(id.dropFirst(2))
            return videoItem(relPath: relPath, name: Self.lastComponent(relPath))
        }
        return nil
    }

    /// The share-relative path backing a playable item id, or nil for containers.
    func path(forItemID id: String) -> String? {
        id.hasPrefix("f:") ? String(id.dropFirst(2)) : nil
    }

    // MARK: - Search (best-effort shallow walk)

    /// A file share has no index, so a true search would mean walking the whole
    /// tree on every query. Slice (a) keeps browsing snappy and skips search; a
    /// cached index-backed search arrives with the metadata phase.
    func search(query: String, limit: Int) async throws -> [MediaItem] {
        []
    }

    // MARK: - Model → MediaItem

    private func folderItem(relPath: String, name: String) -> MediaItem {
        let id = relPath.isEmpty ? Self.rootLibraryID : "d:\(relPath)"
        return MediaItem(id: id, title: name, kind: .folder)
    }

    private func videoItem(relPath: String, name: String) -> MediaItem {
        // Enrich the bare file into a movie/episode so the generic MetadataKit
        // artwork pipeline (ArtworkRouter → TMDb/TVmaze/AniList) can resolve a
        // poster/backdrop and the detail page can look up an overview. Nothing
        // here is a *match* yet — it's a best-effort parse of the filename (and
        // its folder) into a clean title + year + season/episode; a wrong guess
        // just falls back to the clean title on a neutral card.
        let id = "f:\(relPath)"
        let parentHint = Self.seriesHintFolder(forRelPath: relPath)
        switch ShareMediaParser.classify(fileName: name, parentFolder: parentHint) {
        case .movie(let movie):
            return MediaItem(
                id: id,
                title: movie.title.isEmpty ? Self.displayTitle(forFileName: name) : movie.title,
                kind: .movie,
                productionYear: movie.year
            )
        case .episode(let episode):
            let fallbackTitle = "S\(episode.season)·E\(String(format: "%02d", episode.episode))"
            return MediaItem(
                id: id,
                title: episode.title ?? fallbackTitle,
                kind: .episode,
                parentTitle: episode.series,
                seasonNumber: episode.season,
                episodeNumber: episode.episode
            )
        }
    }

    // MARK: - Helpers

    /// Map a container id to its share-relative path (root → "").
    private static func relativePath(forContainerID id: String) -> String? {
        if id == rootLibraryID { return "" }
        if id.hasPrefix("d:") { return String(id.dropFirst(2)) }
        return nil
    }

    private static func lastComponent(_ relPath: String) -> String {
        relPath.split(separator: "/").last.map(String.init) ?? relPath
    }

    /// The folder name that best hints at a *series* title for an episode file:
    /// normally the file's immediate parent, but when that parent is a "Season N"
    /// / "S03" folder we hop up to its parent (the show) instead — so an episode
    /// in `TV Shows/Breaking Bad/Season 1/ep.mkv` recovers "Breaking Bad", not
    /// "Season 1". `nil` when the file sits at the share root.
    private static func seriesHintFolder(forRelPath relPath: String) -> String? {
        var dirs = relPath.split(separator: "/").map(String.init)
        guard dirs.count >= 2 else { return nil } // just "<file>" → no parent dir
        dirs.removeLast() // drop the filename
        guard let parent = dirs.last else { return nil }
        if isSeasonFolder(parent), dirs.count >= 2 {
            return dirs[dirs.count - 2]
        }
        return parent
    }

    private static func isSeasonFolder(_ name: String) -> Bool {
        name.range(of: #"^[Ss]eason\s*\d+$"#, options: .regularExpression) != nil
            || name.range(of: #"^[Ss]\d{1,2}$"#, options: .regularExpression) != nil
    }

    /// Drop the file extension for a cleaner on-screen title while still showing
    /// the real file name (no aggressive "movie parser" rewriting — the user
    /// asked to see their actual files).
    private static func displayTitle(forFileName name: String) -> String {
        let base = (name as NSString).deletingPathExtension
        return base.isEmpty ? name : base
    }
}
