#if canImport(AVFoundation)
import XCTest
import CoreModels
@testable import FeaturePlayback
#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class PlayerViewModelEOFTests: XCTestCase {
    func testStopAfterNaturalEndStillWritesFinalFurthestPosition() async {
        let item = MediaItem(id: "movie", title: "Movie", kind: .movie, runtime: 120)
        let request = PlaybackRequest(
            item: item,
            streamURL: URL(string: "https://example.test/movie.m3u8")!
        )
        let provider = RecordingPlaybackProvider(request: request)
        let engine = SpyVideoEngine()
        let stopped = PlaybackStoppedRecorder()
        let viewModel = PlayerViewModel(
            provider: provider,
            itemID: item.id,
            engineFactory: EngineFactory(makeNative: { _ in engine }),
            onPlaybackStopped: { position, percent in
                stopped.record(position: position, percent: percent)
            }
        )

        await viewModel.load()
        engine.duration = 120
        engine.furthestObservedPosition = 120
        engine.currentTime = 0
        engine.onEnded?()

        await viewModel.stop()

        let reports = await provider.reports
        XCTAssertEqual(reports.map(\.event.rawValue), ["start", "stop"])
        XCTAssertEqual(reports.last?.progress.positionSeconds, 120)
        XCTAssertEqual(reports.last?.progress.durationSeconds, 120)
        XCTAssertEqual(stopped.onlyCall?.position, 120)
        XCTAssertEqual(stopped.onlyCall?.percent, 100)
    }

    func testForcedCheckpointCapturesPausedPosition() async {
        let item = MediaItem(id: "movie", title: "Movie", kind: .movie, runtime: 120)
        let request = PlaybackRequest(
            item: item,
            streamURL: URL(string: "https://example.test/movie.m3u8")!
        )
        let provider = RecordingPlaybackProvider(request: request)
        let engine = SpyVideoEngine()
        let checkpoints = PlaybackStoppedRecorder()
        let viewModel = PlayerViewModel(
            provider: provider,
            itemID: item.id,
            engineFactory: EngineFactory(makeNative: { _ in engine }),
            onPlaybackCheckpoint: { position, percent in
                checkpoints.record(position: position, percent: percent)
            }
        )
        await viewModel.load()
        engine.duration = 120
        engine.currentTime = 30
        engine.furthestObservedPosition = 30
        engine.isPaused = true

        viewModel.checkpointNow()

        XCTAssertEqual(checkpoints.onlyCall?.position, 30)
        XCTAssertEqual(checkpoints.onlyCall?.percent, 25)
    }

    func testInactiveOnlyPauseDoesNotReloadEngine() async {
        let (viewModel, engine, _) = makeViewModel()
        await viewModel.load()

        viewModel.suspendForBackground()
        await viewModel.resumeAfterBackground()

        XCTAssertEqual(engine.reloadAfterForegroundCount, 0)
        XCTAssertTrue(engine.isPaused)
    }

    func testForegroundReturnReloadsOnceAndRemainsPaused() async {
        let (viewModel, engine, provider) = makeViewModel()
        await viewModel.load()
        engine.currentTime = 30

        viewModel.didEnterBackground()
        await viewModel.resumeAfterBackground()
        await viewModel.resumeAfterBackground()
        for _ in 0..<10 { await Task.yield() }

        XCTAssertEqual(engine.reloadAfterForegroundCount, 1)
        XCTAssertTrue(engine.isPaused)
        XCTAssertTrue(viewModel.controls.isPaused)
        let reports = await provider.reports
        XCTAssertEqual(reports.map(\.event.rawValue), ["start", "pause"])
    }

    func testBackgroundDuringBringUpReportsPausedStartBeforeRecovery() async {
        let (viewModel, engine, provider) = makeViewModel()

        viewModel.didEnterBackground()
        await viewModel.load()
        await viewModel.resumeAfterBackground()
        for _ in 0..<10 { await Task.yield() }

        XCTAssertEqual(engine.reloadAfterForegroundCount, 1)
        XCTAssertTrue(engine.isPaused)
        let reports = await provider.reports
        XCTAssertEqual(reports.map(\.event.rawValue), ["start"])
        XCTAssertEqual(reports.first?.progress.isPaused, true)
    }

    func testStopAfterRewindUsesCurrentPositionInsteadOfFurthest() async {
        let item = MediaItem(id: "movie", title: "Movie", kind: .movie, runtime: 600)
        let request = PlaybackRequest(
            item: item,
            streamURL: URL(string: "https://example.test/movie.m3u8")!
        )
        let provider = RecordingPlaybackProvider(request: request)
        let engine = SpyVideoEngine()
        let stopped = PlaybackStoppedRecorder()
        let viewModel = PlayerViewModel(
            provider: provider,
            itemID: item.id,
            engineFactory: EngineFactory(makeNative: { _ in engine }),
            onPlaybackStopped: { position, percent in
                stopped.record(position: position, percent: percent)
            }
        )
        await viewModel.load()
        engine.duration = 600
        engine.furthestObservedPosition = 427
        engine.currentTime = 120

        await viewModel.stop()

        let reports = await provider.reports
        XCTAssertEqual(stopped.onlyCall?.position, 120)
        XCTAssertEqual(stopped.onlyCall?.percent, 20)
        XCTAssertEqual(reports.last?.progress.positionSeconds, 120)
    }

    func testNetworkFileFailureReplacesPlozzigenOnceAndIgnoresOldCallback() async throws {
        let item = MediaItem(id: "movie", title: "Movie", kind: .movie, runtime: 120)
        let identity = try RemoteFileIdentity(
            kind: .strongETag,
            value: "\"movie-v1\""
        )
        let representation = try RemoteFileRepresentation(
            size: 1_024,
            identity: identity,
            consistency: .stronglyBound
        )
        let locator = try NetworkFileLocator(
            accountID: "account",
            sourceID: "source",
            credentialRevision: CredentialRevision(),
            relativePath: "Movies/Movie.mkv",
            representation: representation,
            formatHint: MediaFormatHint(
                container: "mkv",
                mimeType: "video/x-matroska"
            )
        )
        let request = PlaybackRequest(
            item: item,
            playbackSource: .networkFile(locator)
        )
        let provider = RecordingPlaybackProvider(request: request)
        let native = SpyVideoEngine()
        var plozzigenEngines: [SpyVideoEngine] = []
        let factory = EngineFactory(
            makeNative: { _ in native },
            makePlozzigen: {
                let engine = SpyVideoEngine()
                plozzigenEngines.append(engine)
                return engine
            }
        )
        let viewModel = PlayerViewModel(
            provider: provider,
            itemID: item.id,
            engineFactory: factory
        )

        await viewModel.load()
        XCTAssertEqual(plozzigenEngines.count, 1)
        let staleFailure = try XCTUnwrap(plozzigenEngines[0].onFailure)
        let staleFacts = try XCTUnwrap(plozzigenEngines[0].onProbedSourceFactsChanged)
        staleFacts(EngineProbedSourceFacts(range: .dolbyVision))
        let firstTransitionToken = viewModel.dynamicRangeTransitionToken

        staleFailure(.invalidResponse)
        for _ in 0..<50
        where plozzigenEngines.count < 2 || plozzigenEngines[1].loadCount < 1 {
            await Task.yield()
        }

        XCTAssertEqual(plozzigenEngines.count, 2)
        XCTAssertEqual(plozzigenEngines[0].stopCount, 1)
        XCTAssertEqual(plozzigenEngines[1].loadCount, 1)
        XCTAssertNotEqual(viewModel.dynamicRangeTransitionToken, firstTransitionToken)
        XCTAssertEqual(viewModel.inheritedPreservedDynamicRange, .dolbyVision)

        staleFacts(EngineProbedSourceFacts(range: .dolbyVision))
        XCTAssertEqual(
            viewModel.effectiveDynamicRange,
            .awaitingEngineProbe(hint: nil)
        )
        plozzigenEngines[1].onProbedSourceFactsChanged?(
            EngineProbedSourceFacts(range: .hlg)
        )
        XCTAssertEqual(
            viewModel.effectiveDynamicRange,
            .resolved(.hlg, authority: .engineProbe)
        )

        staleFailure(.unknown("late old-engine failure"))
        await Task.yield()
        XCTAssertEqual(plozzigenEngines.count, 2)

        plozzigenEngines[1].onFailure?(.invalidResponse)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(plozzigenEngines.count, 2)

        await viewModel.stop()
    }

    func testDirectFileWaitsForProbeAndAcceptsEveryHDRRange() async throws {
        for range in [
            SourceDynamicRange.dolbyVision,
            .hdr10,
            .hdr10Plus,
            .hlg,
        ] {
            let request = try makeNetworkFileRequest()
            let provider = RecordingPlaybackProvider(request: request)
            let plozzigen = SpyVideoEngine()
            let viewModel = PlayerViewModel(
                provider: provider,
                itemID: request.item.id,
                engineFactory: EngineFactory(
                    makeNative: { _ in SpyVideoEngine() },
                    makePlozzigen: { plozzigen }
                )
            )

            await viewModel.load()
            XCTAssertEqual(
                viewModel.effectiveDynamicRange,
                .awaitingEngineProbe(hint: nil)
            )
            XCTAssertTrue(viewModel.requiresHDRExitVeil)

            plozzigen.onProbedSourceFactsChanged?(
                EngineProbedSourceFacts(range: range)
            )

            XCTAssertEqual(
                viewModel.effectiveDynamicRange,
                .resolved(range, authority: .engineProbe)
            )
            XCTAssertTrue(viewModel.requiresHDRExitVeil)
            XCTAssertTrue(viewModel.controls.subtitlesRenderHDR)
            let playbackInfoCalls = await provider.playbackInfoCallCount
            let itemCalls = await provider.itemCallCount
            XCTAssertEqual(playbackInfoCalls, 1)
            XCTAssertEqual(itemCalls, 0)
            await viewModel.stop()
        }
    }

    func testEngineProbeCorrectsProviderHDRHintToSDR() async throws {
        let request = try makeNetworkFileRequest(
            metadata: MediaSourceMetadata(video: .init(videoRangeType: "HDR10"))
        )
        let provider = RecordingPlaybackProvider(request: request)
        let plozzigen = SpyVideoEngine()
        let viewModel = PlayerViewModel(
            provider: provider,
            itemID: request.item.id,
            engineFactory: EngineFactory(
                makeNative: { _ in SpyVideoEngine() },
                makePlozzigen: { plozzigen }
            )
        )

        await viewModel.load()
        XCTAssertEqual(
            viewModel.effectiveDynamicRange,
            .awaitingEngineProbe(hint: .hdr10)
        )

        plozzigen.onProbedSourceFactsChanged?(
            EngineProbedSourceFacts(range: .sdr)
        )

        XCTAssertEqual(
            viewModel.effectiveDynamicRange,
            .resolved(.sdr, authority: .engineProbe)
        )
        XCTAssertFalse(viewModel.requiresHDRExitVeil)
        XCTAssertFalse(viewModel.controls.subtitlesRenderHDR)
        await viewModel.stop()
    }

    func testUnavailablePlozzigenFallsBackToNativeRangeTruth() async throws {
        let request = try makeNetworkFileRequest()
        let provider = RecordingPlaybackProvider(request: request)
        let native = SpyVideoEngine()
        let viewModel = PlayerViewModel(
            provider: provider,
            itemID: request.item.id,
            engineFactory: EngineFactory(
                makeNative: { _ in native },
                makePlozzigen: { nil }
            )
        )

        await viewModel.load()

        XCTAssertEqual(
            viewModel.effectiveDynamicRange,
            .resolved(.sdr, authority: .nativeFallback)
        )
        XCTAssertFalse(viewModel.effectiveDynamicRange.isAwaitingEngineProbe)
        await viewModel.stop()
    }

    func testStopDuringPreCommitYieldDoesNotCreateReplacementEngine() async throws {
        let request = try makeNetworkFileRequest()
        let provider = RecordingPlaybackProvider(request: request)
        let native = SpyVideoEngine()
        var plozzigenEngines: [SpyVideoEngine] = []
        let gate = PreCommitYieldGate()
        let viewModel = PlayerViewModel(
            provider: provider,
            itemID: request.item.id,
            engineFactory: EngineFactory(
                makeNative: { _ in native },
                makePlozzigen: {
                    let engine = SpyVideoEngine()
                    plozzigenEngines.append(engine)
                    return engine
                }
            )
        )
        viewModel.preEngineCommitYield = { await gate.suspend() }

        let loadTask = Task { await viewModel.load() }
        await waitForGate(gate, entries: 1)
        await viewModel.stop()
        gate.releaseNext()
        await loadTask.value

        XCTAssertTrue(plozzigenEngines.isEmpty)
        XCTAssertEqual(native.loadCount, 0)
        XCTAssertEqual(native.stopCount, 1)
        XCTAssertEqual(native.status, .idle)
        XCTAssertNil(native.onProbedSourceFactsChanged)
    }

    func testNewGenerationSupersedesLoadDuringPreCommitYield() async throws {
        let request = try makeNetworkFileRequest()
        let provider = RecordingPlaybackProvider(request: request)
        let native = SpyVideoEngine()
        var plozzigenEngines: [SpyVideoEngine] = []
        let gate = PreCommitYieldGate()
        let viewModel = PlayerViewModel(
            provider: provider,
            itemID: request.item.id,
            engineFactory: EngineFactory(
                makeNative: { _ in native },
                makePlozzigen: {
                    let engine = SpyVideoEngine()
                    plozzigenEngines.append(engine)
                    return engine
                }
            )
        )
        viewModel.preEngineCommitYield = { await gate.suspend() }

        let staleLoad = Task { await viewModel.load() }
        await waitForGate(gate, entries: 1)
        let currentLoad = Task { await viewModel.load() }
        await waitForGate(gate, entries: 2)

        gate.releaseNext()
        await staleLoad.value
        XCTAssertTrue(plozzigenEngines.isEmpty)
        XCTAssertEqual(native.stopCount, 0)

        gate.releaseNext()
        await currentLoad.value
        XCTAssertEqual(plozzigenEngines.count, 1)
        XCTAssertEqual(plozzigenEngines[0].loadCount, 1)
        XCTAssertNotNil(plozzigenEngines[0].onProbedSourceFactsChanged)
        XCTAssertEqual(native.stopCount, 1)
        await viewModel.stop()
    }

    func testSameRangeHandoffUsesAuthoritativePrefetchProbeAndFallsBackToKnownHint() async throws {
        let request = try makeNetworkFileRequest()
        let provider = RecordingPlaybackProvider(request: request)
        let plozzigen = SpyVideoEngine()
        let viewModel = PlayerViewModel(
            provider: provider,
            itemID: request.item.id,
            engineFactory: EngineFactory(
                makeNative: { _ in SpyVideoEngine() },
                makePlozzigen: { plozzigen }
            )
        )
        await viewModel.load()
        plozzigen.onProbedSourceFactsChanged?(
            EngineProbedSourceFacts(range: .dolbyVision)
        )

        let knownNext = PlayerViewModel.PrefetchedPlayback(
            itemID: "next",
            request: PlaybackRequest(
                item: MediaItem(id: "next", title: "Next", kind: .episode),
                streamURL: URL(string: "https://example.test/next.mkv")!,
                sourceMetadata: MediaSourceMetadata(
                    video: .init(videoRangeType: "DOVI")
                )
            ),
            engineKind: .plozzigen
        )
        let unknownNext = PlayerViewModel.PrefetchedPlayback(
            itemID: "unknown",
            request: PlaybackRequest(
                item: MediaItem(id: "unknown", title: "Unknown", kind: .episode),
                streamURL: URL(string: "https://example.test/unknown.mkv")!
            ),
            engineKind: .plozzigen
        )

        XCTAssertTrue(viewModel.shouldPreserveDisplayMode(forNext: knownNext))
        XCTAssertFalse(viewModel.shouldPreserveDisplayMode(forNext: unknownNext))

        let probedNext = PlayerViewModel.PrefetchedPlayback(
            itemID: "probed",
            request: unknownNext.request,
            engineKind: .plozzigen,
            prefetchedDynamicRange: .dolbyVision
        )
        let mismatchedNext = PlayerViewModel.PrefetchedPlayback(
            itemID: "mismatched",
            request: unknownNext.request,
            engineKind: .plozzigen,
            prefetchedDynamicRange: .hdr10
        )
        let authoritativeSDRNext = PlayerViewModel.PrefetchedPlayback(
            itemID: "sdr",
            request: unknownNext.request,
            engineKind: .plozzigen,
            prefetchedDynamicRange: .sdr
        )
        XCTAssertTrue(viewModel.shouldPreserveDisplayMode(forNext: probedNext))
        XCTAssertFalse(viewModel.shouldPreserveDisplayMode(forNext: mismatchedNext))
        XCTAssertFalse(viewModel.shouldPreserveDisplayMode(forNext: authoritativeSDRNext))

        for range in [
            SourceDynamicRange.hdr10,
            .hdr10Plus,
            .hlg
        ] {
            plozzigen.onProbedSourceFactsChanged?(
                EngineProbedSourceFacts(range: range)
            )
            let sameDisplayClassNext = PlayerViewModel.PrefetchedPlayback(
                itemID: "probed-\(range.rawValue)",
                request: unknownNext.request,
                engineKind: .plozzigen,
                prefetchedDynamicRange: range
            )
            XCTAssertTrue(
                viewModel.shouldPreserveDisplayMode(forNext: sameDisplayClassNext),
                "Expected \(range.rawValue) handoff to preserve display criteria"
            )
        }
        await viewModel.stop()

        let inherited = probedNext.inheritingPreservedDisplayMode(true)
        let incomingEngine = SpyVideoEngine()
        let incoming = PlayerViewModel(
            provider: RecordingPlaybackProvider(request: probedNext.request),
            itemID: probedNext.itemID,
            engineFactory: EngineFactory(
                makeNative: { _ in SpyVideoEngine() },
                makePlozzigen: { incomingEngine }
            ),
            adoptedResolved: inherited
        )
        await incoming.load()
        XCTAssertTrue(incoming.inheritsPreservedDisplayMode)
        XCTAssertEqual(
            incoming.effectiveDynamicRange,
            .awaitingEngineProbe(hint: nil)
        )
        XCTAssertEqual(incoming.inheritedPreservedDynamicRange, .dolbyVision)
        await incoming.stop()
    }

    func testDirectFilePrefetchHeaderProbesRangeWithoutMetadataEnrichment() async throws {
        let current = try makeNetworkFileRequest(
            itemID: "current",
            title: "Episode 1",
            kind: .episode,
            relativePath: "Shows/Show/S01E01.mkv"
        )
        let next = try makeNetworkFileRequest(
            itemID: "next",
            title: "Episode 2",
            kind: .episode,
            relativePath: "Shows/Show/S01E02.mkv"
        )
        let provider = RecordingPlaybackProvider(
            request: current,
            kind: .mediaShare,
            requestsByItemID: ["next": next]
        )
        let rangeProbe = RangeProbeRecorder(result: .dolbyVision)
        let viewModel = PlayerViewModel(
            provider: provider,
            itemID: current.item.id,
            engineFactory: EngineFactory(
                makeNative: { _ in SpyVideoEngine() },
                makePlozzigen: { SpyVideoEngine() },
                probeSourceDynamicRange: { request in
                    await rangeProbe.probe(request)
                }
            ),
            neighborResolver: { (nil, next.item) }
        )

        await waitForPrefetchedNext(viewModel)

        XCTAssertEqual(viewModel.prefetchedNext?.itemID, next.item.id)
        XCTAssertEqual(
            viewModel.prefetchedNext?.prefetchedDynamicRange,
            .dolbyVision
        )
        let rangeProbeCallCount = await rangeProbe.callCount()
        let rangeProbeLastItemID = await rangeProbe.lastItemID()
        let providerItemCallCount = await provider.itemCallCountValue()
        XCTAssertEqual(rangeProbeCallCount, 1)
        XCTAssertEqual(rangeProbeLastItemID, next.item.id)
        XCTAssertEqual(providerItemCallCount, 0)
        await viewModel.stop()
    }

    func testCancelledDirectFilePrefetchProbeCannotPublishRange() async throws {
        let current = try makeNetworkFileRequest(
            itemID: "current",
            title: "Episode 1",
            kind: .episode,
            relativePath: "Shows/Show/S01E01.mkv"
        )
        let next = try makeNetworkFileRequest(
            itemID: "next",
            title: "Episode 2",
            kind: .episode,
            relativePath: "Shows/Show/S01E02.mkv"
        )
        let provider = RecordingPlaybackProvider(
            request: current,
            kind: .mediaShare,
            requestsByItemID: ["next": next]
        )
        let gate = RangeProbeGate(result: .dolbyVision)
        let viewModel = PlayerViewModel(
            provider: provider,
            itemID: current.item.id,
            engineFactory: EngineFactory(
                makeNative: { _ in SpyVideoEngine() },
                makePlozzigen: { SpyVideoEngine() },
                probeSourceDynamicRange: { request in
                    await gate.probe(request)
                }
            ),
            neighborResolver: { (nil, next.item) }
        )
        await gate.waitUntilEntered()

        await viewModel.stop()
        await gate.release()
        for _ in 0..<100 {
            await Task.yield()
        }

        XCTAssertNil(viewModel.prefetchedNext)
    }

    func testCancelledPrefetchProbeReleasesResolvedNonIdempotentSession() async throws {
        let current = try makeNetworkFileRequest(
            itemID: "current",
            title: "Episode 1",
            kind: .episode,
            relativePath: "Shows/Show/S01E01.mkv",
            playSessionID: "current-session"
        )
        let next = try makeNetworkFileRequest(
            itemID: "next",
            title: "Episode 2",
            kind: .episode,
            relativePath: "Shows/Show/S01E02.mkv",
            playSessionID: "next-session"
        )
        let provider = RecordingPlaybackProvider(
            request: current,
            kind: .jellyfin,
            requestsByItemID: ["next": next]
        )
        let gate = RangeProbeGate(result: .dolbyVision)
        let engine = SpyVideoEngine()
        let viewModel = PlayerViewModel(
            provider: provider,
            itemID: current.item.id,
            engineFactory: EngineFactory(
                makeNative: { _ in SpyVideoEngine() },
                makePlozzigen: { engine },
                probeSourceDynamicRange: { request in
                    await gate.probe(request)
                }
            ),
            neighborResolver: { (nil, next.item) }
        )
        await viewModel.load()
        await waitForNextEpisode(viewModel)
        engine.duration = 120
        engine.currentTime = 60
        engine.onProgress?()
        await gate.waitUntilEntered()

        await viewModel.stop()
        await gate.release()
        let released = await waitForReport(
            provider,
            itemID: next.item.id,
            event: .stop
        )

        XCTAssertTrue(released)
        XCTAssertNil(viewModel.prefetchedNext)
    }

    func testForegroundReloadRetainsAuthoritativeProbeTruth() async throws {
        let request = try makeNetworkFileRequest()
        let provider = RecordingPlaybackProvider(request: request)
        let plozzigen = SpyVideoEngine()
        let viewModel = PlayerViewModel(
            provider: provider,
            itemID: request.item.id,
            engineFactory: EngineFactory(
                makeNative: { _ in SpyVideoEngine() },
                makePlozzigen: { plozzigen }
            )
        )
        await viewModel.load()
        plozzigen.onProbedSourceFactsChanged?(
            EngineProbedSourceFacts(range: .hdr10)
        )

        viewModel.didEnterBackground()
        await viewModel.resumeAfterBackground()

        XCTAssertEqual(
            viewModel.effectiveDynamicRange,
            .resolved(.hdr10, authority: .engineProbe)
        )
        await viewModel.stop()
    }

    private func waitForGate(
        _ gate: PreCommitYieldGate,
        entries: Int
    ) async {
        for _ in 0..<1_000 where gate.entryCount < entries {
            await Task.yield()
        }
        XCTAssertEqual(gate.entryCount, entries)
    }

    private func makeNetworkFileRequest(
        metadata: MediaSourceMetadata? = nil,
        itemID: String = "movie",
        title: String = "Movie",
        kind: MediaItemKind = .movie,
        relativePath: String = "Movies/Movie.mkv",
        playSessionID: String? = nil
    ) throws -> PlaybackRequest {
        let identity = try RemoteFileIdentity(
            kind: .strongETag,
            value: "\"movie-v1\""
        )
        let representation = try RemoteFileRepresentation(
            size: 1_024,
            identity: identity,
            consistency: .stronglyBound
        )
        let locator = try NetworkFileLocator(
            accountID: "account",
            sourceID: "source",
            credentialRevision: CredentialRevision(),
            relativePath: relativePath,
            representation: representation,
            formatHint: MediaFormatHint(
                container: "mkv",
                mimeType: "video/x-matroska"
            )
        )
        return PlaybackRequest(
            item: MediaItem(id: itemID, title: title, kind: kind, runtime: 120),
            playbackSource: .networkFile(locator),
            playSessionID: playSessionID,
            sourceMetadata: metadata
        )
    }

    private func waitForPrefetchedNext(_ viewModel: PlayerViewModel) async {
        for _ in 0..<1_000 where viewModel.prefetchedNext == nil {
            await Task.yield()
        }
        XCTAssertNotNil(viewModel.prefetchedNext)
    }

    private func waitForNextEpisode(_ viewModel: PlayerViewModel) async {
        for _ in 0..<1_000 where viewModel.nextEpisode == nil {
            await Task.yield()
        }
        XCTAssertNotNil(viewModel.nextEpisode)
    }

    private func waitForReport(
        _ provider: RecordingPlaybackProvider,
        itemID: String,
        event: PlaybackEvent
    ) async -> Bool {
        for _ in 0..<1_000 {
            if await provider.hasReport(itemID: itemID, event: event) {
                return true
            }
            await Task.yield()
        }
        return false
    }

    private func makeViewModel() -> (
        PlayerViewModel,
        SpyVideoEngine,
        RecordingPlaybackProvider
    ) {
        let item = MediaItem(id: "movie", title: "Movie", kind: .movie, runtime: 120)
        let request = PlaybackRequest(
            item: item,
            streamURL: URL(string: "https://example.test/movie.m3u8")!
        )
        let provider = RecordingPlaybackProvider(request: request)
        let engine = SpyVideoEngine()
        let viewModel = PlayerViewModel(
            provider: provider,
            itemID: item.id,
            engineFactory: EngineFactory(makeNative: { _ in engine })
        )
        return (viewModel, engine, provider)
    }
}

