import Foundation
import CoreModels
import CoreNetworking

/// Second-class local media-share provider (SMB). Conforms to `MediaProvider`
/// so Home / browse / search / playback treat a share like any other backend —
/// but everything a real server would compute (libraries, detail, search) is
/// synthesised from a local scan (`ShareLibraryStore`) instead of network calls.
///
/// The share connection is carried by the ordinary `UserSession`: the synthetic
/// `MediaServer.baseURL` is `smb://host[:port]/share`, `session.userName` is the
/// SMB account (or "guest"), and `session.accessToken` is the password (already
/// Keychain-backed by `SessionStore`). Playback hands back an `smb://` URL that
/// `EnginePlozzigen` turns into an engine `SMBConnection` custom source.
public struct ShareProvider: MediaProvider {
    public let kind: ProviderKind = .mediaShare
    public let session: UserSession

    private let store: ShareLibraryStore
    private let watchStore: ShareWatchStore
    private let host: String
    private let port: Int?
    private let share: String
    /// Injected engine-side SMB header prober (nil in tests / when the engine layer
    /// isn't wired). Used to obtain real per-file stream facts for a share that has
    /// no server metadata. Currently drives an opt-in on-device timing measurement
    /// (env `PLZXPROBE=1`); becomes the source for cached facts in Phase 1.
    private let streamProber: SMBStreamProbing?

    public init(session: UserSession, streamProber: SMBStreamProbing? = nil) {
        self.init(session: session, watchDirectory: nil, streamProber: streamProber)
    }

    /// Test seam: build a provider whose device-local watch state lives in
    /// `watchDirectory` instead of Application Support, so the reportPlayback →
    /// persist → continueWatching path can be exercised end-to-end (including a
    /// simulated relaunch) without touching the real app container.
    init(session: UserSession, watchDirectory: URL?, streamProber: SMBStreamProbing? = nil) {
        self.session = session
        self.streamProber = streamProber
        let parsed = Self.parse(session.server.baseURL)
        self.host = parsed.host
        self.port = parsed.port
        self.share = parsed.share
        let browser = SMBShareBrowser(
            host: parsed.host, port: parsed.port, share: parsed.share,
            user: session.userName, password: session.accessToken
        )
        self.store = ShareLibraryStore(browser: browser, serverName: session.server.name)
        // Watch state is device-local (a file share has no server), scoped by the
        // share's stable account id so two shares keep separate progress.
        self.watchStore = ShareWatchStore(accountKey: session.server.id, directory: watchDirectory)
    }

    // MARK: Library browsing

    /// Shared, process-wide catalog for this share (SQLite index built by a
    /// background `ShareScanner`). Fetched from the registry rather than stored on
    /// the provider, which SwiftUI rebuilds constantly. Accessing it also kicks a
    /// throttled background scan.
    private var catalog: ShareCatalogStore {
        get async {
            await ShareCatalogRegistry.shared.store(
                accountKey: session.server.id,
                displayName: session.server.name,
                host: host, port: port, share: share,
                user: session.userName, password: session.accessToken
            )
        }
    }

    /// Force a fresh scan + enrichment of this share now (Settings "Scan now").
    /// Touches `catalog` first so the store/scanner/enricher are registered even if
    /// Home never queried this share yet, then forces a scan bypassing the throttle.
    public func rescan() async {
        _ = await catalog
        await ShareCatalogRegistry.shared.rescan(accountKey: session.server.id)
    }

    public func libraries() async throws -> [MediaLibrary] {
        // Home aggregation calls this at launch, so it must be instant — SQLite
        // reads only (no network) plus a fire-and-forget scan kick. Indexed
        // Movies / TV Shows / Anime libraries appear ONLY once the scan has found
        // content for them (no empty rows on a fresh share); the raw file-tree
        // library (named after the share) is always present and browsed live.
        let catalog = await catalog
        let counts = await catalog.libraryCounts()
        var result: [MediaLibrary] = []
        if counts.movies > 0 {
            result.append(MediaLibrary(id: ShareCatalogID.moviesLibrary, title: "Movies", kind: .movie))
        }
        if counts.tvSeries > 0 {
            result.append(MediaLibrary(id: ShareCatalogID.tvLibrary, title: "TV Shows", kind: .series))
        }
        if counts.animeSeries > 0 {
            result.append(MediaLibrary(id: ShareCatalogID.animeLibrary, title: "Anime", kind: .series))
        }
        // The raw browsable file tree, named after the share (not "Files").
        result.append(contentsOf: await store.libraries())
        return result
    }

