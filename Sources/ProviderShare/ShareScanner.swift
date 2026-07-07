import Foundation
import CoreModels
import CoreNetworking

/// Walks a share's directory tree once and populates a `ShareCatalogStore`, so the
/// share can serve Recently Added / Search / indexed libraries without a live walk.
///
/// **Design (per the media-share master plan):**
///  * **Foreground, incremental, idempotent.** tvOS has no `BGProcessingTask` and
///    `BGAppRefreshTask` is far too small/short for a NAS walk, so scanning runs
///    while the app is foregrounded. A re-walk is safe: upserts preserve
///    `first_seen_at`, so "date added" stays first-discovery and only genuinely new
///    files get a fresh timestamp.
///  * **Bounded memory.** One directory at a time (explicit DFS stack), committing
///    that directory's files immediately — never the whole tree in memory.
///  * **Cancellation-safe.** On cancel mid-walk it stops without pruning, so a
///    partial pass can't wipe still-present content; the next scan resumes coverage.
///  * **Separate SMB session.** The lister here is backed by a *dedicated*
///    `SMBShareBrowser` (not the interactive one), so a scan doesn't starve live
///    folder browsing on the single-connection session.
///
/// The directory lister is injected so the walk is unit-testable with a fake tree.
actor ShareScanner {
    typealias Lister = @Sendable (_ relPath: String) async throws -> [SMBShareBrowser.Entry]

    private let store: ShareCatalogStore
    private let list: Lister
    private let shareID: String
    private let name: String
    private var reporter: ShareScanReporter
    private var isRunning = false

    /// Folder names whose subtree is skipped wholesale (extras/junk, not library
    /// content). Matched case-insensitively against a directory's own name.
    private static let excludedDirs: Set<String> = [
        "extras", "featurettes", "behind the scenes", "deleted scenes",
        "interviews", "scenes", "shorts", "trailers", "clips", "samples", "sample",
        "other", "subs", "subtitles", "@eadir", ".actors",
    ]

    init(store: ShareCatalogStore, shareID: String = "", name: String = "",
         reporter: ShareScanReporter = .noop, list: @escaping Lister) {
        self.store = store
        self.shareID = shareID
        self.name = name
        self.reporter = reporter
        self.list = list
    }

    /// Re-point progress reporting after creation, so a scanner built before the
    /// app wired its status reporter (a startup race) still drives the UI.
    func setReporter(_ reporter: ShareScanReporter) { self.reporter = reporter }

    /// Run a scan unless one already ran within `minInterval` (or is running).
    /// Called fire-and-forget from the Home hot path, so it must be cheap to no-op.
    func scanIfStale(minInterval: TimeInterval = 600) async {
        if isRunning { return }
        if let last = await store.meta("last_full_scan_at"),
           let ts = TimeInterval(last),
           Date().timeIntervalSince1970 - ts < minInterval {
            return
        }
        await scan()
    }

    /// Full depth-first walk from the share root. Idempotent.
    func scan() async {
        if isRunning { return }
        isRunning = true
        reporter.scanStarted(shareID, name)
        // Clears the "scanning" indicator even on cancel/early return, so the
        // Home banner never hangs.
        defer { isRunning = false; reporter.scanFinished(shareID) }

        let scanID = await nextScanID()
        PlozzLog.boot("share.scan begin scanID=\(scanID)")

        var stack: [String] = [""] // "" == share root
        var dirsWalked = 0
        var filesFound = 0

        while let dir = stack.popLast() {
            if Task.isCancelled {
                PlozzLog.boot("share.scan cancelled after \(dirsWalked) dirs, \(filesFound) files — no prune")
                return
            }
            let entries: [SMBShareBrowser.Entry]
            do {
                entries = try await list(dir)
            } catch {
                // A single failed directory shouldn't abort the whole scan; skip it.
                PlozzLog.boot("share.scan skip dir \(dir.isEmpty ? "<root>" : dir) (\(error))")
                continue
            }
            dirsWalked += 1

            var batch: [CatalogAsset] = []
            for entry in entries {
                let childPath = dir.isEmpty ? entry.name : "\(dir)/\(entry.name)"
                if entry.isDirectory {
                    if Self.excludedDirs.contains(entry.name.lowercased()) { continue }
                    stack.append(childPath)
                } else if ShareMediaParser.isVideoFile(entry.name), !Self.isSampleFile(entry.name) {
                    batch.append(Self.asset(relPath: childPath, entry: entry))
                }
            }
            if !batch.isEmpty {
                filesFound += batch.count
                await store.upsert(batch, scanID: scanID)
                reporter.scanProgress(shareID, filesFound)
            }
        }

        // Completed a full pass: drop assets no longer on the share, and stamp the
        // completion time so `scanIfStale` can throttle the next walk.
        await store.pruneNotSeen(inScan: scanID)
        await store.setMeta("last_full_scan_at", String(Date().timeIntervalSince1970))
        PlozzLog.boot("share.scan done scanID=\(scanID) dirs=\(dirsWalked) files=\(filesFound)")
    }

    // MARK: - Parse one file into a catalog asset

    static func asset(relPath: String, entry: SMBShareBrowser.Entry) -> CatalogAsset {
        let name = entry.name
        let seriesHint = seriesHintFolder(forRelPath: relPath)
        switch ShareMediaParser.classify(fileName: name, parentFolder: seriesHint) {
        case .movie(let movie):
            let title = movie.title.isEmpty ? displayTitle(forFileName: name) : movie.title
            return CatalogAsset(
                relPath: relPath, basename: name, size: Int64(entry.size),
                modifiedAt: entry.modifiedAt, kind: .movie, library: .movies,
                title: title, year: movie.year,
                seriesTitle: nil, seriesKey: nil, season: nil, episode: nil
            )
        case .episode(let ep):
            let library: CatalogLibrary = isAnimePath(relPath) ? .anime : .tv
            let fallback = "S\(ep.season)·E\(String(format: "%02d", ep.episode))"
            return CatalogAsset(
                relPath: relPath, basename: name, size: Int64(entry.size),
                modifiedAt: entry.modifiedAt, kind: .episode, library: library,
                title: ep.title ?? fallback, year: nil,
                seriesTitle: ep.series,
                seriesKey: ShareCatalogID.seriesKey(fromTitle: ep.series),
                season: ep.season, episode: ep.episode
            )
        }
    }

    // MARK: - Heuristics

    /// Best-effort anime detection at scan time: a path segment named "anime"
    /// (case-insensitive). Refined/corrected in Phase 2 once real ids resolve.
    static func isAnimePath(_ relPath: String) -> Bool {
        relPath.split(separator: "/").contains { seg in
            let s = seg.lowercased()
            return s == "anime" || s == "animes" || s == "anime tv" || s == "anime movies"
        }
    }

    /// A common `-sample`/`.sample` throwaway that shouldn't enter the library.
    static func isSampleFile(_ name: String) -> Bool {
        let stem = (name as NSString).deletingPathExtension.lowercased()
        return stem == "sample" || stem.hasSuffix("-sample") || stem.hasSuffix(".sample") || stem.hasSuffix(" sample")
    }

    /// The folder that best hints at a *series* title for an episode: normally the
    /// immediate parent, but hop over a "Season N" / "S03" folder to the show.
    /// Mirrors `ShareLibraryStore.seriesHintFolder`.
    static func seriesHintFolder(forRelPath relPath: String) -> String? {
        var dirs = relPath.split(separator: "/").map(String.init)
        guard dirs.count >= 2 else { return nil }
        dirs.removeLast()
        guard let parent = dirs.last else { return nil }
        if isSeasonFolder(parent), dirs.count >= 2 { return dirs[dirs.count - 2] }
        return parent
    }

    private static func isSeasonFolder(_ name: String) -> Bool {
        name.range(of: #"^[Ss]eason\s*\d+$"#, options: .regularExpression) != nil
            || name.range(of: #"^[Ss]\d{1,2}$"#, options: .regularExpression) != nil
    }

    private static func displayTitle(forFileName name: String) -> String {
        let base = (name as NSString).deletingPathExtension
        return base.isEmpty ? name : base
    }

    // MARK: - Scan id

    private func nextScanID() async -> Int64 {
        let current = Int64(await store.meta("scan_counter") ?? "0") ?? 0
        let next = current + 1
        await store.setMeta("scan_counter", String(next))
        return next
    }
}
