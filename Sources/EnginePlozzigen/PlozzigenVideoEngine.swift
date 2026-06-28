#if canImport(AVFoundation)
import Foundation
import AVFoundation
import Combine
import CoreModels
import FeaturePlayback
#if canImport(UIKit)
import UIKit
#endif
@preconcurrency import AetherEngine

// The module and main class are both named "AetherEngine", so we typealias
// the class to avoid ambiguity. All other public types (LoadOptions,
// AetherPlayerView, etc.) are resolved from the module import directly.
private typealias AEEngine = AetherEngine

/// `VideoEngine` implementation backed by AetherEngine (branded "Plozzigen").
///
/// AetherEngine handles the full native pipeline internally:
/// FFmpeg demux → on-device copy-remux → localhost HLS-fMP4 → AVPlayer.
/// This gives us: Dolby Vision, Atmos passthrough, full-timeline seek,
/// bounded memory (segment cache + backpressure), and producer-restart seek.
///
/// This adapter maps AetherEngine's published state to Plozz's `VideoEngine`
/// protocol so it plugs into the existing `PlayerViewModel` / routing
/// infrastructure without changes to the rest of the app.
@MainActor
public final class PlozzigenVideoEngine: VideoEngine {

    // MARK: - VideoEngine State

    public private(set) var status: VideoEngineStatus = .idle
    public private(set) var isPaused: Bool = true
    public private(set) var furthestObservedPosition: TimeInterval = 0
    public private(set) var audioTracks: [MediaTrack] = []
    public private(set) var subtitleTracks: [MediaTrack] = []

    public var currentTime: TimeInterval { engine.currentTime }
    public var duration: TimeInterval { engine.duration }
    public var bufferedPosition: TimeInterval { engine.clock.bufferedPosition }

    public var preventsDisplaySleep: Bool {
        engine.state == .playing
    }

    public var displayName: String { "Plozzigen" }

    public var capabilities: PlayerEngineCapabilities {
        [.playbackSpeed]
    }

    // MARK: - Callbacks

    public var onProgress: (@MainActor () -> Void)?
    public var onFailure: (@MainActor (AppError) -> Void)?
    public var onEnded: (@MainActor () -> Void)?

    // MARK: - Private

    private let engine: AEEngine
    private var cancellables = Set<AnyCancellable>()
    private var progressTimer: Task<Void, Never>?
    #if canImport(UIKit)
    private let videoView: UIView
    #endif

    // MARK: - Init

    public init() throws {
        self.engine = try AEEngine()
        #if canImport(UIKit)
        let surface = AetherPlayerView()
        engine.bind(view: surface)
        self.videoView = surface
        #endif
        observeEngine()
    }

    // MARK: - VideoEngine Lifecycle

    public func load(request: PlaybackRequest, startPosition: TimeInterval) async {
        status = .loading
        isPaused = false
        furthestObservedPosition = startPosition

        // Prefer the original range-readable URL (MKV bytes with embedded auth)
        // for sources that have a localRemuxSource descriptor; AetherEngine
        // handles the remux pipeline internally. Fall back to streamURL for
        // standard HLS / direct-play URLs.
        let url = request.localRemuxSource?.originalURL ?? request.streamURL

        let options = LoadOptions(
            matchContentEnabled: true
        )

        do {
            try await engine.load(
                url: url,
                startPosition: startPosition > 0 ? startPosition : nil,
                options: options
            )
            engine.play()
            // Track lists are published by AetherEngine after load completes.
            syncTracks()
        } catch {
            let err: AppError = .unknown(error.localizedDescription)
            status = .failed(err)
            onFailure?(err)
        }
    }

    public func play() {
        engine.play()
        isPaused = false
    }

    public func pause() {
        engine.pause()
        isPaused = true
    }

    public func seek(to seconds: TimeInterval) async {
        await engine.seek(to: seconds)
    }

    public func seek(to seconds: TimeInterval, kind: VideoSeekKind) async {
        await engine.seek(to: seconds)
    }

    public func stop() {
        progressTimer?.cancel()
        progressTimer = nil
        engine.stop()
        status = .idle
        isPaused = true
    }

    // MARK: - Tunables

    public func setPlaybackSpeed(_ rate: Double) {
        engine.setRate(Float(rate))
    }

    public func setAudioDelay(_ seconds: TimeInterval) {}
    public func setSubtitleDelay(_ seconds: TimeInterval) {}
    public func setDialogEnhanceEnabled(_ enabled: Bool) {}

    // MARK: - Tracks

    public func selectAudioTrack(_ track: MediaTrack?) {
        guard let track else { return }
        engine.selectAudioTrack(index: track.id)
    }

    public func selectSubtitleTrack(_ track: MediaTrack?) {
        if let track {
            engine.selectSubtitleTrack(index: track.id)
        } else {
            engine.clearSubtitle()
        }
    }

    // MARK: - View

    #if canImport(UIKit)
    public func makeVideoOutputView() -> UIView {
        videoView
    }
    #endif

    // MARK: - Engine Observation (Combine)

    private func observeEngine() {
        // State → status/isPaused/onEnded/onFailure
        engine.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                switch state {
                case .idle:
                    break
                case .loading:
                    self.status = .loading
                case .playing:
                    self.isPaused = false
                    self.status = .ready
                    self.startProgressTimer()
                case .paused:
                    self.isPaused = true
                    if self.status != .ready { self.status = .ready }
                case .seeking:
                    break
                case .ended:
                    self.onEnded?()
                case .error(let msg):
                    let err: AppError = .unknown(msg)
                    self.status = .failed(err)
                    self.onFailure?(err)
                }
            }
            .store(in: &cancellables)

        // Track furthest observed position from clock ticks
        engine.clock.$currentTime
            .receive(on: DispatchQueue.main)
            .sink { [weak self] time in
                guard let self else { return }
                if time > self.furthestObservedPosition {
                    self.furthestObservedPosition = time
                }
            }
            .store(in: &cancellables)

        // Sync track lists when AetherEngine publishes them
        engine.$audioTracks
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncTracks() }
            .store(in: &cancellables)
        engine.$subtitleTracks
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncTracks() }
            .store(in: &cancellables)
    }

    private func startProgressTimer() {
        guard progressTimer == nil else { return }
        progressTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { break }
                self?.onProgress?()
            }
        }
    }

    private func syncTracks() {
        audioTracks = engine.audioTracks.map { track in
            MediaTrack(
                id: track.id,
                kind: .audio,
                displayTitle: track.name,
                language: track.language,
                isDefault: track.isDefault
            )
        }
        subtitleTracks = engine.subtitleTracks.map { track in
            MediaTrack(
                id: track.id,
                kind: .subtitle,
                displayTitle: track.name,
                language: track.language,
                isDefault: track.isDefault
            )
        }
    }
}

// MARK: - Factory

public enum PlozzigenVideoEngineFactory {
    @MainActor
    public static func makeEngine() -> (any VideoEngine)? {
        try? PlozzigenVideoEngine()
    }
}
#endif
