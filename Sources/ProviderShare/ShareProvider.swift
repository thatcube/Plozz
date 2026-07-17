import Foundation
import CoreModels
import CoreNetworking
import MediaTransportCore

/// Second-class local media-share provider (SMB). Conforms to `MediaProvider`
/// so Home / browse / search / playback treat a share like any other backend —
/// but everything a real server would compute (libraries, detail, search) is
/// synthesised from a local scan (`ShareLibraryStore`) instead of network calls.
///
/// Connection metadata remains in the ordinary `UserSession`; credentials are
/// resolved only by the transport adapter. Playback returns a credential-free
/// `NetworkFileLocator` that EnginePlozzigen opens through the shared resolver.
///
/// This type is a thin facade: catalog reads go through the injected
/// `any ShareCatalogReading` capability (never the concrete `ShareCatalogStore`),
/// watch-state stamping/writes through `ShareWatchStateService`, and playback
/// file access (locator, sidecar subtitles, stream probe) through
/// `SharePlaybackSourceService`. It keeps only browse/playback orchestration.
public struct ShareProvider: MediaProvider {
    public let kind: ProviderKind = .mediaShare
    public let session: UserSession
    public let localMediaContext: LocalMediaContext

    private let store: ShareLibraryStore
    private let catalogCoordinator: any ShareCatalogCoordinating
    /// Resolves the read-only catalog capability for this share on demand (the
    /// injected coordinator outlives transient provider values). A test override
    /// short-circuits to a supplied reader.
    private let catalogAccessor: @Sendable () async -> any ShareCatalogReading
    private let watchState: ShareWatchStateService
    private let playbackSource: SharePlaybackSourceService

    public init(
        session: UserSession,
        localMediaContext: LocalMediaContext,
        credentialRevision: CredentialRevision,
        sessionFactory: @escaping ShareTransportSessionFactory,
        catalogCoordinator: any ShareCatalogCoordinating,
        durableLocalStateStore: DurableLocalStateStore? = nil,
        streamProber: NetworkFileStreamProbing? = nil
    ) {
        self.init(
            session: session,
            localMediaContext: localMediaContext,
            durableLocalStateStore: durableLocalStateStore,
            credentialRevision: credentialRevision,
            sessionFactory: sessionFactory,
            catalogCoordinator: catalogCoordinator,
            streamProber: streamProber
        )
    }

    /// Test seam with an injectable durable store and catalog reader.
    init(
        session: UserSession,
        localMediaContext: LocalMediaContext? = nil,
        durableLocalStateStore: DurableLocalStateStore? = nil,
        credentialRevision: CredentialRevision = CredentialRevision(
            rawValue: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        ),
        sessionFactory: @escaping ShareTransportSessionFactory = { _ in
            throw MediaTransportError.unsupportedCapability("test transport")
        },
        catalogCoordinator: any ShareCatalogCoordinating = ShareCatalogCoordinator(),
        streamProber: NetworkFileStreamProbing? = nil,
        catalogStore: (any ShareCatalogReading)? = nil
    ) {
        self.session = session
        let resolvedContext = localMediaContext ?? LocalMediaContext(
            accountID: session.server.id,
            profileID: ProfileStore.defaultProfileID,
            profileNamespace: nil
        )
        self.localMediaContext = resolvedContext
        self.catalogCoordinator = catalogCoordinator
        let browser = ShareTransportBrowser(
            role: .metadata,
            sessionFactory: sessionFactory
        )
        let libraryStore = ShareLibraryStore(browser: browser, serverName: session.server.name)
        self.store = libraryStore
        // Watch state is device-local (a file share has no server), scoped by the
        // share's stable account id so two shares keep separate progress.
        let watchStore = ShareWatchStore(
            localMediaContext: resolvedContext,
            durableStore: durableLocalStateStore
        )
        let accountID = resolvedContext.accountID
        let displayName = session.server.name
        // Capture the coordinator + fixed context (not `self`, which is still being
        // initialised) so the accessor can resolve the read capability lazily.
        let accessor: @Sendable () async -> any ShareCatalogReading = {
            if let catalogStore { return catalogStore }
            return await catalogCoordinator.catalogReader(
                accountKey: accountID,
                displayName: displayName,
                credentialRevision: credentialRevision,
                sessionFactory: sessionFactory
            )
        }
        self.catalogAccessor = accessor
        self.watchState = ShareWatchStateService(
            watchStore: watchStore,
            accountID: accountID,
            catalog: accessor
        )
        self.playbackSource = SharePlaybackSourceService(
            store: libraryStore,
            streamProber: streamProber,
            accountID: accountID,
            credentialRevision: credentialRevision
        )
    }

