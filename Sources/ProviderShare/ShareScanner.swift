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
        // Sidecar/artwork folders are re-verified on a long cadence rather than
        // every pass — see `directoriesNeedingRelist`. A share that has never
        // completed one is treated as due, so the first pass after upgrading is
        // deep and the incremental state it leaves behind is complete.
        let lastDeep = await store.meta("last_deep_scan_at").flatMap(TimeInterval.init)
        let deep = lastDeep.map {
            Date().timeIntervalSince1970 - $0 >= Self.deepScanInterval
        } ?? true
        return await scan(deep: deep)
    }

    /// How often the sidecar/artwork re-verification pass runs.
    ///
    /// This is the cadence at which an NFO edited in place, or a poster deleted
    /// without its folder's mtime moving, is noticed. Daily rather than every ten
    /// minutes: those are hand edits on a library the viewer is not usually
    /// watching at the same moment, and the old cadence re-listed essentially
    /// every leaf folder 144 times a day to catch them.
    static let deepScanInterval: TimeInterval = 24 * 60 * 60

    /// Parent directories of `paths` — i.e. every directory known to contain a
    /// subdirectory. A top-level entry's parent is the root, `""`.
    static func parentPaths(of paths: some Sequence<String>) -> Set<String> {
        var out: Set<String> = []
        for path in paths where !path.isEmpty {
            if let slash = path.lastIndex(of: "/") {
                out.insert(String(path[path.startIndex..<slash]))
            } else {
                out.insert("")
            }
        }
        return out
    }

    /// How close to "now" a directory mtime may be and still be trusted for
    /// skipping on a later pass.
    ///
    /// The racy-timestamp problem, and the same one git solves for its index: a
    /// file added in the *same second* the scan reads the directory leaves an
    /// mtime equal to the one recorded, so the directory would look unchanged
    /// forever after. Many filesystems and every SMB/NFS server in practice have
    /// one-second resolution, so the window has to cover a whole tick plus skew.
    static let racyMTimeWindow: TimeInterval = 2

    /// The mtime to persist, or `nil` when it is too fresh to be trusted.
    ///
    /// Recording `nil` costs one listing of that directory on the next pass —
    /// there is no stored mtime to compare against, so it can't be skipped —
    /// which is exactly the conservative outcome wanted, and it self-corrects on
    /// the pass after.
    static func trustworthyMTime(_ mtime: Date?, now: Date = Date()) -> Date? {
        guard let mtime else { return nil }
        return now.timeIntervalSince(mtime) >= racyMTimeWindow ? mtime : nil
    }

    /// Full breadth-first walk from the share root, using a pool of independent
    /// connections to list `concurrency` directories at once. Idempotent.
    @discardableResult
    func scan(deep: Bool = true) async -> ShareScanOutcome {
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

        // Resume an interrupted pass rather than re-walking from the root.
        //
        // CRITICAL: a resume reuses the interrupted pass's scanID. Everything the
        // earlier pass upserted carries that id, and the prune deletes rows whose
        // `last_scan` differs — so allocating a fresh id here would make the
        // completed portion look vanished and delete it. Reusing the id also makes
        // the union of both passes a complete walk, which is exactly what the
        // prune requires to be correct.
        let resumeState = await Self.loadResumeState(store: store)
        let scanID: Int64
        var frontier: [String]
        if let resumeState {
            scanID = resumeState.scanID
            frontier = resumeState.frontier
            PlozzLog.boot(
                "share.scan resume scanID=\(scanID) pending=\(frontier.count) concurrency=\(concurrency)"
            )
        } else {
            guard let fresh = await store.nextScanID(for: scanGeneration), !isInvalidated else {
                await finishScan(listers: pool)
                return isInvalidated ? .invalidated : .failedToStart
            }
            scanID = fresh
            frontier = [""] // "" == share root
            PlozzLog.boot("share.scan begin scanID=\(scanID) concurrency=\(concurrency)")
        }
        guard !isInvalidated else {
            await finishScan(listers: pool)
            return .invalidated
        }
        // Incremental scan state: a directory whose mtime is unchanged since the
        // last scan doesn't need listing. Loaded once for the whole walk.
        let storedDirectoryMTimes = await store.directoryModifiedTimes()
        // Directories known to CONTAIN a subdirectory, derived from the recorded
        // paths rather than queried per-child.
        //
        // Load-bearing for the skip rule below, and the reason it isn't simply
        // "unchanged ⇒ skip". One listing returns every child *with its mtime*,
        // so listing a parent is what makes skipping all of its children
        // possible. Skipping the parent instead forfeits that: its children's
        // fresh mtimes are unobtainable, so every one of them has to be listed.
        // For a series folder with ten seasons, skipping saved one listing and
        // forced ten — the optimization ran backwards on every interior node.
        let directoriesWithSubdirectories = Self.parentPaths(of: storedDirectoryMTimes.keys)
        // Sidecar/artwork folders are re-listed on a DEEP pass only.
        //
        // They can't be skipped on mtime alone (an NFO edited in place doesn't
        // move its directory's mtime, and a deleted poster is only observable by
        // listing), but that guarantee was being bought on every ordinary pass —
        // and since a well-kept library has a poster or NFO in essentially every
        // leaf folder, it exempted exactly the folders the skip exists for. The
        // guarantee is kept, just paid for once a day instead of every ten
        // minutes.
        let directoriesNeedingRelist = deep ? await store.directoriesRequiringRelist() : []
        // mtime each directory was reported with by its parent's listing, so the
        // value recorded for a folder is the one a later scan will compare against.
        var listedDirectoryMTimes: [String: Date?] = [:]
        var dirsWalked = 0
        var dirsSkipped = 0
        var filesFound = 0
        let progressClock = ContinuousClock()
        var lastProgressReport = progressClock.now
        // Set if ANY directory listing failed this pass (transient SMB timeout, auth
        // hiccup, permission-denied folder). A failed listing looks like an empty
        // folder, so pruning on a partial walk would delete still-present content and
        // reset its "date added" on rediscovery — skip the prune when this is set.
        var anyListingFailed = false
        // PATH-FREE aggregate of listing failures by bounded category (C3): no dir/
        // basename/error text is ever recorded — only per-category counts, logged once.
        var listFailureCounts: [ShareScanListFailureCategory: Int] = [:]

        // Level-by-level BFS. Each level's directories are listed in parallel across
        // the pool; a plain free-list of listers (managed here on the actor) bounds
        // concurrency to the pool size with no locks/continuations.
        while !frontier.isEmpty {
            if Task.isCancelled {
                await Self.saveResumeState(
                    store: store, scanID: scanID, frontier: frontier,
                    scanGeneration: scanGeneration
                )
                PlozzLog.boot(
                    "share.scan cancelled after \(dirsWalked) dirs, \(filesFound) files — "
                        + "no prune, \(frontier.count) dir(s) saved to resume"
                )
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
                        listFailureCounts[result.failureCategory ?? .other, default: 0] += 1
                        let dead = result.lister
                        Task { await dead.close() }
                        let fresh = makeLister()
                        pool.append(fresh)
                        activeListers.append(fresh)
                        free.append(fresh)
                    }
                    dirsWalked += 1
                    if result.ok {
                        await store.recordDirectory(
                            relPath: result.dir,
                            modifiedAt: Self.trustworthyMTime(
                                listedDirectoryMTimes[result.dir] ?? nil
                            ),
                            scanID: scanID,
                            scanGeneration: scanGeneration
                        )
                    }
                    // Split this directory's children: an unchanged one keeps its
                    // recorded contents (stamped so the prune spares them) and is
                    // NOT listed, but we still descend into ITS children — a
                    // directory's mtime says nothing about deeper changes.
                    for child in result.subdirectories {
                        listedDirectoryMTimes[child.relPath] = child.modifiedAt
                        if let mtime = child.modifiedAt,
                           let known = storedDirectoryMTimes[child.relPath],
                           known == mtime,
                           // Leaves only. A directory with children must be
                           // listed even when unchanged, because that single
                           // listing is what yields their mtimes and lets the
                           // whole level below be skipped.
                           !directoriesWithSubdirectories.contains(child.relPath),
                           !directoriesNeedingRelist.contains(child.relPath) {
                            dirsSkipped += 1
                            await store.touchDirectoryContents(
                                relPath: child.relPath,
                                scanID: scanID,
                                scanGeneration: scanGeneration
                            )
                            nextFrontier.append(
                                contentsOf: await store.recordedSubdirectories(of: child.relPath)
                            )
                        } else {
                            nextFrontier.append(child.relPath)
                        }
                    }
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
                    if !result.artwork.isEmpty {
                        await store.upsertArtwork(
                            result.artwork,
                            scanID: scanID,
                            scanGeneration: scanGeneration
                        )
                    }
                    let now = progressClock.now
                    if dirsWalked == 1
                        || lastProgressReport.duration(to: now) >= .milliseconds(250) {
                        // Everything still queued: this level's undispatched tail
                        // plus the children discovered so far. Walked vs walked +
                        // pending is the walk's REAL completion — the frontier is
                        // the only honest denominator a breadth-first walk has
                        // (the tree's size isn't knowable until it's walked).
                        let pending = (frontier.count - index) + nextFrontier.count
                        reporter.scanFrontierProgress(
                            shareID, dirsWalked, max(0, pending), filesFound
                        )
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
                // Everything still unwalked: this level's undispatched tail plus the
                // children discovered so far. Directories already listed keep their
                // rows stamped with `scanID`, so they simply aren't revisited.
                let pending = Array(frontier[min(index, frontier.count)...]) + nextFrontier
                await Self.saveResumeState(
                    store: store, scanID: scanID, frontier: pending,
                    scanGeneration: scanGeneration
                )
                PlozzLog.boot(
                    "share.scan cancelled after \(dirsWalked) dirs, \(filesFound) files — "
                        + "no prune, \(pending.count) dir(s) saved to resume"
                )
                await finishScan(listers: pool)
                return isInvalidated ? .invalidated : .cancelled(scanGeneration: scanGeneration)
            }
            frontier = nextFrontier
            // Checkpoint at every level boundary, not only on graceful
            // cancellation: an app that is force-quit, crashes, or is suspended and
            // reclaimed by iOS never runs the cancellation path at all — which is
            // the common way a scan dies on a phone. One small meta write per BFS
            // level is cheap against a walk measured in minutes.
            await Self.saveResumeState(
                store: store, scanID: scanID, frontier: frontier,
                scanGeneration: scanGeneration
            )
        }
        reporter.scanFrontierProgress(shareID, dirsWalked, 0, filesFound)

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
            // Clean full pass: prune vanished assets AND every orphan row they
            // leave behind (enrichment/metadata_values/state, sidecar inventory +
            // value cache, dead aliases/merges), regroup movies, recompute sidecar
            // associations, and rematerialize local + filename projections — all in
            // ONE atomic transaction. After commit no readable item can resurrect a
            // deleted item's ids/artwork/metadata/state on path/series-key reuse.
            await store.pruneDirectoryStateNotSeen(
                inScan: scanID, scanGeneration: scanGeneration
            )
            // Only NOW is this scan's directory state safe to skip against: the
            // pass completed, so every recorded directory had its full subtree
            // walked. A partial pass's rows are never trusted.
            await store.markDirectoryStateComplete(
                scanID: scanID, scanGeneration: scanGeneration
            )
            let finalized = await store.finalizeCleanScan(
                inScan: scanID,
                scanGeneration: scanGeneration
            )
            guard !isInvalidated else {
                await finishScan(listers: pool)
                return .invalidated
            }
            if !finalized {
                // Superseded generation or a rolled-back SQLite failure: the clean
                // transaction made NO change (no partial prune — invariant 9). Still
                // refresh the pure path-derived filename/explicit ids so they stay
                // current; orphan cleanup is deferred to the next clean pass.
                await store.materializeFilenameProviderIDs(scanGeneration: scanGeneration)
            }
        } else {
            // Partial walk: never prune/reconcile. Still refresh pure path-derived
            // filename/folder explicit ids (already persisted on the asset row and
            // independent of the deferred prune) into the same `metadata_values`
            // priority projection NFO ids use.
            guard !isInvalidated else {
                await finishScan(listers: pool)
                return .invalidated
            }
            await store.materializeFilenameProviderIDs(scanGeneration: scanGeneration)
        }
        // The walk finished: no partial state to carry forward.
        await Self.clearResumeState(store: store, scanGeneration: scanGeneration)
        await store.setMeta(
            "last_full_scan_at",
            String(Date().timeIntervalSince1970),
            scanGeneration: scanGeneration
        )
        // Only a deep pass may stamp this: an ordinary pass skipped the sidecar
        // folders, so it cannot claim to have re-verified them.
        if deep {
            await store.setMeta(
                "last_deep_scan_at",
                String(Date().timeIntervalSince1970),
                scanGeneration: scanGeneration
            )
        }
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
        // One-time reread after an NFO PARSER-RULE upgrade (root-gated episode fields,
        // strict date rejection): mark already-processed sidecars whose stored
        // parser_version predates the current parser as pending so the local enricher
        // reparses each existing NFO once under the corrected rules. The UPDATE is
        // table-wide and idempotent; a meta gate keeps it to one pass per bump. Never
        // touches external/local-materialization version or forces a resolver call.
        let nfoParserCurrent = String(ShareNFOParser.parserVersion)
        if await store.meta("nfo_parser_version") != nfoParserCurrent {
            await store.markSidecarsPendingForParserUpgrade()
            await store.setMeta("nfo_parser_version", nfoParserCurrent, scanGeneration: scanGeneration)
        }
        let failureSummary = listFailureCounts.isEmpty
            ? "none"
            : listFailureCounts
                .sorted { $0.key.rawValue < $1.key.rawValue }
                .map { "\($0.key.rawValue):\($0.value)" }
                .joined(separator: ",")
        PlozzLog.boot(
            "share.scan done scanID=\(scanID) dirs=\(dirsWalked) skipped=\(dirsSkipped) files=\(filesFound) pruned=\(!anyListingFailed) failed=\(listFailureCounts.values.reduce(0, +)) failures=[\(failureSummary)] elapsed=\(Int(Date().timeIntervalSince(started) * 1_000))ms"
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
    /// A subdirectory seen in a listing, with the mtime used to decide whether it
    /// needs listing on the next scan.
    struct ScannedSubdirectory: Sendable {
        let relPath: String
        let modifiedAt: Date?
    }

    private struct DirResult: Sendable {
        let lister: ScanLister
        let dir: String
        let subdirectories: [ScannedSubdirectory]
        var subdirs: [String] { subdirectories.map(\.relPath) }
        let assets: [CatalogAsset]
        let sidecars: [LocalSidecarCandidate]
        let artwork: [LocalArtworkCandidate]
        let ok: Bool
        /// Set only when `ok == false`: a bounded, PATH-FREE classification of the
        /// listing failure for aggregate diagnostics (never the directory, basename,
        /// or the error's localized description, which can embed a share path).
        var failureCategory: ShareScanListFailureCategory?
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
            // PATH-PRIVATE diagnostics (C3): never log the directory/basename or the
            // error's localized description (either can embed a share path). Classify
            // the failure into a bounded category; the caller aggregates counts.
            return DirResult(
                lister: lister, dir: dir, subdirectories: [], assets: [], sidecars: [],
                artwork: [], ok: false,
                failureCategory: ShareScanListFailureCategory(error)
            )
        }
        var subdirs: [ScannedSubdirectory] = []
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
                subdirs.append(ScannedSubdirectory(relPath: childPath, modifiedAt: entry.modifiedAt))
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

        // This is deliberately computed only from the directory listing. No stat,
        // readSmallFile, source lease, ImageIO, or metadata work is admitted here.
        let artwork = ShareArtworkInventoryPolicy.candidates(entries: entries, parentDir: dir)
        return DirResult(
            lister: lister, dir: dir, subdirectories: subdirs, assets: assets,
            sidecars: sidecars, artwork: artwork, ok: true
        )
    }

    // MARK: - Interrupted-scan resume

    /// A partial walk's remaining work, persisted so an interruption costs only
    /// what was left rather than the whole share.
    private struct ResumeState {
        let scanID: Int64
        let frontier: [String]
    }

    private static let resumeScanIDKey = "resume_scan_id"
    private static let resumeFrontierKey = "resume_frontier"
    private static let resumeSavedAtKey = "resume_saved_at"

    /// How long a saved frontier stays usable. A resume reuses the interrupted
    /// pass's scanID, so its already-walked half is never revisited — if that half
    /// is days old it is better to re-walk from scratch than to prune against a
    /// stale picture of the share.
    private static let resumeMaxAge: TimeInterval = 6 * 60 * 60

    private static func loadResumeState(store: ShareCatalogStore) async -> ResumeState? {
        guard let idText = await store.meta(resumeScanIDKey),
              let scanID = Int64(idText),
              let savedAtText = await store.meta(resumeSavedAtKey),
              let savedAt = TimeInterval(savedAtText),
              let json = await store.meta(resumeFrontierKey),
              let data = json.data(using: .utf8),
              let frontier = try? JSONDecoder().decode([String].self, from: data),
              !frontier.isEmpty
        else { return nil }
        guard Date().timeIntervalSince1970 - savedAt < resumeMaxAge else { return nil }
        return ResumeState(scanID: scanID, frontier: frontier)
    }

    private static func saveResumeState(
        store: ShareCatalogStore,
        scanID: Int64,
        frontier: [String],
        scanGeneration: UUID?
    ) async {
        guard !frontier.isEmpty,
              let data = try? JSONEncoder().encode(frontier),
              let json = String(data: data, encoding: .utf8)
        else {
            // Nothing left to do, or the frontier can't be encoded: drop any stale
            // state rather than leaving a resume pointing at the wrong work.
            await clearResumeState(store: store, scanGeneration: scanGeneration)
            return
        }
        await store.setMeta(resumeScanIDKey, String(scanID), scanGeneration: scanGeneration)
        await store.setMeta(resumeFrontierKey, json, scanGeneration: scanGeneration)
        await store.setMeta(
            resumeSavedAtKey,
            String(Date().timeIntervalSince1970),
            scanGeneration: scanGeneration
        )
    }

    private static func clearResumeState(store: ShareCatalogStore, scanGeneration: UUID?) async {
        for key in [resumeScanIDKey, resumeFrontierKey, resumeSavedAtKey] {
            await store.setMeta(key, "", scanGeneration: scanGeneration)
        }
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

/// Bounded, PATH-FREE classification of a directory-listing failure, used only for
/// aggregate scan diagnostics. The raw value is a fixed, library-structure-free token;
/// it is derived solely from the error's domain/code — never its localized description
/// (which can embed a share path/basename) and never any directory string.
enum ShareScanListFailureCategory: String, Sendable, CaseIterable {
    case timedOut
    case connectionLost
    case authFailed
    case permissionDenied
    case notFound
    case cancelled
    case other

    init(_ error: Error) {
        if error is CancellationError {
            self = .cancelled
            return
        }
        let ns = error as NSError
        switch (ns.domain, ns.code) {
        case (NSURLErrorDomain, NSURLErrorTimedOut):
            self = .timedOut
        case (NSURLErrorDomain, NSURLErrorCancelled):
            self = .cancelled
        case (NSURLErrorDomain, NSURLErrorNetworkConnectionLost),
             (NSURLErrorDomain, NSURLErrorNotConnectedToInternet),
             (NSURLErrorDomain, NSURLErrorCannotConnectToHost),
             (NSURLErrorDomain, NSURLErrorCannotFindHost),
             (NSURLErrorDomain, NSURLErrorDNSLookupFailed):
            self = .connectionLost
        case (NSURLErrorDomain, NSURLErrorUserAuthenticationRequired),
             (NSURLErrorDomain, NSURLErrorUserCancelledAuthentication):
            self = .authFailed
        case (NSURLErrorDomain, NSURLErrorNoPermissionsToReadFile):
            self = .permissionDenied
        case (NSURLErrorDomain, NSURLErrorFileDoesNotExist),
             (NSURLErrorDomain, NSURLErrorResourceUnavailable):
            self = .notFound
        case (NSCocoaErrorDomain, NSFileReadNoPermissionError),
             (NSCocoaErrorDomain, NSFileWriteNoPermissionError):
            self = .permissionDenied
        case (NSCocoaErrorDomain, NSFileNoSuchFileError),
             (NSCocoaErrorDomain, NSFileReadNoSuchFileError):
            self = .notFound
        case (NSPOSIXErrorDomain, Int(EACCES)),
             (NSPOSIXErrorDomain, Int(EPERM)):
            self = .permissionDenied
        case (NSPOSIXErrorDomain, Int(ENOENT)):
            self = .notFound
        case (NSPOSIXErrorDomain, Int(ETIMEDOUT)):
            self = .timedOut
        case (NSPOSIXErrorDomain, Int(ECONNRESET)),
             (NSPOSIXErrorDomain, Int(ECONNREFUSED)),
             (NSPOSIXErrorDomain, Int(ENOTCONN)),
             (NSPOSIXErrorDomain, Int(EHOSTUNREACH)),
             (NSPOSIXErrorDomain, Int(ENETUNREACH)),
             (NSPOSIXErrorDomain, Int(ENETDOWN)):
            self = .connectionLost
        default:
            self = .other
        }
    }
}
