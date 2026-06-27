#if canImport(AVFoundation)
import Foundation
import CoreModels
import FeaturePlayback

/// Cue-driven, on-demand, minimal-footprint local remux engine.
///
/// On `preparePlayback()` it: range-reads the MKV head, parses Info/Tracks plus
/// the Cues (following the SeekHead to the tail when Cues live at EOF), computes
/// the **entire** keyframe-aligned segment timeline up front, opens the FFmpeg
/// `-c copy` remuxer, captures the CMAF init segment, and starts a loopback HTTP
/// server that vends a complete VOD playlist. Each media segment is produced on
/// demand from a single range read — no disk cache. Because the playlist declares
/// the full timeline immediately, AVPlayer's seekable range is the whole movie and
/// a far seek resolves to an already-listed segment that the app serves locally —
/// it can never 404 against an on-demand server transcoder.
struct CueDrivenLocalRemuxStreamer: LocalRemuxStreamer {
    let strategy = LocalRemuxStrategyChoice.cueLocalhostHLS

    @MainActor
    func openSession(source: LocalRemuxSourceDescriptor) async throws -> any LocalRemuxStreamingSession {
        CueDrivenLocalRemuxSession(source: source, strategy: strategy)
    }
}

@MainActor
final class CueDrivenLocalRemuxSession: LocalRemuxStreamingSession {
    let strategy: LocalRemuxStrategyChoice
    let metricsController: LocalRemuxMetricsController
    private let source: LocalRemuxSourceDescriptor
    private var backend: CueDrivenRemuxBackend?
    private var pollTask: Task<Void, Never>?

    init(source: LocalRemuxSourceDescriptor, strategy: LocalRemuxStrategyChoice) {
        self.source = source
        self.strategy = strategy
        self.metricsController = LocalRemuxMetricsController(strategy: strategy)
    }

    func preparePlayback() async throws -> LocalRemuxPreparedStream {
        let source = self.source
        // All blocking work (network range reads + FFmpeg) happens off the main
        // actor; only the returned, Sendable backend crosses back.
        let backend = try await Task.detached(priority: .userInitiated) {
            try CueDrivenRemuxBackend.build(source: source)
        }.value

        self.backend = backend
        startMetricsPolling(backend: backend)

        return LocalRemuxPreparedStream(
            playbackURL: backend.playbackURL,
            isManifestStream: true,
            deliveryMode: .localRemux
        )
    }

    func teardown() async {
        pollTask?.cancel()
        pollTask = nil
        backend?.shutdown()
        backend = nil
    }

    /// Pushes the backend's atomic byte / segment counters into the shared metrics
    /// controller so the Remux overlay reflects live local-serving activity. Kept on
    /// the main actor and reading a Sendable snapshot avoids capturing main-actor
    /// state inside the `@Sendable` server closures.
    private func startMetricsPolling(backend: CueDrivenRemuxBackend) {
        let metrics = metricsController
        pollTask = Task { @MainActor in
            while !Task.isCancelled {
                let snapshot = backend.metricsSnapshot()
                metrics.updateStrategyMetrics(
                    segmentCount: snapshot.segmentsServed,
                    bytesPulled: snapshot.bytesPulled,
                    cacheDiskBytes: 0,
                    cacheMemoryBytes: snapshot.memoryBytes
                )
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }
    }
}
#endif
