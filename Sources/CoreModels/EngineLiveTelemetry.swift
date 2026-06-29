import Foundation

/// Live, per-tick decode/render stats an engine can publish for the diagnostics
/// overlay. Engines without an `AVPlayer` (Plozzigen/mpv) have no access log, so
/// the sampler reads these instead to fill dropped frames, observed FPS, and
/// bitrate — otherwise those fields would stay `-` on every non-native engine.
public struct EngineLiveTelemetry: Equatable, Sendable {
    /// Cumulative dropped video frames since playback started.
    public var droppedFrameCount: Int?
    /// Frames the engine is actually presenting right now (frames/sec).
    public var observedFps: Double?
    /// Instantaneous stream bitrate in bits/sec (overlay-normalised; engines that
    /// only know Mbps multiply by 1_000_000 before publishing).
    public var observedBitrate: Double?

    public init(droppedFrameCount: Int? = nil, observedFps: Double? = nil, observedBitrate: Double? = nil) {
        self.droppedFrameCount = droppedFrameCount
        self.observedFps = observedFps
        self.observedBitrate = observedBitrate
    }
}
