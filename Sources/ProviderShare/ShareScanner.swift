import Foundation
import CoreModels
import CoreNetworking
import MediaTransportCore

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
    typealias Lister = @Sendable (_ relPath: String) async throws -> [RemoteFileEntry]

    /// One pool slot: an independent directory lister + its teardown. In production
    /// each wraps a dedicated transport session (its own SMB connection); in tests a
    /// closure over a shared fake tree with a no-op close.
    struct ScanLister: Sendable {
        let list: Lister
        private let closer: ScanListerCloser

        init(
            list: @escaping Lister,
            close: @escaping @Sendable () async -> Void
        ) {
            self.list = list
            closer = ScanListerCloser(close: close)
        }

        func close() async {
            await closer.close()
        }
    }

    private actor ScanListerCloser {
        private let closeAction: @Sendable () async -> Void
        private var closeTask: Task<Void, Never>?

        init(close: @escaping @Sendable () async -> Void) {
            closeAction = close
        }

        func close() async {
            let task: Task<Void, Never>
            if let closeTask {
                task = closeTask
            } else {
                let closeAction = self.closeAction
                let created = Task.detached(priority: .utility) {
                    await closeAction()
                }
                closeTask = created
                task = created
            }
            await task.value
        }
    }

    private let store: ShareCatalogStore
    private let makeLister: @Sendable () -> ScanLister
    private let concurrency: Int
    private let pacer: ShareScanPacer
    private let shareID: String
    private let name: String
    private var reporter: ShareScanReporter
    private var isRunning = false
    private var isInvalidated = false
    private var activeListers: [ScanLister] = []

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
        self.init(
            store: store,
            shareID: shareID,
            name: name,
            reporter: reporter,
            concurrency: concurrency,
            pacer: ShareScanPacer(),
            makeLister: makeLister
        )
    }

    /// Test seam for deterministic pacing behavior; production uses `.shared`
    /// through the source-compatible initializer above.
    init(store: ShareCatalogStore, shareID: String = "", name: String = "",
         reporter: ShareScanReporter = .noop, concurrency: Int = 4,
         pacer: ShareScanPacer,
         makeLister: @escaping @Sendable () -> ScanLister) {
        self.store = store
        self.shareID = shareID
        self.name = name
        self.reporter = reporter
        self.concurrency = max(1, concurrency)
        self.pacer = pacer
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

    func invalidate() {
        isInvalidated = true
    }

    func forceCloseActiveListers() async {
        let listers = activeListers
        await withTaskGroup(of: Void.self) { group in
            for lister in listers {
                group.addTask {
                    await lister.close()
                }
            }
        }
    }

    /// Run a scan unless one already ran within `minInterval` (or is running).
    /// Called fire-and-forget from the Home hot path, so it must be cheap to no-op.
    @discardableResult
    func scanIfStale(minInterval: TimeInterval = 600) async -> ShareScanOutcome {
        if isRunning { return .freshNoOp }
        if isInvalidated { return .invalidated }
        // Force a walk (ignoring the staleness throttle) when the CLASSIFIER changed
        // since the last completed pass, so every already-indexed file is
        // reclassified under the new movie/episode rules right away instead of
        // waiting for it to change on disk (a re-walk re-upserts each file's kind/
        // library/keys). A cheap meta read on the hot path.
        let parserCurrent = String(ShareMediaParser.classifierVersion)
        let parserStored = await store.meta("parser_version")
        // Same idea for the SIDECAR/explicit-id inventory (Step 3): a version bump
        // here forces exactly one re-walk so an already-indexed share discovers
        // existing NFO files / backfills explicit ids without waiting for files to
        // change on disk — independent of the classifier and never forcing
        // external re-enrichment (no `enrich_version`/`ShareEnricher` touch).
        let localInventoryCurrent = String(ShareMediaParser.localInventoryVersion)
        let localInventoryStored = await store.meta("local_inventory_version")
        if parserStored == parserCurrent,
           localInventoryStored == localInventoryCurrent,
           let last = await store.meta("last_full_scan_at"),
           let ts = TimeInterval(last),
           Date().timeIntervalSince1970 - ts < minInterval {
            return .freshNoOp
        }
        return await scan()
    }

    /// Full breadth-first walk from the share root, using a pool of independent
    /// connections to list `concurrency` directories at once. Idempotent.
    @discardableResult
    func scan() async -> ShareScanOutcome {
        if isRunning { return .freshNoOp }
        if isInvalidated { return .invalidated }
        if Task.isCancelled { return .cancelled(scanGeneration: nil) }
        isRunning = true
        let scanGeneration = UUID()
        await store.activateScanGeneration(scanGeneration)
        let started = Date()
        reporter.scanStarted(shareID, name)

        guard !Task.isCancelled, !isInvalidated else {
            await finishScan(listers: [])
            return isInvalidated ? .invalidated : .cancelled(scanGeneration: scanGeneration)
        }

        // Pre-build the pool of independent listers (each its own SMB connection).
        // `pool` tracks EVERY lister we create (including ones swapped in to replace
        // a wedged connection) so all are torn down when the scan ends. Each close
        // runs in its own task so one hung teardown can't block the others.
        var pool = (0..<concurrency).map { _ in makeLister() }
        activeListers = pool
        // The live free-list of healthy connections, carried ACROSS BFS levels. Every
        // dispatched lister returns here exactly once per level (healthy back as-is; a
        // failed one replaced by a fresh connection), so at each level boundary it
        // holds exactly `concurrency` healthy listers.
        var free = pool

        guard let scanID = await store.nextScanID(for: scanGeneration),
              !isInvalidated else {
            await finishScan(listers: pool)
            return isInvalidated ? .invalidated : .failedToStart
        }
        PlozzLog.boot("share.scan begin scanID=\(scanID) concurrency=\(concurrency)")

        var frontier: [String] = [""] // "" == share root
        var dirsWalked = 0
        var filesFound = 0
        let progressClock = ContinuousClock()
        var lastProgressReport = progressClock.now
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
                await finishScan(listers: pool)
                return .cancelled(scanGeneration: scanGeneration)
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
                    guard !isInvalidated else {
                        group.cancelAll()
                        continue
                    }
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
                        activeListers.append(fresh)
                        free.append(fresh)
                    }
                    dirsWalked += 1
                    nextFrontier.append(contentsOf: result.subdirs)
                    if !result.assets.isEmpty {
                        filesFound += result.assets.count
                        await store.upsert(
                            result.assets,
                            scanID: scanID,
                            scanGeneration: scanGeneration
                        )
                    }
                    if !result.sidecars.isEmpty {
                        await store.upsertSidecars(
                            result.sidecars,
                            scanID: scanID,
                            scanGeneration: scanGeneration
                        )
                    }
                    let now = progressClock.now
                    if dirsWalked == 1
                        || lastProgressReport.duration(to: now) >= .milliseconds(250) {
                        reporter.scanDetailedProgress(shareID, dirsWalked, filesFound)
                        lastProgressReport = now
                    }
                    if Task.isCancelled { continue }   // stop dispatching; let in-flight drain
                    // Never pause for browsing (which could starve a scan forever).
                    // Instead, admit replacement directory requests at a bounded
                    // slower rate while the user is actively navigating the share.
                    if index < frontier.count {
                        await pacer.paceIfBrowsing()
                        spawnNext()
                    }
                }
            }

            if Task.isCancelled || isInvalidated {
                PlozzLog.boot("share.scan cancelled after \(dirsWalked) dirs, \(filesFound) files — no prune")
                await finishScan(listers: pool)
                return isInvalidated ? .invalidated : .cancelled(scanGeneration: scanGeneration)
            }
            frontier = nextFrontier
        }
        reporter.scanDetailedProgress(shareID, dirsWalked, filesFound)

        // Completed a full pass. Only prune (drop assets no longer on the share) when
        // EVERY directory listed cleanly — a partial walk (some listing failed) must
        // not delete content that's merely temporarily unreachable. Still stamp the
        // completion time either way so `scanIfStale` throttles the next walk (a
        // permanently-inaccessible folder can't cause a perpetual re-scan); the next
        // clean pass performs the deferred prune.
        guard !isInvalidated else {
            await finishScan(listers: pool)
            return .invalidated
        }
        if !anyListingFailed {
            await store.preserveMovieAliasesBeforePrune(scanGeneration: scanGeneration)
            guard !isInvalidated else {
                await finishScan(listers: pool)
                return .invalidated
            }
            await store.pruneNotSeen(inScan: scanID, scanGeneration: scanGeneration)
            guard !isInvalidated else {
                await finishScan(listers: pool)
                return .invalidated
            }
            await store.pruneSidecarsNotSeen(inScan: scanID, scanGeneration: scanGeneration)
            guard !isInvalidated else {
                await finishScan(listers: pool)
                return .invalidated
            }
            await store.rebuildMovieGroups(scanGeneration: scanGeneration)
            await store.reconcileSidecarAssociations(scanGeneration: scanGeneration)
        }
        guard !isInvalidated else {
            await finishScan(listers: pool)
            return .invalidated
        }
        // Filename/folder explicit ids are pure path computation (already
        // persisted on the asset row) — materialize them into the same
        // `metadata_values` priority projection NFO ids use, every scan
        // (clean or partial), since nothing here depends on the prune above.
        await store.materializeFilenameProviderIDs(scanGeneration: scanGeneration)
        await store.setMeta(
            "last_full_scan_at",
            String(Date().timeIntervalSince1970),
            scanGeneration: scanGeneration
        )
        // Record the classifier the catalog was built with, so `scanIfStale` only
        // force-reparses once per classifier bump (and doesn't perpetually re-walk).
        await store.setMeta(
            "parser_version",
            String(ShareMediaParser.classifierVersion),
            scanGeneration: scanGeneration
        )
        await store.setMeta(
            "local_inventory_version",
            String(ShareMediaParser.localInventoryVersion),
            scanGeneration: scanGeneration
        )
        PlozzLog.boot(
            "share.scan done scanID=\(scanID) dirs=\(dirsWalked) files=\(filesFound) pruned=\(!anyListingFailed) elapsed=\(Int(Date().timeIntervalSince(started) * 1_000))ms"
        )
        await finishScan(listers: pool)
        // A completed pass earns a completion stamp. When some listing failed the pass
        // stayed unpruned (partial), but it is still a *completed* pass under the
        // approved partial throttle — the coordinator distinguishes this from a
        // cancelled/superseded pass via the explicit outcome.
        return anyListingFailed ? .completedPartial : .completedClean
    }

    private func finishScan(listers: [ScanLister]) async {
        await withTaskGroup(of: Void.self) { group in
            for lister in listers {
                group.addTask {
                    await lister.close()
                }
            }
        }
        activeListers = []
        isRunning = false
        reporter.scanFinished(shareID)
    }

    /// Result of listing one directory: the connection it used (returned to the
    /// pool), the sub-directories discovered, the playable assets parsed, the NFO
    /// sidecar candidates discovered (pure filename/sibling-stem facts — no read),
    /// and whether the listing actually succeeded (a failed listing must not let
    /// the walk treat the folder as "empty" and prune its still-present content).
    private struct DirResult: Sendable {
        let lister: ScanLister
        let subdirs: [String]
        let assets: [CatalogAsset]
        let sidecars: [LocalSidecarCandidate]
        let ok: Bool
    }

    /// List + classify one directory off the actor (pure I/O + parsing, no shared
    /// state), so the pooled listings run truly in parallel. A per-directory error
    /// is swallowed to an empty result (so one bad folder never aborts the walk) but
    /// is flagged `ok: false` so the caller can skip the global prune.
    private static func processDirectory(_ dir: String, using lister: ScanLister) async -> DirResult {
        let entries: [RemoteFileEntry]
        do {
            ShareBackgroundActivity.listStarted()
            defer { ShareBackgroundActivity.listFinished() }
            entries = try await lister.list(dir)
        } catch {
            PlozzLog.boot("share.scan skip dir \(dir.isEmpty ? "<root>" : dir) (\(error))")
            return DirResult(lister: lister, subdirs: [], assets: [], sidecars: [], ok: false)
        }
        var subdirs: [String] = []
        var assets: [CatalogAsset] = []
        // Video stems discovered in THIS SAME listing, bucketed by classified
        // kind, so a sibling `.nfo`'s stem can be matched against a movie vs an
        // episode file without any extra read — a pure by-product of the assets
        // loop below (still listing-only: no `stat`/`readSmallFile`/XML parsing).
        var movieStemsLower: Set<String> = []
        var episodeStemsLower: Set<String> = []
        var stemToVideoRelPath: [String: String] = [:]
        var nfoEntries: [(entry: RemoteFileEntry, childPath: String)] = []
        for entry in entries {
            let childPath = dir.isEmpty ? entry.name : "\(dir)/\(entry.name)"
            if entry.kind == .directory {
                if excludedDirs.contains(entry.name.lowercased()) { continue }
                subdirs.append(childPath)
            } else if ShareMediaParser.isVideoFile(entry.name), !isSampleFile(entry.name) {
                let parsed = asset(relPath: childPath, entry: entry)
                let stem = ShareMediaParser.videoStem(entry.name).lowercased()
                switch parsed.kind {
                case .movie: movieStemsLower.insert(stem)
                case .episode: episodeStemsLower.insert(stem)
                }
                stemToVideoRelPath[stem] = childPath
                assets.append(parsed)
            } else if isNFOFile(entry.name) {
                nfoEntries.append((entry, childPath))
            }
        }

        var sidecars: [LocalSidecarCandidate] = []
        for (entry, childPath) in nfoEntries {
            let lowerName = entry.name.lowercased()
            let kind: LocalSidecarKind
            var associatedVideo: String?
            if lowerName == "movie.nfo" {
                kind = .movieGeneric
            } else if lowerName == "tvshow.nfo" {
                kind = .series
            } else {
                let stem = ShareMediaParser.videoStem(entry.name).lowercased()
                if movieStemsLower.contains(stem) {
                    kind = .movieStem
                    associatedVideo = stemToVideoRelPath[stem]
                } else if episodeStemsLower.contains(stem) {
                    kind = .episodeStem
                    associatedVideo = stemToVideoRelPath[stem]
                } else {
                    continue // Not a supported sidecar name/position — ignored.
                }
            }
            sidecars.append(LocalSidecarCandidate(
                relPath: childPath, parentDir: dir, basename: entry.name, kind: kind,
                size: entry.size ?? 0, modifiedAt: entry.modifiedAt ?? .distantPast,
                stableFileID: entry.stableFileID, strongETag: entry.strongETag,
                changeToken: entry.changeToken, associatedVideoRelPath: associatedVideo
            ))
        }

        return DirResult(lister: lister, subdirs: subdirs, assets: assets, sidecars: sidecars, ok: true)
    }

    /// A supported NFO sidecar filename (any casing).
    private static func isNFOFile(_ name: String) -> Bool {
        (name as NSString).pathExtension.caseInsensitiveCompare("nfo") == .orderedSame
    }

    // MARK: - Parse one file into a catalog asset

    static func asset(relPath: String, entry: RemoteFileEntry) -> CatalogAsset {
        let name = entry.name
        let explicitIDs = ShareMediaParser.embeddedProviderIDs(relPath: relPath)
        switch ShareMediaParser.classify(relPath: relPath) {
        case .movie(let movie):
            let title = movie.title.isEmpty ? displayTitle(forFileName: name) : movie.title
            let g = ShareMediaParser.movieGrouping(relPath: relPath, parsedTitle: title, parsedYear: movie.year)
            var movieKey = ShareCatalogID.movieKey(fromTitle: g.title, year: g.year)
            var movieTitleKey = ShareCatalogID.seriesKey(fromTitle: g.title)
            if let part = g.part {
                movieKey += "-\(part)"
                movieTitleKey += "-\(part)"
            }
            return CatalogAsset(
                relPath: relPath, basename: name, size: entry.size ?? 0,
                modifiedAt: entry.modifiedAt ?? .distantPast, kind: .movie, library: .movies,
                title: g.title, year: g.year,
                seriesTitle: nil, seriesKey: nil, season: nil, episode: nil,
                movieKey: movieKey, movieTitleKey: movieTitleKey,
                explicitProviderIDs: explicitIDs, metadataRoot: nil
            )
        case .episode(let ep):
            let library: CatalogLibrary = isAnimePath(relPath) ? .anime : .tv
            let fallback = "S\(ep.season)·E\(String(format: "%02d", ep.episode))"
            return CatalogAsset(
                relPath: relPath, basename: name, size: entry.size ?? 0,
                modifiedAt: entry.modifiedAt ?? .distantPast, kind: .episode, library: library,
                title: ep.title ?? fallback, year: ep.year,
                seriesTitle: ep.series,
                seriesKey: ShareCatalogID.seriesKey(fromTitle: ep.series, providerTag: ep.providerTag),
                season: ep.season, episode: ep.episode,
                movieKey: nil, movieTitleKey: nil,
                explicitProviderIDs: explicitIDs, metadataRoot: seriesMetadataRoot(relPath: relPath)
            )
        }
    }

    /// The authoritative SHOW FOLDER's full relative path (root-first ancestors
    /// joined up to and including the folder `ShareMediaParser.classify` proved
    /// names the series) — where a `tvshow.nfo` sidecar would live. `nil` when the
    /// folder tree doesn't prove a show folder (mirrors `authoritativeShowFolder`,
    /// so this stays consistent with which folder GROUPING already trusts).
    static func seriesMetadataRoot(relPath: String) -> String? {
        let comps = relPath.split(separator: "/").map(String.init)
        guard comps.count > 1 else { return nil }
        let ancestors = Array(comps.dropLast())
        guard let showFolder = ShareMediaParser.authoritativeShowFolder(fromAncestors: ancestors),
              let idx = ancestors.lastIndex(of: showFolder) else { return nil }
        return ancestors[0...idx].joined(separator: "/")
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

}

/// Bounded scan admission control shared by interactive ShareProvider requests
/// and the background scanner. Recent navigation adds a small delay before each
/// replacement directory request; continuous navigation still makes guaranteed
/// progress because the delay is fixed rather than waiting for an idle window.
actor ShareScanPacer {
    private let activeWindow: Duration
    private let activeDelay: Duration
    private let clock = ContinuousClock()
    private var lastInteractiveActivity: ContinuousClock.Instant?

    init(activeWindow: Duration = .seconds(1), activeDelay: Duration = .milliseconds(60)) {
        self.activeWindow = activeWindow
        self.activeDelay = activeDelay
    }

    func noteInteractiveActivity() {
        lastInteractiveActivity = clock.now
    }

    @discardableResult
    func paceIfBrowsing() async -> Bool {
        guard let lastInteractiveActivity,
              lastInteractiveActivity.duration(to: clock.now) < activeWindow else { return false }
        try? await Task.sleep(for: activeDelay)
        return true
    }
}