    public func continueWatching(limit: Int) async throws -> [MediaItem] {
        // Resume row is served entirely from local watch state — no network, so
        // it's safe on the Home hot path. Each resumable id is rebuilt from the
        // store (id → item, no scan) and stamped with its saved progress.
        let resumable = await watchStore.resumable(limit: limit)
        var items: [MediaItem] = []
        for entry in resumable {
            // Resolve through the CATALOG first (indexed → carries series/season
            // linkage, including the `seasonID` the player's neighbour resolver
            // needs to offer Up Next / auto-advance), falling back to the raw
            // file-tree build only for un-indexed items. Matches `item(id:)`'s
            // resolution order; a bare `store.item(id:)` yields a filename-parsed
            // item with no `seasonID`, which silently disables episode hand-off.
            let base: MediaItem
            if let indexed = await catalog.item(id: entry.itemID) {
                base = indexed
            } else if let raw = await store.item(id: entry.itemID) {
                base = raw
            } else {
                continue
            }
            items.append(Self.stamped(base, with: entry.record))
        }
        // Device-observable (in-app log ring) so a missing Continue Watching row
        // can be traced to "no resumable state on disk" vs "rebuild dropped it".
        PlozzLog.playback.info("share.continueWatching account=\(session.server.id) resumable=\(resumable.count) rebuilt=\(items.count)")
        return items
    }

    public func latest(limit: Int) async throws -> [MediaItem] {
        // Recently Added, served from the catalog by first-discovery date — no
        // network, safe on the Home hot path. Empty until the first scan populates.
        let items = await catalog.latest(limit: limit)
        return await stampWatchState(items)
    }

    public func item(id: String) async throws -> MediaItem {
        // Indexed items (movies/series/seasons/episodes) resolve from the catalog;
        // raw file-tree ids (`share:root`, `d:`) fall back to the live browser.
        if let indexed = await catalog.item(id: id) {
            // A user just opened this — fast-track its enrichment ahead of the
            // background backlog so its hero/poster/overview persist promptly. Fire-
            // and-forget (no added latency); a no-op once the item is enriched.
            await ShareCatalogRegistry.shared.enrichItem(accountKey: session.server.id, itemID: id)
            measureStreamProbeIfEnabled(itemID: id)
            return await stampWatchState(indexed)
        }
        guard let item = await store.item(id: id) else {
            throw AppError.unknown("Item not found on share: \(id)")
        }
        return await stampWatchState(item)
    }

    /// Opt-in on-device timing measurement (env `PLZXPROBE=1`): probe this item's
    /// file headers over SMB and log elapsed time + facts, so we can validate the
    /// probe is fast enough for the browse-time metadata feature before building the
    /// full pipeline. Fire-and-forget; never blocks item resolution.
    private func measureStreamProbeIfEnabled(itemID: String) {
        guard ProcessInfo.processInfo.environment["PLZXPROBE"] == "1",
              let prober = streamProber else { return }
        Task.detached(priority: .utility) {
            // Record the browse, let the user settle, then probe ONLY if still idle —
            // so probing never competes with active navigation. One in-flight at a
            // time, spaced apart, capped per launch. (A naive fire-per-item version
            // stormed the NAS and, because the probe blocks a thread, froze the UI.)
            await ProbeMeasurementGate.shared.noteActivity()
            try? await Task.sleep(for: .seconds(4))
            guard await ProbeMeasurementGate.shared.tryStartIfIdle(idleFor: 4) else { return }
            defer { Task { await ProbeMeasurementGate.shared.finish() } }
            guard let relPath = await self.store.path(forItemID: itemID) else { return }
            let ext = (relPath as NSString).pathExtension.lowercased()
            let videoExts: Set<String> = ["mkv", "mp4", "m4v", "mov", "avi", "ts", "m2ts", "mts", "webm"]
            guard videoExts.contains(ext), let url = self.smbURL(forRelativePath: relPath) else { return }
            let name = (relPath as NSString).lastPathComponent
            let start = Date()
            let facts = await prober.probe(smbURL: url)
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            if let f = facts {
                HandoffDiagnostics.emit("PROBE ok file=\(name) container=\(ext) elapsed=\(ms)ms range=\(f.videoRangeType ?? "-") res=\(f.videoWidth ?? 0)x\(f.videoHeight ?? 0) vcodec=\(f.videoCodec ?? "-") acodec=\(f.audioCodec ?? "-") ch=\(f.audioChannels ?? 0) atmos=\(f.audioIsAtmos) dur=\(Int(f.durationSeconds ?? 0))s")
            } else {
                HandoffDiagnostics.emit("PROBE FAILED file=\(name) container=\(ext) elapsed=\(ms)ms")
            }
        }
    }