@MainActor
private final class PreCommitYieldGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private(set) var entryCount = 0

    func suspend() async {
        entryCount += 1
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func releaseNext() {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume()
    }
}

private actor RecordingPlaybackProvider: MediaProvider {
    struct Report: Sendable {
        let event: PlaybackEvent
        let progress: PlaybackProgress
    }

    nonisolated let kind: ProviderKind
    nonisolated let session = UserSession(
        server: MediaServer(
            id: "server",
            name: "Server",
            baseURL: URL(string: "https://example.test")!,
            provider: .jellyfin
        ),
        userID: "user",
        userName: "User",
        deviceID: "device",
        accessToken: "token"
    )

    private let request: PlaybackRequest
    private let requestsByItemID: [String: PlaybackRequest]
    private(set) var reports: [Report] = []
    private(set) var playbackInfoCallCount = 0
    private(set) var itemCallCount = 0

    init(
        request: PlaybackRequest,
        kind: ProviderKind = .jellyfin,
        requestsByItemID: [String: PlaybackRequest] = [:]
    ) {
        self.request = request
        self.kind = kind
        self.requestsByItemID = requestsByItemID
    }

    func libraries() async throws -> [MediaLibrary] { [] }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func item(id: String) async throws -> MediaItem {
        itemCallCount += 1
        return requestsByItemID[id]?.item ?? request.item
    }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        MediaPage(items: [], startIndex: page.startIndex, totalCount: 0)
    }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest {
        playbackInfoCallCount += 1
        return requestsByItemID[itemID] ?? request
    }
    func playbackInfo(for itemID: String, mediaSourceID: String?, forceTranscode: Bool) async throws -> PlaybackRequest {
        playbackInfoCallCount += 1
        return requestsByItemID[itemID] ?? request
    }

    func itemCallCountValue() -> Int { itemCallCount }
    func hasReport(itemID: String, event: PlaybackEvent) -> Bool {
        reports.contains {
            $0.progress.itemID == itemID && $0.event == event
        }
    }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {
        reports.append(Report(event: event, progress: progress))
    }
    nonisolated func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}

