#if canImport(AVFoundation)
import CoreModels
import TraktService
import XCTest

@testable import FeaturePlayback

@MainActor
final class WatchProgressReporterTests: XCTestCase {

    private var retainedHosts: [SpyReporterHost] = []

    override func tearDown() {
        retainedHosts.removeAll()
        super.tearDown()
    }

    private func makeSUT(
        checkpointInterval: TimeInterval = 0, // loop off by default; tests call emitCheckpoint directly
        item: MediaItem = MediaItem(id: "item-1", title: "Ep", kind: .episode, runtime: 1_000)
    ) -> (WatchProgressReporter, SpyReporterHost, RecordingProvider, RecordingScrobbler, CheckpointRecorder) {
        let host = SpyReporterHost()
        host.request = PlaybackRequest(
            item: item,
            streamURL: URL(string: "https://example.test/a.m3u8")!,
            playSessionID: "session-1"
        )
        host.engineDuration = 1_000
        retainedHosts.append(host)
        let provider = RecordingProvider()
        let scrobbler = RecordingScrobbler()
        let recorder = CheckpointRecorder()
        let sut = WatchProgressReporter(
            host: host,
            provider: provider,
            itemID: "item-1",
            scrobbler: scrobbler,
            checkpointInterval: checkpointInterval,
            onCheckpoint: { position, percent in recorder.record(position: position, percent: percent) }
        )
        return (sut, host, provider, scrobbler, recorder)
    }

    // MARK: helpers

    private func waitForEvents(
        _ provider: RecordingProvider,
        count: Int,
        timeout: TimeInterval = 2.0
    ) async -> [RecordingProvider.Reported] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let events = await provider.events
            if events.count >= count { return events }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return await provider.events
    }

    // MARK: report + scrobble fan-out

    func testReportSendsToProviderAndScrobbler() async {
        let (sut, host, provider, scrobbler, _) = makeSUT()
        host.engineCurrentTime = 500
        await sut.report(event: .progress, isPaused: false)
        let events = await provider.events
        XCTAssertEqual(events.map(\.event), [.progress])
        XCTAssertEqual(events.first?.position, 500)
        let scrobbles = await scrobbler.calls
        XCTAssertEqual(scrobbles.map(\.event), [.progress])
        XCTAssertEqual(scrobbles.first?.progress ?? -1, 50, accuracy: 0.001) // 500/1000
    }

    func testReportHonorsPositionOverrideForScrobblePercent() async {
        // At stop() the engine reads 0; the override must drive the scrobble percent.
        let (sut, _, _, scrobbler, _) = makeSUT()
        await sut.report(event: .stop, isPaused: true, positionOverride: 900)
        let scrobbles = await scrobbler.calls
        XCTAssertEqual(scrobbles.first?.progress ?? -1, 90, accuracy: 0.001)
    }

    // MARK: defer-until-started

    func testStateChangeBeforeStartIsDeferredThenFlushedWhenDifferent() async {
        let (sut, _, provider, _, _) = makeSUT()
        // A pause arrives before .start — must NOT report yet.
        sut.reportStateChange(paused: true)
        await Task.yield()
        var events = await provider.events
        XCTAssertTrue(events.isEmpty, "a state change before start must be deferred")

        // Start unpaused → flush the deferred pause (differs from started state).
        await sut.reportStart(isPaused: false, positionOverride: 0)
        events = await provider.events
        XCTAssertEqual(events.map(\.event), [.start, .pause])
    }

    func testDeferredStateMatchingStartIsNotReplayed() async {
        let (sut, _, provider, _, _) = makeSUT()
        sut.reportStateChange(paused: true)
        // Start ALSO paused → nothing to replay.
        await sut.reportStart(isPaused: true, positionOverride: 0)
        let events = await provider.events
        XCTAssertEqual(events.map(\.event), [.start], "a deferred state equal to the start state isn't replayed")
    }

    func testStateChangeAfterStartReportsImmediately() async {
        let (sut, _, provider, _, _) = makeSUT()
        await sut.reportStart(isPaused: false, positionOverride: 0)
        sut.reportStateChange(paused: true)
        // reportStateChange spawns a Task; poll until it lands.
        let events = await waitForEvents(provider, count: 2)
        XCTAssertEqual(events.map(\.event), [.start, .pause])
    }

    // MARK: checkpoint dedup + guards

    func testCheckpointFiresOnForwardProgressAndDedupes() async {
        let (sut, host, _, _, recorder) = makeSUT()
        sut.startCheckpointLoop(seedPosition: 100) // seed, loop off (interval 0)
        host.resumePosition = 100
        sut.emitCheckpoint()
        XCTAssertEqual(recorder.positions, [], "no forward progress past the seed → no checkpoint")

        host.resumePosition = 250
        sut.emitCheckpoint()
        XCTAssertEqual(recorder.positions, [250], "forward progress fires one checkpoint")

        sut.emitCheckpoint() // same position again
        XCTAssertEqual(recorder.positions, [250], "same position must not re-enqueue (dedup)")

        host.resumePosition = 250.5 // sub-1s advance
        sut.emitCheckpoint()
        XCTAssertEqual(recorder.positions, [250], "a sub-1s advance is below the dedup threshold")
    }

    func testCheckpointSuppressedWhilePausedUnlessForced() async {
        let (sut, host, _, _, recorder) = makeSUT()
        sut.startCheckpointLoop(seedPosition: 0)
        host.resumePosition = 300
        host.engineIsPaused = true
        sut.emitCheckpoint() // includingPaused defaults false
        XCTAssertEqual(recorder.positions, [], "a paused player must not checkpoint on the timer path")

        sut.checkpointNow() // includingPaused = true
        XCTAssertEqual(recorder.positions, [300], "an explicit checkpoint (background) fires even while paused")
    }

    func testCheckpointNoOpWithoutRequest() async {
        let (sut, host, _, _, recorder) = makeSUT()
        host.request = nil
        host.resumePosition = 400
        sut.checkpointNow()
        XCTAssertEqual(recorder.positions, [], "no active request → no checkpoint")
    }
}

