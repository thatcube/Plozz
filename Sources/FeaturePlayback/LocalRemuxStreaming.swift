#if canImport(AVFoundation)
import Foundation
import CoreModels

/// The AVPlayer-facing output a local-remux strategy prepared from the original
/// bytes. Strategies are free to vend localhost HLS, a custom-scheme asset, or a
/// cached manifest as long as AVPlayer can consume the returned URL.
@MainActor
public struct LocalRemuxPreparedStream: Sendable {
    public var playbackURL: URL
    public var isManifestStream: Bool
    public var deliveryMode: PlaybackDiagnostics.PlaybackMode

    public init(
        playbackURL: URL,
        isManifestStream: Bool,
        deliveryMode: PlaybackDiagnostics.PlaybackMode = .localRemux
    ) {
        self.playbackURL = playbackURL
        self.isManifestStream = isManifestStream
        self.deliveryMode = deliveryMode
    }
}

/// Shared mutable metrics tracker every local-remux strategy can update. The
/// player owns seek / first-frame / harness timing; the strategy owns byte / cache
/// / segment counters. Sibling branches can plug a new engine into the same
/// recorder and get identical diagnostics + torture-test scoring immediately.
@MainActor
public final class LocalRemuxMetricsController {
    private let strategy: LocalRemuxStrategyChoice
    private let sessionStartedAt = Date()
    private var pendingSeekStartedAt: Date?
    private var harnessStartedAt: Date?
    private var snapshotStorage: PlaybackDiagnostics.RemuxDiagnostics

    public init(strategy: LocalRemuxStrategyChoice) {
        self.strategy = strategy
        self.snapshotStorage = PlaybackDiagnostics.RemuxDiagnostics(
            strategyID: strategy.id,
            strategyName: strategy.displayName
        )
    }

    public var snapshot: PlaybackDiagnostics.RemuxDiagnostics { snapshotStorage }

    public func recordFirstFrameIfNeeded() {
        guard snapshotStorage.timeToFirstFrameMs == nil else { return }
        snapshotStorage.timeToFirstFrameMs = milliseconds(since: sessionStartedAt)
    }

    public func beginSeek() {
        pendingSeekStartedAt = Date()
    }

    public func endSeek() {
        guard let pendingSeekStartedAt else { return }
        snapshotStorage.lastSeekLatencyMs = milliseconds(since: pendingSeekStartedAt)
        self.pendingSeekStartedAt = nil
    }

    public func updateStallCount(_ count: Int?) {
        guard let count, count >= 0 else { return }
        snapshotStorage.stallCount = max(snapshotStorage.stallCount ?? 0, count)
    }

    public func updateStrategyMetrics(
        segmentCount: Int? = nil,
        bytesPulled: Int64? = nil,
        cacheDiskBytes: Int64? = nil,
        cacheMemoryBytes: Int64? = nil
    ) {
        if let segmentCount, segmentCount >= 0 {
            snapshotStorage.segmentCount = segmentCount
        }
        if let bytesPulled, bytesPulled >= 0 {
            snapshotStorage.bytesPulled = bytesPulled
        }
        if let cacheDiskBytes, cacheDiskBytes >= 0 {
            snapshotStorage.cacheDiskBytes = cacheDiskBytes
        }
        if let cacheMemoryBytes, cacheMemoryBytes >= 0 {
            snapshotStorage.cacheMemoryBytes = cacheMemoryBytes
        }
    }

    public func setHarnessRunning(step: String) {
        if harnessStartedAt == nil {
            harnessStartedAt = Date()
        }
        snapshotStorage.harnessState = .running
        snapshotStorage.harnessStep = step
    }

    public func finishHarness(success: Bool, summary: String) {
        let startedAt = harnessStartedAt ?? Date()
        let finishedAt = Date()
        snapshotStorage.harnessState = success ? .passed : .failed
        snapshotStorage.harnessStep = nil
        snapshotStorage.lastHarnessResult = .init(
            state: success ? .passed : .failed,
            summary: summary,
            startedAt: startedAt,
            finishedAt: finishedAt
        )
        harnessStartedAt = nil
    }

    public func resetHarnessState() {
        snapshotStorage.harnessState = .idle
        snapshotStorage.harnessStep = nil
        harnessStartedAt = nil
    }

    private func milliseconds(since date: Date) -> Int {
        Int((Date().timeIntervalSince(date) * 1000).rounded())
    }
}