    // MARK: Library browsing

    /// App-owned catalog for this share (SQLite index built by a background
    /// `ShareScanner`), resolved through the injected read capability so the
    /// concrete store never leaks into the facade.
    private var catalog: any ShareCatalogReading {
        get async { await catalogAccessor() }
    }

    /// Force a fresh scan + enrichment of this share now (Settings "Scan now").
    /// Touches `catalog` first so the store/scanner/enricher are registered even if
    /// Home never queried this share yet, then forces a scan bypassing the throttle.
    public func rescan() async {
        _ = await catalog
        await catalogCoordinator.rescan(accountKey: localMediaContext.accountID)
    }

    public func libraries() async throws -> [MediaLibrary] {
        // Home aggregation calls this at launch, so it must be instant — SQLite
        // reads only (no network) plus a fire-and-forget scan kick. Indexed
        // Movies / TV Shows / Anime libraries appear ONLY once the scan has found
        // content for them (no empty rows on a fresh share); the raw file-tree
        // library (named after the share) is always present and browsed live.
        let catalog = await self.catalog
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
        // Canonicalize ALL stored state before filtering/limiting so several legacy
        // file-version records collapse to one movie without pushing distinct
        // titles off the row.
        let byCanonical = await watchState.allCanonicalRecords()
        let resumable = byCanonical.filter { !$0.value.played && $0.value.position > 1 }
        let ranked = resumable
            .sorted { $0.value.updatedAt > $1.value.updatedAt }
            .prefix(limit)

        var items: [MediaItem] = []
        for (itemID, record) in ranked {
            // Resolve through the CATALOG first (indexed → carries series/season
            // linkage, including the `seasonID` the player's neighbour resolver
            // needs to offer Up Next / auto-advance), falling back to the raw
            // file-tree build only for un-indexed items.
            let base: MediaItem
            if let indexed = await catalog.item(id: itemID) {
                base = indexed
            } else if let rawItem = await store.item(id: itemID) {
                base = rawItem
            } else {
                continue
            }
            items.append(ShareWatchStateService.stamped(base, with: record))
        }
        // Device-observable (in-app log ring) so a missing Continue Watching row
        // can be traced to "no resumable state on disk" vs "rebuild dropped it".
        PlozzLog.playback.info("share.continueWatching account=\(localMediaContext.accountID) resumable=\(resumable.count) folded=\(byCanonical.count) rebuilt=\(items.count)")
        return items
    }

    public func latest(limit: Int) async throws -> [MediaItem] {
        // Recently Added, served from the catalog by first-discovery date — no
        // network, safe on the Home hot path. Empty until the first scan populates.
        let items = await catalog.latest(limit: limit)
        return await watchState.stamp(items)
    }

    public func item(id: String) async throws -> MediaItem {
        // Indexed items (movies/series/seasons/episodes) resolve from the catalog;
        // raw file-tree ids (`share:root`, `d:`) fall back to the live browser.
        if let indexed = await catalog.item(id: id) {
            // A user just opened this — fast-track its enrichment ahead of the
            // background backlog so its hero/poster/overview persist promptly. Fire-
            // and-forget (no added latency); a no-op once the item is enriched.
            await catalogCoordinator.enrichItem(
                accountKey: localMediaContext.accountID,
                itemID: id
            )
            playbackSource.measureStreamProbeIfEnabled(itemID: id)
            return await watchState.stamp(indexed)
        }
        guard let item = await store.item(id: id) else {
            throw AppError.unknown("Item not found on share: \(id)")
        }
        return await watchState.stamp(item)
    }