// MARK: - Spies

@MainActor
private final class SpyReporterHost: WatchProgressReporterHost {
    var engineCurrentTime: TimeInterval = 0
    var engineDuration: TimeInterval = 0
    var engineIsPaused = false
    var controlsDuration: TimeInterval = 0
    var request: PlaybackRequest?
    var resumePosition: TimeInterval = 0

    var reporterEngineCurrentTime: TimeInterval { engineCurrentTime }
    var reporterEngineDuration: TimeInterval { engineDuration }
    var reporterEngineIsPaused: Bool { engineIsPaused }
    var reporterControlsDuration: TimeInterval { controlsDuration }
    var reporterRequest: PlaybackRequest? { request }
    var reporterResumePosition: TimeInterval { resumePosition }
}

private actor RecordingProvider: MediaProvider {
    struct Reported {
        let event: PlaybackEvent
        let position: TimeInterval
        let isPaused: Bool
    }
    private(set) var events: [Reported] = []

    nonisolated let kind: ProviderKind = .jellyfin
    nonisolated let session = UserSession(
        server: MediaServer(
            id: "s", name: "S",
            baseURL: URL(string: "https://example.test")!, provider: .jellyfin
        ),
        userID: "u", userName: "U", deviceID: "d", accessToken: "t"
    )

    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {
        events.append(Reported(event: event, position: progress.positionSeconds, isPaused: progress.isPaused))
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
    nonisolated func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}

private actor RecordingScrobbler: TraktScrobbling {
    struct Call {
        let event: PlaybackEvent
        let progress: Double
    }
    private(set) var calls: [Call] = []

    func scrobble(item: MediaItem, progress: Double, event: PlaybackEvent) async {
        calls.append(Call(event: event, progress: progress))
    }
}

private final class CheckpointRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _positions: [TimeInterval] = []

    var positions: [TimeInterval] {
        lock.lock(); defer { lock.unlock() }
        return _positions
    }

    func record(position: TimeInterval, percent: Double) {
        lock.lock(); _positions.append(position); lock.unlock()
    }
}
#endif
