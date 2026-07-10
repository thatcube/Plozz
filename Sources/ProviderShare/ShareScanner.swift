import Foundation
import CoreModels
import CoreNetworking

/// Walks a share's directory tree and populates a `ShareCatalogStore`, so the
/// share can serve Recently Added / Search / indexed libraries without a live walk.
///
/// **Design (per the media-share master plan + SMB-perf research):**
///  * **Parallel, pooled walk.** The `thatcube/SMBClient` library is strictly
///    serial per connection (one in-flight request per `Connection` semaphore), so
///    the ONLY way to parallelise is multiple independent connections. The scanner
///    runs a pool of `concurrency` independent listers (each its own SMB
///    connection) over a **level-by-level BFS** — media trees are wide at the
///    show/season/file levels, so a small pool (default 4) yields ~Nx throughput.
///  * **Foreground, incremental, idempotent.** tvOS has no `BGProcessingTask`, so
///    scanning runs while foregrounded. A re-walk is safe: upserts preserve
///    `first_seen_at`, so "date added" stays first-discovery.
///  * **Bounded memory.** Only the current BFS level's directory listings are held
///    (a few MB at most); each directory's files are committed immediately.
///  * **Cancellation-safe.** On cancel mid-walk it stops without pruning, so a
///    partial pass can't wipe still-present content; the next scan resumes coverage.
///  * **Separate SMB connections.** The pool's listers are dedicated to scanning
///    (not the interactive browser), so a walk never starves live folder browsing.
///
/// The lister *factory* is injected so the walk is unit-testable with a fake tree
/// (each pool slot gets its own lister; fakes can share a concurrency-safe tree).
actor ShareScanner {
    typealias Lister = @Sendable (_ relPath: String) async throws -> [SMBShareBrowser.Entry]

    /// One pool slot: an independent directory lister + its teardown. In production
    /// each wraps a dedicated `SMBShareBrowser` (its own SMB connection); in tests a
    /// closure over a shared fake tree with a no-op close.
    struct ScanLister: Sendable {
        let list: Lister
        let close: @Sendable () async -> Void
    }

    private let store: ShareCatalogStore
    private let makeLister: @Sendable () -> ScanLister
    private let concurrency: Int
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
         reporter: ShareScanReporter = .noop, concurrency: Int = 4,
         makeLister: @escaping @Sendable () -> ScanLister) {
        self.store = store
        self.shareID = shareID
        self.name = name
        self.reporter = reporter
        self.concurrency = max(1, concurrency)
        self.makeLister = makeLister
    }

    /// Re-point progress reporting after creation, so a scanner built before the
    /// app wired its status reporter (a startup race) still drives the UI. If a scan
    /// is already in flight, replay `scanStarted` so the new reporter learns of it
    /// (its `scanStarted` went to the previous `.noop` reporter and would otherwise
    /// leave later progress/finish events with no state to update).
    func setReporter(_ reporter: ShareScanReporter) {
        self.reporter = reporter
        if isRunning { reporter.scanStarted(shareID, name) }
    }

    /// Run a scan unless one already ran within `minInterval` (or is running).
    /// Called fire-and-forget from the Home hot path, so it must be cheap to no-op.
    func scanIfStale(minInterval: TimeInterval = 600) async {
        if isRunning { return }
        // Force a walk (ignoring the staleness throttle) when the CLASSIFIER changed
        // since the last completed pass, so every already-indexed file is
        // reclassified under the new movie/episode rules right away instead of
        // waiting for it to change on disk (a re-walk re-upserts each file's kind/
        // library/keys). A cheap meta read on the hot path.
        let parserCurrent = String(ShareMediaParser.classifierVersion)
        let parserStored = await store.meta("parser_version")
        if parserStored == parserCurrent,
           let last = await store.meta("last_full_scan_at"),
           let ts = TimeInterval(last),
           Date().timeIntervalSince1970 - ts < minInterval {
            return
        }
        await scan()
    }

    /// Full breadth-first walk from the share root, using a pool of independent
    /// connections to list `concurrency` directories at once. Idempotent.
    func scan() async {
        if isRunning { return }
        isRunning = true
        reporter.scanStarted(shareID, name)

        // Pre-build the pool of independent listers (each its own SMB connection).
        // `pool` tracks EVERY lister we create (including ones swapped in to replace
        // a wedged connection) so all are torn down when the scan ends. Each close
        // runs in its own task so one hung teardown can't block the others.
        var pool = (0..<concurrency).map { _ in makeLister() }
        // The live free-list of healthy connections, carried ACROSS BFS levels. Every
        // dispatched lister returns here exactly once per level (healthy back as-is; a
        // failed one replaced by a fresh connection), so at each level boundary it
        // holds exactly `concurrency` healthy listers.
        var free = pool
        defer {
            isRunning = false
            reporter.scanFinished(shareID)
            let toClose = pool
            Task { for lister in toClose { Task { await lister.close() } } }
        }

        let scanID = await nextScanID()
        PlozzLog.boot("share.scan begin scanID=\(scanID) concurrency=\(concurrency)")

        var frontier: [String] = [""] // "" == share root
        var dirsWalked = 0
        var filesFound = 0
        // Set if ANY directory listing failed this pass (transient SMB timeout, auth
        // hiccup, permission-denied folder). A failed listing looks like an empty
        // folder, so pruning on a partial walk would delete still-present content and
        // reset its "date added" on rediscovery — skip the prune when this is set.
        var anyListingFailed = false

        // Level-by-level BFS. Each level's directories are listed in parallel across
        // the pool; a plain free-list of listers (managed here on the actor) bounds
        // concurrency to the pool size with no locks/continuations.
        while !frontier.isEmpty {
            if Task.isCancelled {
                PlozzLog.boot("share.scan cancelled after \(dirsWalked) dirs, \(filesFound) files — no prune")
                return
            }
            var nextFrontier: [String] = []
            var index = 0                         // next directory in `frontier` to dispatch

            await withTaskGroup(of: DirResult.self) { group in
                func spawnNext() {
                    guard index < frontier.count, let lister = free.popLast() else { return }
                    let dir = frontier[index]
                    index += 1
                    group.addTask { await Self.processDirectory(dir, using: lister) }
                }
                // Fill the pool.
                for _ in 0..<concurrency { spawnNext() }
                // Drain results, committing each directory and launching the next.
                while let result = await group.next() {
                    if result.ok {
                        free.append(result.lister)     // healthy — return it to the pool
                    } else {
                        // A failed listing likely left this connection WEDGED: the SMB
                        // library doesn't honour cancellation mid-read, so a timed-out
                        // read keeps holding the connection's lock and every later list
                        // on it also times out (20s each) — one bad socket crawls the
                        // whole walk and it looks stuck. Discard it (fire-and-forget
                        // close, since that may hang too) and swap in a FRESH
                        // connection so throughput recovers immediately.
                        anyListingFailed = true
                        let dead = result.lister
                        Task { await dead.close() }
                        let fresh = makeLister()
                        pool.append(fresh)
                        free.append(fresh)
                    }
                    dirsWalked += 1
                    nextFrontier.append(contentsOf: result.subdirs)
                    if !result.assets.isEmpty {
                        filesFound += result.assets.count
                        await store.upsert(result.assets, scanID: scanID)
                        reporter.scanProgress(shareID, filesFound)
                    }
                    if Task.isCancelled { continue }   // stop dispatching; let in-flight drain
                    spawnNext()
                }
            }
            if Task.isCancelled {
                PlozzLog.boot("share.scan cancelled after \(dirsWalked) dirs, \(filesFound) files — no prune")
                return
            }
            frontier = nextFrontier
        }

        // Completed a full pass. Only prune (drop assets no longer on the share) when
        // EVERY directory listed cleanly — a partial walk (some listing failed) must
        // not delete content that's merely temporarily unreachable. Still stamp the
        // completion time either way so `scanIfStale` throttles the next walk (a
        // permanently-inaccessible folder can't cause a perpetual re-scan); the next
        // clean pass performs the deferred prune.
        if !anyListingFailed {
            await store.pruneNotSeen(inScan: scanID)
        }
        await store.setMeta("last_full_scan_at", String(Date().timeIntervalSince1970))
        // Record the classifier the catalog was built with, so `scanIfStale` only
        // force-reparses once per classifier bump (and doesn't perpetually re-walk).
        await store.setMeta("parser_version", String(ShareMediaParser.classifierVersion))
        PlozzLog.boot("share.scan done scanID=\(scanID) dirs=\(dirsWalked) files=\(filesFound) pruned=\(!anyListingFailed)")
    }

    /// Result of listing one directory: the connection it used (returned to the
    /// pool), the sub-directories discovered, the playable assets parsed, and
    /// whether the listing actually succeeded (a failed listing must not let the
    /// walk treat the folder as "empty" and prune its still-present content).
    private struct DirResult: Sendable {
        let lister: ScanLister
        let subdirs: [String]
        let assets: [CatalogAsset]
        let ok: Bool
    }

    /// List + classify one directory off the actor (pure I/O + parsing, no shared
    /// state), so the pooled listings run truly in parallel. A per-directory error
    /// is swallowed to an empty result (so one bad folder never aborts the walk) but
    /// is flagged `ok: false` so the caller can skip the global prune.
    private static func processDirectory(_ dir: String, using lister: ScanLister) async -> DirResult {
        let entries: [SMBShareBrowser.Entry]
        do {
            entries = try await lister.list(dir)
        } catch {
            PlozzLog.boot("share.scan skip dir \(dir.isEmpty ? "<root>" : dir) (\(error))")
            return DirResult(lister: lister, subdirs: [], assets: [], ok: false)
        }
        var subdirs: [String] = []
        var assets: [CatalogAsset] = []
        for entry in entries {
            let childPath = dir.isEmpty ? entry.name : "\(dir)/\(entry.name)"
            if entry.isDirectory {
                if excludedDirs.contains(entry.name.lowercased()) { continue }
                subdirs.append(childPath)
            } else if ShareMediaParser.isVideoFile(entry.name), !isSampleFile(entry.name) {
                assets.append(asset(relPath: childPath, entry: entry))
            }
        }
        return DirResult(lister: lister, subdirs: subdirs, assets: assets, ok: true)
    }

    // MARK: - Parse one file into a catalog asset

    static func asset(relPath: String, entry: SMBShareBrowser.Entry) -> CatalogAsset {
        let name = entry.name
        switch ShareMediaParser.classify(relPath: relPath) {
        case .movie(let movie):
            let title = movie.title.isEmpty ? displayTitle(forFileName: name) : movie.title
            let g = ShareMediaParser.movieGrouping(relPath: relPath, parsedTitle: title, parsedYear: movie.year)
            var movieKey = ShareCatalogID.movieKey(fromTitle: g.title, year: g.year)
            if let part = g.part { movieKey += "-\(part)" }
            return CatalogAsset(
                relPath: relPath, basename: name, size: Int64(entry.size),
                modifiedAt: entry.modifiedAt, kind: .movie, library: .movies,
                title: title, year: movie.year,
                seriesTitle: nil, seriesKey: nil, season: nil, episode: nil,
                movieKey: movieKey
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
                season: ep.season, episode: ep.episode,
                movieKey: nil
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