    public func children(of itemID: String) async throws -> [MediaItem] {
        // Series → seasons, season → episodes (from the catalog); a raw folder's
        // children are that directory's live listing.
        if ShareCatalogID.isSeries(itemID), let key = ShareCatalogID.seriesKey(forSeriesID: itemID) {
            return await stampWatchState(await catalog.seasons(seriesKey: key))
        }
        if let (key, season) = ShareCatalogID.seasonComponents(forSeasonID: itemID) {
            return await stampWatchState(await catalog.episodes(seriesKey: key, season: season))
        }
        let entries = try await store.entries(forContainerID: itemID)
        return await stampWatchState(entries)
    }

    public func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        // Indexed library grids page from the catalog; series/season containers are
        // small (delegate to `children`); the raw file tree lists the directory.
        if let library = ShareCatalogID.catalogLibrary(forID: containerID) {
            let t0 = Date()
            let catalog = await catalog
            let items: [MediaItem]
            let total: Int
            switch library {
            case .movies:
                items = await catalog.movies(offset: page.startIndex, limit: page.limit)
                total = await catalog.movieCount()
            case .tv, .anime:
                items = await catalog.series(in: library, offset: page.startIndex, limit: page.limit)
                total = await catalog.seriesCount(in: library)
            }
            let stamped = await stampWatchState(items)
            if ProcessInfo.processInfo.environment["PLZXPAGE"] == "1" {
                HandoffDiagnostics.emit("SMBPAGE lib=\(library.rawValue) start=\(page.startIndex) limit=\(page.limit) count=\(stamped.count) total=\(total) took=\(Int(Date().timeIntervalSince(t0) * 1000))ms")
            }
            // Report the EXACT catalog count (not an open-ended estimate) so the grid
            // sizes its sparse store once and can jump/random-access any page — the
            // same experience as Plex (totalSize) / Jellyfin (TotalRecordCount).
            // Guard against a page landing beyond a stale/mid-scan count so the grid
            // still sees at least what we returned.
            let reportedTotal = max(total, page.startIndex + stamped.count)
            return MediaPage(items: stamped, startIndex: page.startIndex, totalCount: reportedTotal)
        }
        if ShareCatalogID.isSeries(containerID) || ShareCatalogID.isSeason(containerID) {
            let all = try await children(of: containerID)
            let start = min(page.startIndex, all.count)
            let end = min(start + page.limit, all.count)
            return MediaPage(items: Array(all[start..<end]), startIndex: start, totalCount: all.count)
        }
        // Browsing the raw file tree lists exactly that directory.
        let all = try await store.entries(forContainerID: containerID)
        let start = min(page.startIndex, all.count)
        let end = min(start + page.limit, all.count)
        let slice = await stampWatchState(Array(all[start..<end]))
        return MediaPage(items: slice, startIndex: start, totalCount: all.count)
    }

    // MARK: Search

    public func search(query: String, limit: Int) async throws -> [MediaItem] {
        // Indexed search over the catalog; empty until the first scan populates.
        await stampWatchState(await catalog.search(query: query, limit: limit))
    }

    // MARK: Playback

    public func playbackInfo(for itemID: String) async throws -> PlaybackRequest {
        let item = try await item(id: itemID)
        guard let relPath = await store.path(forItemID: itemID) else {
            throw AppError.unknown("Item is not directly playable: \(itemID)")
        }
        guard let url = smbURL(forRelativePath: relPath) else {
            throw AppError.unknown("Couldn't build a stream URL for \(relPath)")
        }
        // Resume where the user left off (0 for a fresh/finished item). The player
        // treats this as the authoritative seed for both Play-from-detail and
        // Play-from-Continue-Watching.
        let record = await watchStore.record(for: itemID)
        let startPosition = (record?.played == true) ? 0 : (record?.position ?? 0)
        // Surface any text sidecar subtitles sitting next to the video (and in a
        // sibling Subs/Subtitles folder) as selectable tracks. Best-effort: a
        // listing/read failure just yields no sidecars rather than blocking play.
        let subtitleTracks = (try? await discoverSidecarSubtitles(forVideoRelPath: relPath)) ?? []
        return PlaybackRequest(
            item: item,
            streamURL: url,
            subtitleTracks: subtitleTracks,
            startPosition: startPosition,
            sourceProvider: .mediaShare,
            serverName: session.server.name
        )
    }

    /// Finds text sidecar subtitles for a video by listing its directory (and a
    /// sibling `Subs`/`Subtitles` folder) and matching files by stem, then
    /// materialises each to a local `file://` temp so the player's overlay — which
    /// fetches over HTTP/`file://`, never `smb://` — can read them. Reads are
    /// serial (the SMB session is single-connection) and lazy-small (sidecars are
    /// tiny). Cleans up its temp dir on player teardown is handled by the OS temp
    /// reaper; files are namespaced per item so replays reuse them within a run.
    private func discoverSidecarSubtitles(forVideoRelPath relPath: String) async throws -> [MediaTrack] {
        let dir = (relPath as NSString).deletingLastPathComponent
        let videoStem = ShareMediaParser.videoStem((relPath as NSString).lastPathComponent)

        // Gather candidate (directory, entry, isDedicatedSubsFolder) triples from the
        // video's own folder and any sibling Subs/Subtitles folder.
        var candidates: [(dir: String, name: String, dedicated: Bool)] = []
        let ownDir = dir
        let subFolderNames = ["Subs", "Subtitles", "subs", "subtitles"]
        let subDirs = subFolderNames.map { sub in dir.isEmpty ? sub : "\(dir)/\(sub)" }
        for (listDir, dedicated) in [(ownDir, false)] + subDirs.map({ ($0, true) }) {
            guard let entries = try? await store.rawEntries(inDirectory: listDir) else { continue }
            for entry in entries where !entry.isDirectory && ShareMediaParser.isSubtitleFile(entry.name) {
                candidates.append((listDir, entry.name, dedicated))
            }
        }
        guard !candidates.isEmpty else { return [] }

        var tracks: [MediaTrack] = []
        var nextID = 5_000
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("plozz-sidecars", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        for (candidateDir, name, dedicated) in candidates {
            guard let sidecar = ShareMediaParser.parseSidecar(name) else { continue }
            guard Self.sidecarMatchesVideo(sidecarStem: sidecar.stem, videoStem: videoStem, dedicatedFolder: dedicated) else { continue }

            let relSidecar = candidateDir.isEmpty ? name : "\(candidateDir)/\(name)"
            guard let data = try? await store.readFile(relSidecar), !data.isEmpty else { continue }
            let localURL = tempDir.appendingPathComponent("\(abs(relSidecar.hashValue))-\(name)")
            do {
                try data.write(to: localURL, options: .atomic)
            } catch {
                continue
            }
            let language = sidecar.language
            let langName = language.flatMap { SubtitleLanguageCatalog.displayName(forCode: $0) }
            var title = langName ?? language ?? "Subtitle"
            if sidecar.isForced { title += " (Forced)" }
            if sidecar.isSDH { title += " (SDH)" }
            tracks.append(MediaTrack(
                id: nextID,
                kind: .subtitle,
                displayTitle: title,
                language: language,
                codec: sidecar.ext,
                isForced: sidecar.isForced,
                isHearingImpaired: sidecar.isSDH,
                deliveryURL: localURL,
                isImageBasedSubtitle: false,
                isExternal: true
            ))
            nextID += 1
        }
        return tracks
    }

    /// Whether a sidecar's parsed stem belongs to the video with `videoStem`.
    ///
    /// In the video's **own** directory we require an *exact* stem match — a
    /// prefix relaxation there cross-attaches sibling episodes with non-zero-padded
    /// numbering (`Show.S01E1.srt` would prefix-match `Show.S01E10.mkv`) and movie
    /// siblings (`Batman` vs `Batman Begins`). In a **dedicated** `Subs/Subtitles`
    /// folder — conventionally holding a single title's subs — we allow a prefix
    /// match, but only at a separator boundary so `E1` still can't match `E10`.
    static func sidecarMatchesVideo(sidecarStem: String, videoStem: String, dedicatedFolder: Bool) -> Bool {
        if sidecarStem == videoStem { return true }
        guard dedicatedFolder else { return false }
        return isPrefixAtBoundary(sidecarStem, of: videoStem)
            || isPrefixAtBoundary(videoStem, of: sidecarStem)
    }

    /// Whether `prefix` is a prefix of `whole` ending at a separator boundary
    /// (the next character is `.`, space, `-`, `_`), so `E1` can't prefix `E10`.
    private static func isPrefixAtBoundary(_ prefix: String, of whole: String) -> Bool {
        guard prefix.count < whole.count, whole.hasPrefix(prefix) else { return false }
        let nextIndex = whole.index(whole.startIndex, offsetBy: prefix.count)
        let next = whole[nextIndex]
        return next == "." || next == " " || next == "-" || next == "_"
    }

    public func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {
        // No server to report to, but persist live progress locally so a hard app
        // kill still leaves a usable resume point. A share reports `.stop` with the
        // final position too (the outbox — which owns the played-vs-resume decision
        // that needs duration — may not even target a local share), so `.stop`
        // persists the resume directly here. A later `setPlayed(true)` drained from
        // the outbox (newer `capturedAt`) still supersedes it and clears the resume,
        // so a fully-watched title doesn't linger in Continue Watching.
        PlozzLog.playback.info("share.reportPlayback event=\(String(describing: event)) item=\(progress.itemID) pos=\(Int(progress.positionSeconds)) account=\(session.server.id)")
        switch event {
        case .progress, .pause, .stop:
            await watchStore.setResume(progress.positionSeconds, itemID: progress.itemID, capturedAt: Date(), duration: progress.durationSeconds)
        case .start, .unpause:
            break
        }
    }

    // MARK: - Watch-state stamping

    /// Overlay saved resume/played state onto a freshly-built item so the detail
    /// Play button shows "Resume" and cards show a checkmark / progress.
    private func stampWatchState(_ item: MediaItem) async -> MediaItem {
        // Only leaf playables carry watch state; containers (folders, series,
        // seasons, collections) have no resume/played record, so skip the lookup.
        switch item.kind {
        case .folder, .collection, .series, .season:
            return item
        default:
            break
        }
        let record = await watchStore.record(for: item.id)
        return Self.stamped(item, with: record)
    }

    private func stampWatchState(_ items: [MediaItem]) async -> [MediaItem] {
        var result: [MediaItem] = []
        result.reserveCapacity(items.count)
        for item in items { result.append(await stampWatchState(item)) }
        return result
    }

    private static func stamped(_ item: MediaItem, with record: ShareWatchStore.Record?) -> MediaItem {
        guard let record else { return item }
        var copy = item
        copy.isPlayed = record.played
        copy.resumePosition = (!record.played && record.position > 1) ? record.position : nil
        copy.lastPlayedAt = record.updatedAt
        // Carry the learned duration onto the item (a share item has no runtime
        // until it's played once) and derive the played fraction the Continue
        // Watching / poster progress bar renders. Only in-progress records get a
        // fraction — a finished (played) or unstarted item shows no bar.
        if let duration = record.duration, duration > 0 {
            if copy.runtime == nil { copy.runtime = duration }
            if !record.played, record.position > 1 {
                copy.playedPercentage = min(max(record.position / duration, 0), 1)
            }
        }
        return copy
    }

    // MARK: Images

    public func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? {
        // Artwork via MetadataKit (TMDb) lands in Phase 2c. No poster for now.
        nil
    }

    // MARK: - SMB URL

    /// Build `smb://[user[:password]@]host[:port]/share/<relPath>` with each
    /// path segment percent-encoded, for the engine's custom SMB source.
    private func smbURL(forRelativePath relPath: String) -> URL? {
        var comps = URLComponents()
        comps.scheme = "smb"
        comps.host = Self.bracketedHostIfIPv6(host)
        comps.port = port
        if !session.userName.isEmpty {
            comps.user = session.userName
            if !session.accessToken.isEmpty { comps.password = session.accessToken }
        }
        // Share + each relative segment, joined so URLComponents percent-encodes
        // spaces and other reserved characters correctly.
        let segments = [share] + relPath.split(separator: "/").map(String.init)
        comps.path = "/" + segments.joined(separator: "/")
        return comps.url
    }

    /// URLComponents produces `nil` for a bare IPv6 literal host (e.g. `fe80::1`)
    /// — it must be bracketed. IPv4 and hostnames never contain a colon, so this
    /// only wraps genuine IPv6 literals (and leaves already-bracketed ones alone).
    public static func bracketedHostIfIPv6(_ host: String) -> String {
        guard host.contains(":"), !host.hasPrefix("[") else { return host }
        return "[\(host)]"
    }

    /// The inverse: `URLComponents.host` returns an IPv6 literal *bracketed*
    /// (`"[fe80::1]"`) on Apple Foundation, but the SMB layer (`NWEndpoint.Host`)
    /// needs the bare literal — a bracketed string is treated as an unresolvable
    /// DNS name. Strip a matching surrounding `[...]` so the browser/engine get
    /// `fe80::1`. `smbURL` re-brackets it for URL construction via
    /// `bracketedHostIfIPv6`.
    public static func unbracketedHost(_ host: String) -> String {
        guard host.hasPrefix("["), host.hasSuffix("]"), host.count >= 2 else { return host }
        return String(host.dropFirst().dropLast())
    }

    // MARK: - Parse baseURL

    private static func parse(_ baseURL: URL) -> (host: String, port: Int?, share: String) {
        let comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        let host = unbracketedHost(comps?.host ?? "")
        let port = comps?.port
        let share = (comps?.path ?? "")
            .split(separator: "/", omittingEmptySubsequences: true)
            .first.map(String.init) ?? ""
        return (host, port, share)
    }
}

