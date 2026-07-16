import Foundation

/// Real, per-file technical facts obtained by PROBING a file's own headers —
/// independent of any provider/server metadata. This is how the app gets accurate
/// resolution / dynamic range / audio for SMB shares, which carry no server-side
/// description. Codable so it can be persisted in the per-file cache.
///
/// Every field is optional and asserted only when the probe actually resolved it:
/// a `nil` means "not known", and the UI must render nothing for it rather than
/// guessing. Notably, the Dolby Vision *profile number* is NOT carried here (the
/// engine's header probe can say "this is Dolby Vision" but does not reliably
/// resolve profile 5 vs 8.1), so DoVi is surfaced for DISPLAY only, never fed into
/// playback-compatibility prediction.
public struct ProbedStreamFacts: Codable, Hashable, Sendable {
    public var videoWidth: Int?
    public var videoHeight: Int?
    /// Provider-agnostic dynamic-range token (matches Jellyfin's vocabulary the rest
    /// of the app uses): "SDR" / "HDR10" / "HDR10Plus" / "HLG" / "DOVI". nil = unknown.
    public var videoRangeType: String?
    public var videoCodec: String?
    public var audioCodec: String?
    public var audioChannels: Int?
    public var audioIsAtmos: Bool
    public var durationSeconds: Double?

    public init(
        videoWidth: Int? = nil,
        videoHeight: Int? = nil,
        videoRangeType: String? = nil,
        videoCodec: String? = nil,
        audioCodec: String? = nil,
        audioChannels: Int? = nil,
        audioIsAtmos: Bool = false,
        durationSeconds: Double? = nil
    ) {
        self.videoWidth = videoWidth
        self.videoHeight = videoHeight
        self.videoRangeType = videoRangeType
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.audioChannels = audioChannels
        self.audioIsAtmos = audioIsAtmos
        self.durationSeconds = durationSeconds
    }
}

public extension MediaSourceMetadata {
    /// Additively records an authoritative Atmos confirmation without changing
    /// any other provider-supplied stream facts.
    func confirmingAtmos() -> MediaSourceMetadata {
        var copy = self
        if var audio = copy.audio {
            audio.profile = "Dolby Atmos"
            copy.audio = audio
        }
        return copy
    }
}

public extension MediaItem {
    /// Additively records an authoritative Atmos confirmation on the item and
    /// its default version so detail, picker, and playback surfaces agree.
    func confirmingAtmos() -> MediaItem {
        var copy = self
        if let mediaInfo = copy.mediaInfo {
            copy.mediaInfo = mediaInfo.confirmingAtmos()
        }
        copy.versions = copy.versions.map { version in
            var version = version
            guard version.isDefault else { return version }
            version.audioProfile = "Dolby Atmos"
            if let sourceMetadata = version.sourceMetadata {
                version.sourceMetadata = sourceMetadata.confirmingAtmos()
            }
            return version
        }
        return copy
    }
}

/// Probes a credential-free network file's headers for real stream facts.
/// Implemented by the engine layer and injected into providers so transport
/// packages never depend on the demuxer. Must run off the main actor.
public protocol NetworkFileStreamProbing: Sendable {
    /// Resolve `locator`, read its headers, and return the probed facts — or nil
    /// if the probe failed/timed out (the caller then shows nothing, never a guess).
    func probe(locator: NetworkFileLocator) async -> ProbedStreamFacts?
}

/// Probes a managed provider's credential-free authenticated HTTP locator.
/// Implementations resolve credentials only at the I/O boundary; the locator
/// and returned facts remain secret-free.
public protocol AuthenticatedHTTPStreamProbing: Sendable {
    func probe(locator: AuthenticatedHTTPPlaybackLocator) async -> ProbedStreamFacts?
}

/// Optional provider capability for delayed, authoritative stream inspection.
/// Detail pages invoke this only after first paint and never await it for Play.
public protocol SupplementalStreamFactsProviding: Sendable {
    func supplementalStreamFacts(for item: MediaItem) async -> ProbedStreamFacts?
}