@MainActor
public protocol LocalRemuxStreamingSession: AnyObject {
    var strategy: LocalRemuxStrategyChoice { get }
    var metricsController: LocalRemuxMetricsController { get }
    func preparePlayback() async throws -> LocalRemuxPreparedStream
    func teardown() async
}

public protocol LocalRemuxStreamer: Sendable {
    var strategy: LocalRemuxStrategyChoice { get }
    @MainActor
    func openSession(source: LocalRemuxSourceDescriptor) async throws -> any LocalRemuxStreamingSession
}

/// Reference seam that keeps the current provider AVPlayer URL in place while
/// still routing through the shared local-remux registry, controls, and metrics.
/// Sibling branches can replace this with a true local engine without changing the
/// player/diagnostics contract.
struct ReferenceServerRemuxLocalRemuxStreamer: LocalRemuxStreamer {
    let strategy = LocalRemuxStrategyChoice.referenceServerRemux

    @MainActor
    func openSession(source: LocalRemuxSourceDescriptor) async throws -> any LocalRemuxStreamingSession {
        ReferenceServerRemuxLocalRemuxSession(source: source, strategy: strategy)
    }
}

@MainActor
final class ReferenceServerRemuxLocalRemuxSession: LocalRemuxStreamingSession {
    let strategy: LocalRemuxStrategyChoice
    let metricsController: LocalRemuxMetricsController
    private let source: LocalRemuxSourceDescriptor

    init(source: LocalRemuxSourceDescriptor, strategy: LocalRemuxStrategyChoice) {
        self.source = source
        self.strategy = strategy
        self.metricsController = LocalRemuxMetricsController(strategy: strategy)
    }

    func preparePlayback() async throws -> LocalRemuxPreparedStream {
        guard let playbackURL = source.referencePlaybackURL else {
            throw AppError.notFound
        }
        guard playbackURL.pathExtension.lowercased() == "m3u8" else {
            throw AppError.invalidResponse
        }
        return LocalRemuxPreparedStream(
            playbackURL: playbackURL,
            isManifestStream: true,
            deliveryMode: .localRemux
        )
    }

    func teardown() async {}
}

/// The single registry sibling remux branches plug into. Add a new strategy id +
/// factory here, then expose its counters through `LocalRemuxMetricsController`,
/// and the diagnostics overlay / torture harness pick it up automatically.
///
/// Engine modules that link FFmpeg (e.g. EngineMPV) cannot be referenced from this
/// FFmpeg-free module, so they contribute their streamer at launch via
/// `register(choice:factory:)`. The *choice* half lives in CoreModels
/// (`LocalRemuxStrategyChoice.registerDynamic`) so persistence and display-name
/// resolution recognise it; the *factory* half is held here.
public enum LocalRemuxStrategyRegistry {
    /// Thread-safe id → streamer-factory store for dynamically-registered engines.
    private final class FactoryStore: @unchecked Sendable {
        static let shared = FactoryStore()
        private let lock = NSLock()
        private var factories: [String: @Sendable () -> any LocalRemuxStreamer] = [:]

        func register(id: String, factory: @escaping @Sendable () -> any LocalRemuxStreamer) {
            lock.lock(); defer { lock.unlock() }
            factories[id] = factory
        }

        func factory(for id: String) -> (@Sendable () -> any LocalRemuxStreamer)? {
            lock.lock(); defer { lock.unlock() }
            return factories[id]
        }
    }

    public static var availableChoices: [LocalRemuxStrategyChoice] {
        LocalRemuxStrategyChoice.allChoices
    }

    /// Contribute an engine: registers the user-visible choice (CoreModels) and the
    /// factory used to build the streamer when that id is selected. Idempotent by
    /// id, so calling it again at a later launch simply refreshes the entry.
    public static func register(
        choice: LocalRemuxStrategyChoice,
        factory: @escaping @Sendable () -> any LocalRemuxStreamer
    ) {
        LocalRemuxStrategyChoice.registerDynamic(choice)
        FactoryStore.shared.register(id: choice.id, factory: factory)
    }

    public static func makeStreamer(for strategyID: String) -> (any LocalRemuxStreamer)? {
        switch strategyID {
        case LocalRemuxStrategyChoice.referenceServerRemuxID:
            return ReferenceServerRemuxLocalRemuxStreamer()
        default:
            return FactoryStore.shared.factory(for: strategyID)?()
        }
    }
}
#endif
