import Foundation

/// Stream facts an engine can read from its OWN probe of the source, independent
/// of any provider (server) metadata. This is what makes accurate diagnostics
/// possible for sources that carry no server-side description — chiefly raw SMB
/// shares, where there is no Plex/Jellyfin `MediaSource` to describe the file.
///
/// The engine (AetherEngine/Plozzigen) demuxes the file to play it, so it already
/// knows the real dynamic range (that's how it drives the panel's Dolby Vision
/// switch), the audio codec/layout, and the coded dimensions. Surfacing those
/// here lets the diagnostics overlay show the *truth* for SMB instead of nothing
/// — or worse, a defaulted "SDR".
///
/// Every field is optional: the engine publishes only what it has actually
/// probed. A `nil` field means "not known yet", and the overlay must show nothing
/// for it rather than guessing (better to have nothing than the wrong thing).
public struct EngineProbedSourceFacts: Equatable, Sendable {
    /// The source's real dynamic range, as detected by the engine's demuxer.
    /// Deliberately does NOT carry a Dolby Vision *profile* number: single-layer
    /// engines detect "this is Dolby Vision" without reliably resolving 5 vs 8.1,
    /// so we surface "Dolby Vision" without asserting a profile.
    public var range: SourceDynamicRange?
    public var videoWidth: Int?
    public var videoHeight: Int?
    public var videoDecoder: String?
    public var audioCodec: String?
    public var audioChannels: Int?
    public var audioIsAtmos: Bool
    public var audioDecoder: String?

    public init(
        range: SourceDynamicRange? = nil,
        videoWidth: Int? = nil,
        videoHeight: Int? = nil,
        videoDecoder: String? = nil,
        audioCodec: String? = nil,
        audioChannels: Int? = nil,
        audioIsAtmos: Bool = false,
        audioDecoder: String? = nil
    ) {
        self.range = range
        self.videoWidth = videoWidth
        self.videoHeight = videoHeight
        self.videoDecoder = videoDecoder
        self.audioCodec = audioCodec
        self.audioChannels = audioChannels
        self.audioIsAtmos = audioIsAtmos
        self.audioDecoder = audioDecoder
    }
}