    public func children(of itemID: String) async throws -> [MediaItem] {
        // Series → seasons, season → episodes (from the catalog); a raw folder's
        // children are that directory's live listing.
        if ShareCatalogID.isSeries(itemID), let key = ShareCatalogID.seriesKey(forSeriesID: itemID) {
            return await watchState.stamp(await catalog.seasons(seriesKey: key))
        }
        if let (key, season) = ShareCatalogID.seasonComponents(forSeasonID: itemID) {
            return await watchState.stamp(await catalog.episodes(seriesKey: key, season: season))
        }
        let entries = try await store.entries(forContainerID: itemID)
        return await watchState.stamp(entries)
    }

    public func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        // Indexed library grids page from the catalog; series/season containers are
        // small (delegate to `children`); the raw file tree lists the directory.
        if let library = ShareCatalogID.catalogLibrary(forID: containerID) {
            let t0 = Date()
            let catalog = await self.catalog
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
            let stamped = await watchState.stamp(items)
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
        let slice = await watchState.stamp(Array(all[start..<end]))
        return MediaPage(items: slice, startIndex: start, totalCount: all.count)
    }

    // MARK: Search

    public func search(query: String, limit: Int) async throws -> [MediaItem] {
        // Indexed search over the catalog; empty until the first scan populates.
        return await watchState.stamp(await catalog.search(query: query, limit: limit))
    }

    // MARK: Playback

    public func playbackInfo(for itemID: String) async throws -> PlaybackRequest {
        try await playbackInfo(for: itemID, mediaSourceID: nil, forceTranscode: false)
    }

    public func playbackInfo(for itemID: String, forceTranscode: Bool) async throws -> PlaybackRequest {
        try await playbackInfo(for: itemID, mediaSourceID: nil, forceTranscode: forceTranscode)
    }

    /// Resolve the file to stream. The version picker threads the chosen version's
    /// id (which, for a share, IS the file's rel-path) as `mediaSourceID`; a logical
    /// `movie:<key>` with no chosen version plays its best default file; a bare
    /// `f:<rel>` (raw browser / episode) plays directly.
    public func playbackInfo(for itemID: String, mediaSourceID: String?, forceTranscode: Bool) async throws -> PlaybackRequest {
        let catalog = await self.catalog
        let canonicalItemID = await catalog.canonicalItemID(itemID)
        let relPath: String
        if let ms = mediaSourceID, !ms.isEmpty {
            relPath = ms
        } else if ShareCatalogID.relPath(forFileID: itemID) != nil,
                  await catalog.containsFileAsset(id: itemID),
                  let path = await store.path(forItemID: itemID) {
            // A live raw-file id means the user selected that exact file in Files.
            relPath = path
        } else if let key = ShareCatalogID.movieKey(forMovieID: canonicalItemID) {
            guard let def = await catalog.defaultMovieRelPath(forKey: key) else {
                throw AppError.unknown("No playable version for \(canonicalItemID)")
            }
            relPath = def
        } else if let p = await store.path(forItemID: itemID) {
            relPath = p
        } else {
            throw AppError.unknown("Item is not directly playable: \(itemID)")
        }
        let locator = try await playbackSource.networkFileLocator(for: relPath)
        let item = try await item(id: canonicalItemID)
        // Resume from the newest canonical/legacy member-file state so a movie
        // watched before version grouping still resumes after the upgrade.
        let records = await watchState.records(for: [canonicalItemID])
        let record = records[canonicalItemID]
        let startPosition = (record?.played == true) ? 0 : (record?.position ?? 0)
        let playItem = (mediaSourceID != nil) ? item.selectingVersion(mediaSourceID) : item
        // Surface any text sidecar subtitles sitting next to the video (and in a
        // sibling Subs/Subtitles folder) as selectable tracks. Best-effort: a
        // listing/read failure just yields no sidecars rather than blocking play.
        let subtitleTracks = (try? await playbackSource.discoverSidecarSubtitles(forVideoRelPath: relPath)) ?? []
        return PlaybackRequest(
            item: playItem,
            playbackSource: .networkFile(locator),
            subtitleTracks: subtitleTracks,
            startPosition: startPosition,
            sourceProvider: .mediaShare,
            serverName: session.server.name,
            sourceFileName: (relPath as NSString).lastPathComponent
        )
    }