extension ShareProvider: ProviderTeardown {
    /// Release the SMB session when the account is removed / the token refreshes
    /// and the registry evicts this provider.
    public func teardown() async {
        await store.close()
    }
}

extension ShareProvider: CapabilityReporting {
    /// A media share is video-only: no music library, no server-backed remote
    /// subtitle search. Advertised explicitly so capability-gated UI is correct.
    public var capabilities: ProviderCapability { .video }
}

extension ShareProvider: WatchStateProviding {
    /// Live UI toggle (mark watched / unwatched): the action happens *now*, so
    /// stamp with the current time. The outbox-drained path uses the timestamped
    /// ``PlayedStateWriting`` overload below with the play's real capture time.
    public func setPlayed(_ played: Bool, itemID: String) async throws {
        await watchStore.setPlayed(played, itemID: itemID, capturedAt: Date())
    }
}

extension ShareProvider: PlayedStateWriting {
    /// Outbox-drained played write: use the play's real `capturedAt` (not the
    /// drain time) so a stale played write that drains after a newer re-watch
    /// can't overwrite the newer resume state — the local store orders writes by
    /// `capturedAt`.
    public func setPlayed(_ played: Bool, itemID: String, capturedAt: Date) async throws {
        await watchStore.setPlayed(played, itemID: itemID, capturedAt: capturedAt)
    }
}

