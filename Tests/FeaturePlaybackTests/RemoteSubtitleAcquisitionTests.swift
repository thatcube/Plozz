#if canImport(AVFoundation)
import XCTest
import CoreModels
@testable import FeaturePlayback

/// A subtitle-focused fake `MediaProvider` whose subtitle-search/download/track
/// surface is scriptable, so `RemoteSubtitleAcquisition` can be driven without a
/// real server. Advertises `.remoteSubtitles` unless constructed otherwise.
private actor FakeSubtitleProvider: MediaProvider, CapabilityReporting {
    nonisolated let kind: ProviderKind = .jellyfin
    nonisolated let session = UserSession(
        server: MediaServer(
            id: "server", name: "Server",
            baseURL: URL(string: "https://example.test")!, provider: .jellyfin
        ),
        userID: "user", userName: "User", deviceID: "device", accessToken: "token"
    )
    nonisolated let capabilities: ProviderCapability

    private let searchResults: [RemoteSubtitle]
    /// Tracks the server exposes only *after* a successful download.
    private let tracksAfterDownload: [MediaTrack]
    private(set) var searchCallCount = 0
    private(set) var downloadedIDs: [String] = []
    private var didDownload = false

    init(
        capabilities: ProviderCapability = [.video, .remoteSubtitles],
        searchResults: [RemoteSubtitle] = [],
        tracksAfterDownload: [MediaTrack] = []
    ) {
        self.capabilities = capabilities
        self.searchResults = searchResults
        self.tracksAfterDownload = tracksAfterDownload
    }

    func remoteSubtitleSearch(itemID: String, language: String, preference: SubtitleSearchPreference) async throws -> [RemoteSubtitle] {
        searchCallCount += 1
        return searchResults
    }
    func downloadRemoteSubtitle(itemID: String, subtitleID: String) async throws {
        downloadedIDs.append(subtitleID)
        didDownload = true
    }
    func subtitleTracks(forItemID itemID: String) async throws -> [MediaTrack] {
        didDownload ? tracksAfterDownload : []
    }

    // Unused MediaProvider surface.
    func libraries() async throws -> [MediaLibrary] { [] }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func item(id: String) async throws -> MediaItem { MediaItem(id: id, title: "", kind: .movie) }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        MediaPage(items: [], startIndex: page.startIndex, totalCount: 0)
    }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest {
        PlaybackRequest(item: MediaItem(id: itemID, title: "", kind: .movie), streamURL: URL(string: "https://example.test/a.m3u8")!)
    }
    func playbackInfo(for itemID: String, mediaSourceID: String?, forceTranscode: Bool) async throws -> PlaybackRequest {
        try await playbackInfo(for: itemID)
    }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    nonisolated func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}

@MainActor
private final class SpyAcquisitionHost: RemoteSubtitleAcquisitionHost {
    var downloadStates: [SubtitleDownloadState] = []
    var hotLoaded: [(track: MediaTrack, language: String?, forced: Bool)] = []
    var selected: [(id: Int, userInitiated: Bool)] = []
    var primaryOff = true
    var hotLoadReturnID = 900_001

    func setSubtitleDownloadState(_ state: SubtitleDownloadState) { downloadStates.append(state) }
    func hotLoadDownloadedSubtitle(_ track: MediaTrack, preferredLanguage: String?, forced: Bool) -> Int {
        hotLoaded.append((track, preferredLanguage, forced))
        return hotLoadReturnID
    }
    func selectDownloadedSubtitle(id: Int, userInitiated: Bool) { selected.append((id, userInitiated)) }
    var isPrimarySubtitleOff: Bool { primaryOff }
}