    /// Thin forwarder retained for direct tests of the representation-identity
    /// policy; the logic lives in `SharePlaybackSourceService`.
    func networkFileLocator(for relativePath: String) async throws -> NetworkFileLocator {
        try await playbackSource.networkFileLocator(for: relativePath)
    }

    /// Forwarder retained for the sidecar-matching unit tests; the logic lives in
    /// `SharePlaybackSourceService`.
    static func sidecarMatchesVideo(sidecarStem: String, videoStem: String, dedicatedFolder: Bool) -> Bool {
        SharePlaybackSourceService.sidecarMatchesVideo(
            sidecarStem: sidecarStem,
            videoStem: videoStem,
            dedicatedFolder: dedicatedFolder
        )
    }

    public func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {
        // No server to report to, but persist live progress locally so a hard app
        // kill still leaves a usable resume point.
        await watchState.recordPlayback(progress, event: event)
    }

    // MARK: Images

    public func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? {
        // Artwork via MetadataKit (TMDb) lands in Phase 2c. No poster for now.
        nil
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
    /// DNS name. Strip a matching surrounding `[...]` so the transport gets
    /// `fe80::1`.
    public static func unbracketedHost(_ host: String) -> String {
        guard host.hasPrefix("["), host.hasSuffix("]"), host.count >= 2 else { return host }
        return String(host.dropFirst().dropLast())
    }

    // MARK: - Parse baseURL

    private static func parse(
        _ baseURL: URL
    ) -> (host: String, port: Int?, share: String, rootPathComponents: [String]) {
        let comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        let host = unbracketedHost(comps?.host ?? "")
        let port = comps?.port
        let pathComponents = (comps?.path ?? "")
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        return (
            host,
            port,
            pathComponents.first ?? "",
            Array(pathComponents.dropFirst())
        )
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

extension ShareProvider: InteractiveBrowseActivityReporting {
    public func noteInteractiveBrowseActivity() async {
        await catalogCoordinator.noteInteractiveActivity(
            accountKey: localMediaContext.accountID
        )
    }
}

extension ShareProvider: WatchStateProviding {
    /// Live UI toggle (mark watched / unwatched): the action happens *now*, so
    /// stamp with the current time. The outbox-drained path uses the timestamped
    /// ``PlayedStateWriting`` overload below with the play's real capture time.
    public func setPlayed(_ played: Bool, itemID: String) async throws {
        await watchState.setPlayed(played, itemID: itemID, capturedAt: Date())
    }
}

extension ShareProvider: PlayedStateWriting {
    /// Outbox-drained played write: use the play's real `capturedAt` (not the
    /// drain time) so a stale played write that drains after a newer re-watch
    /// can't overwrite the newer resume state — the local store orders writes by
    /// `capturedAt`.
    public func setPlayed(_ played: Bool, itemID: String, capturedAt: Date) async throws {
        await watchState.setPlayed(played, itemID: itemID, capturedAt: capturedAt)
    }
}

extension ShareProvider: ResumeStateWriting {
    /// Persist a resume position locally. `capturedAt` orders writes so a late
    /// draining queued resume can't overwrite a newer state.
    public func setResumePosition(_ seconds: TimeInterval, itemID: String, capturedAt: Date) async throws {
        await watchState.setResumePosition(seconds, itemID: itemID, capturedAt: capturedAt)
    }
}