extension ShareProvider: ResumeStateWriting {
    /// Persist a resume position locally. `capturedAt` orders writes so a late
    /// draining queued resume can't overwrite a newer state.
    public func setResumePosition(_ seconds: TimeInterval, itemID: String, capturedAt: Date) async throws {
        await watchStore.setResume(seconds, itemID: itemID, capturedAt: capturedAt)
    }
}

/// Serializes the opt-in stream-probe MEASUREMENT to ONE probe at a time and caps the
/// total per launch. A naive fire-per-item version stormed the NAS and — because the
/// probe blocks a thread — exhausted the Swift concurrency pool, stalling artwork and
/// enrichment. This gate makes the measurement safe: browsing a whole folder still
/// runs at most one probe at a time, and never more than `maxTotal` overall.
private actor ProbeMeasurementGate {
    static let shared = ProbeMeasurementGate()
    private var inFlight = false
    private var completed = 0
    private var lastStart = Date.distantPast
    private var lastActivity = Date.distantPast
    private let maxTotal = 12
    /// Minimum gap between probe STARTS.
    private let minInterval: TimeInterval = 6

    /// Record that the user just did something (opened/browsed an item), so probing
    /// can hold off until they've paused.
    func noteActivity() { lastActivity = Date() }

    /// Only start a probe when the user has been IDLE for `idleFor` seconds (no
    /// browsing), so probing never competes with active navigation.
    func tryStartIfIdle(idleFor: TimeInterval) -> Bool {
        let now = Date()
        guard !inFlight, completed < maxTotal,
              now.timeIntervalSince(lastActivity) >= idleFor,
              now.timeIntervalSince(lastStart) >= minInterval else { return false }
        inFlight = true
        lastStart = now
        return true
    }

    func finish() {
        inFlight = false
        completed += 1
    }
}