private actor RangeProbeRecorder {
    private let result: SourceDynamicRange?
    private var requests: [PlaybackRequest] = []

    init(result: SourceDynamicRange?) {
        self.result = result
    }

    func probe(_ request: PlaybackRequest) -> SourceDynamicRange? {
        requests.append(request)
        return result
    }

    func callCount() -> Int { requests.count }
    func lastItemID() -> String? { requests.last?.item.id }
}

private actor RangeProbeGate {
    private let result: SourceDynamicRange?
    private var didEnter = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(result: SourceDynamicRange?) {
        self.result = result
    }

    func probe(_ request: PlaybackRequest) async -> SourceDynamicRange? {
        _ = request
        didEnter = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        return result
    }

    func waitUntilEntered() async {
        while !didEnter {
            await Task.yield()
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class SpyVideoEngine: VideoEngine {
    let displayName = "spy"
    var status: VideoEngineStatus = .idle
    var isPaused = false
    var preventsDisplaySleep = false
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0
    var furthestObservedPosition: TimeInterval = 0
    var audioTracks: [MediaTrack] = []
    var subtitleTracks: [MediaTrack] = []
    var onProgress: (@MainActor () -> Void)?
    var onFailure: (@MainActor (AppError) -> Void)?
    var onEnded: (@MainActor () -> Void)?
    var onTracksChanged: (@MainActor () -> Void)?
    var onProbedSourceFactsChanged: (@MainActor (EngineProbedSourceFacts) -> Void)?
    var onSubtitleCues: (@MainActor ([SubtitleCue]) -> Void)?
    var onSecondarySubtitleCues: (@MainActor ([SubtitleCue]) -> Void)?
    var loadCount = 0
    var stopCount = 0
    var reloadAfterForegroundCount = 0

    func load(request: PlaybackRequest, startPosition: TimeInterval) async {
        loadCount += 1
        status = .ready
        currentTime = startPosition
        furthestObservedPosition = max(furthestObservedPosition, startPosition)
    }

    func play() { isPaused = false }
    func pause() { isPaused = true }
    func reloadAfterForeground() async throws {
        reloadAfterForegroundCount += 1
    }
    func seek(to seconds: TimeInterval) async {
        currentTime = seconds
        furthestObservedPosition = max(furthestObservedPosition, seconds)
    }
    func stop() {
        stopCount += 1
        status = .idle
        duration = 0
    }
    func selectAudioTrack(_ track: MediaTrack?) {}
    func selectSubtitleTrack(_ track: MediaTrack?) {}

    #if canImport(UIKit)
    func makeVideoOutputView() -> UIView { UIView() }
    #endif
}

private final class PlaybackStoppedRecorder: @unchecked Sendable {
    struct Call {
        let position: TimeInterval
        let percent: Double
    }

    private let lock = NSLock()
    private var calls: [Call] = []

    var onlyCall: Call? {
        lock.lock()
        defer { lock.unlock() }
        XCTAssertEqual(calls.count, 1)
        return calls.first
    }

    func record(position: TimeInterval, percent: Double) {
        lock.lock()
        calls.append(Call(position: position, percent: percent))
        lock.unlock()
    }
}
#endif