@MainActor
final class RemoteSubtitleAcquisitionTests: XCTestCase {
    private func waitUntil(timeout: TimeInterval = 2, _ cond: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !cond() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func textSidecar(id: Int, language: String?) -> MediaTrack {
        MediaTrack(
            id: id, kind: .subtitle, displayTitle: "Sub", language: language,
            deliverySource: .localFile(URL(string: "file:///tmp/\(id).srt")!),
            isImageBasedSubtitle: false, isExternal: true
        )
    }

    // MARK: search

    func testSearchWithUnsupportedProviderReportsEmptyImmediately() async {
        let provider = FakeSubtitleProvider(capabilities: [.video])
        let host = SpyAcquisitionHost()
        let acq = RemoteSubtitleAcquisition(provider: provider, itemID: "i", host: host)

        acq.search(requestedLanguage: "eng", defaultLanguage: nil, preference: .default)

        XCTAssertEqual(host.downloadStates, [.empty])
        let count = await provider.searchCallCount
        XCTAssertEqual(count, 0)
    }

    func testSearchWithNoLanguageReportsEmpty() async {
        let provider = FakeSubtitleProvider()
        let host = SpyAcquisitionHost()
        let acq = RemoteSubtitleAcquisition(provider: provider, itemID: "i", host: host)

        acq.search(requestedLanguage: nil, defaultLanguage: nil, preference: .default)

        XCTAssertEqual(host.downloadStates, [.empty])
    }

    func testSearchPublishesResultsAndRemembersLanguage() async {
        let results = [RemoteSubtitle(id: "s1", name: "English.srt", language: "eng")]
        let provider = FakeSubtitleProvider(searchResults: results)
        let host = SpyAcquisitionHost()
        let acq = RemoteSubtitleAcquisition(provider: provider, itemID: "i", host: host)

        acq.search(requestedLanguage: "eng", defaultLanguage: nil, preference: .default)

        XCTAssertEqual(host.downloadStates.first, .searching)
        await waitUntil { host.downloadStates.count >= 2 }
        if case .results(let subs)? = host.downloadStates.last {
            XCTAssertEqual(subs.map(\.id), ["s1"])
        } else {
            XCTFail("expected .results, got \(String(describing: host.downloadStates.last))")
        }
        XCTAssertEqual(acq.lastSearchLanguage, "eng")
    }

    func testSearchWithEmptyResultsReportsEmpty() async {
        let provider = FakeSubtitleProvider(searchResults: [])
        let host = SpyAcquisitionHost()
        let acq = RemoteSubtitleAcquisition(provider: provider, itemID: "i", host: host)

        acq.search(requestedLanguage: "eng", defaultLanguage: nil, preference: .default)
        await waitUntil { host.downloadStates.count >= 2 }

        XCTAssertEqual(host.downloadStates.last, .empty)
    }

    func testRefreshSearchReusesLastLanguage() async {
        let provider = FakeSubtitleProvider(searchResults: [RemoteSubtitle(id: "s1", name: "n", language: "fra")])
        let host = SpyAcquisitionHost()
        let acq = RemoteSubtitleAcquisition(provider: provider, itemID: "i", host: host)

        acq.search(requestedLanguage: "fra", defaultLanguage: nil, preference: .default)
        await waitUntil { host.downloadStates.count >= 2 }
        acq.refreshSearch(defaultLanguage: nil, preference: .default)

        XCTAssertEqual(acq.lastSearchLanguage, "fra")
        await waitUntil { host.downloadStates.count >= 4 }
        let count = await provider.searchCallCount
        XCTAssertEqual(count, 2)
    }

    // MARK: download

    func testDownloadHotLoadsSelectsAndReportsAdded() async {
        let sidecar = textSidecar(id: 42, language: "eng")
        let provider = FakeSubtitleProvider(tracksAfterDownload: [sidecar])
        let host = SpyAcquisitionHost()
        let acq = RemoteSubtitleAcquisition(provider: provider, itemID: "i", host: host)

        acq.download(RemoteSubtitle(id: "dl1", name: "n", language: "eng"), preference: .default)

        XCTAssertEqual(host.downloadStates.first, .downloading("dl1"))
        await waitUntil { host.downloadStates.last == .added }
        XCTAssertEqual(host.hotLoaded.count, 1)
        XCTAssertEqual(host.hotLoaded.first?.track.id, 42)
        XCTAssertEqual(host.selected.map(\.id), [host.hotLoadReturnID])
        XCTAssertEqual(host.selected.first?.userInitiated, true)
        let downloaded = await provider.downloadedIDs
        XCTAssertEqual(downloaded, ["dl1"])
    }

    func testDownloadWithNoNewTrackStillReportsAddedAndDoesNotSelect() async {
        // Server never surfaces a new sidecar → poll returns nil.
        let provider = FakeSubtitleProvider(tracksAfterDownload: [])
        let host = SpyAcquisitionHost()
        let acq = RemoteSubtitleAcquisition(provider: provider, itemID: "i", host: host)

        acq.download(RemoteSubtitle(id: "dl1", name: "n", language: "eng"), preference: .default)
        await waitUntil { host.downloadStates.last == .added }

        XCTAssertTrue(host.hotLoaded.isEmpty)
        XCTAssertTrue(host.selected.isEmpty)
    }

    func testDownloadWithEmptyIDIsIgnored() async {
        let provider = FakeSubtitleProvider()
        let host = SpyAcquisitionHost()
        let acq = RemoteSubtitleAcquisition(provider: provider, itemID: "i", host: host)

        acq.download(RemoteSubtitle(id: "", name: "n", language: "eng"), preference: .default)

        XCTAssertTrue(host.downloadStates.isEmpty)
    }

    // MARK: auto-download

    func testAutoDownloadHotLoadsAndSelectsWhenSubtitleOff() async {
        let sidecar = textSidecar(id: 7, language: "eng")
        let provider = FakeSubtitleProvider(
            searchResults: [RemoteSubtitle(id: "auto1", name: "English.srt", language: "eng")],
            tracksAfterDownload: [sidecar]
        )
        let host = SpyAcquisitionHost()
        host.primaryOff = true
        let acq = RemoteSubtitleAcquisition(provider: provider, itemID: "i", host: host)

        acq.autoDownload(language: "eng", mode: .all, preference: .default)
        await waitUntil { !host.hotLoaded.isEmpty }

        XCTAssertEqual(host.hotLoaded.first?.track.id, 7)
        XCTAssertEqual(host.selected.map(\.id), [host.hotLoadReturnID])
        XCTAssertEqual(host.selected.first?.userInitiated, false)
        // Auto path never publishes a manual download UI state.
        XCTAssertTrue(host.downloadStates.isEmpty)
    }

    func testAutoDownloadHotLoadsButDoesNotSelectWhenSubtitleAlreadyShown() async {
        let sidecar = textSidecar(id: 7, language: "eng")
        let provider = FakeSubtitleProvider(
            searchResults: [RemoteSubtitle(id: "auto1", name: "English.srt", language: "eng")],
            tracksAfterDownload: [sidecar]
        )
        let host = SpyAcquisitionHost()
        host.primaryOff = false
        let acq = RemoteSubtitleAcquisition(provider: provider, itemID: "i", host: host)

        acq.autoDownload(language: "eng", mode: .all, preference: .default)
        await waitUntil { !host.hotLoaded.isEmpty }

        XCTAssertEqual(host.hotLoaded.count, 1)
        XCTAssertTrue(host.selected.isEmpty)
    }

    func testAutoDownloadRequiresLanguageMatch() async {
        // Only a non-matching-language result exists → requireLanguageMatch drops it.
        let provider = FakeSubtitleProvider(
            searchResults: [RemoteSubtitle(id: "auto1", name: "Spanish.srt", language: "spa")],
            tracksAfterDownload: [textSidecar(id: 7, language: "spa")]
        )
        let host = SpyAcquisitionHost()
        let acq = RemoteSubtitleAcquisition(provider: provider, itemID: "i", host: host)

        acq.autoDownload(language: "eng", mode: .all, preference: .default)
        // Give the task time to run and bail.
        await waitUntil(timeout: 0.5) { false }

        XCTAssertTrue(host.hotLoaded.isEmpty)
        let downloaded = await provider.downloadedIDs
        XCTAssertTrue(downloaded.isEmpty)
    }
}
#endif
