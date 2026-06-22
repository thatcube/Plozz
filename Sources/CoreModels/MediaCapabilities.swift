import Foundation
#if canImport(VideoToolbox)
import VideoToolbox
#endif
#if canImport(AVFoundation)
import AVFoundation
#endif

// MARK: - MediaCapabilities
//
// The single source of truth for "what can the running Apple TV (and the
// display / audio gear plugged into it) actually play?" Both providers consume
// this so that direct-play / transcode decisions are made the same way:
//
//   * `ProviderJellyfin.JellyfinCapabilityProfile` builds the Jellyfin
//     `DeviceProfile` (DirectPlay/Codec profiles, `VideoRangeType`,
//     `MaxAudioChannels`) from the policy helpers below — `allowedHDRRanges`
//     map 1:1 onto Jellyfin `VideoRangeType` strings (the enum `rawValue`s),
//     `allowedDirectPlayVideoCodecs` feed the DirectPlay `VideoCodec` lists, and
//     `recommendedMaxAudioChannels` replaces the hard-coded `"8"`.
//   * `ProviderPlex.PlexClient.canDirectPlay` checks a candidate stream's video
//     codec against `allowedDirectPlayVideoCodecs` and its audio codec against
//     `allowedPassthroughAudioCodecs` (+ the always-decodable lossy set) instead
//     of its own private static sets.
//
// Design rules (so this stays the shared foundation):
//   * `CoreModels` has **no** module dependencies and must compile on Linux/CI,
//     so every VideoToolbox / AVFoundation probe is guarded by `canImport` and
//     OS checks, with a conservative `.default` used everywhere a probe is
//     unavailable.
//   * The *policy* helpers (`allowedHDRRanges`, `allowedPassthroughAudioCodecs`,
//     `allowedDirectPlayVideoCodecs`, `recommendedMaxAudioChannels`) are pure,
//     dependency-free, and therefore unit-testable on Linux with injected
//     capabilities — no hardware required.
//   * Everything is `Sendable` (strict concurrency complete). This layer does no
//     logging by design (it sits below `PlozzLog`, which lives in
//     `CoreNetworking`); it also never touches secrets.

/// A snapshot of what the running device — together with the currently connected
/// display and audio output — can decode and present.
///
/// Construct one explicitly (for deterministic tests) or call ``detected()`` to
/// probe the real hardware. Use ``default`` on platforms where probing is
/// unavailable (Linux/CI).
public struct MediaCapabilities: Sendable, Equatable {

    // MARK: Video decode

    /// Hardware HEVC (H.265) decode. True on every Apple TV 4K.
    public var supportsHEVC: Bool
    /// Hardware AV1 decode. Only the A15-class Apple TV 4K (3rd gen) on
    /// tvOS 16+ advertises this.
    public var supportsAV1: Bool

    // MARK: Display HDR

    /// The connected display accepts an HDR10 (PQ) signal.
    public var supportsHDR10: Bool
    /// The connected display accepts an HLG signal.
    public var supportsHLG: Bool
    /// The connected display accepts Dolby Vision.
    ///
    /// **Policy:** Apple only supports Dolby Vision **Profile 5** (single-layer
    /// IPT-PQ-C2) and **Profile 8** (single-layer cross-compatible). Profile 7
    /// (dual-layer FEL/MEL, common in UHD Blu-ray rips) is **not** decodable and
    /// must fall through to a transcode — see ``allowedHDRRanges``.
    public var supportsDolbyVision: Bool

    // MARK: Audio output

    /// Maximum output channel count the current audio route advertises (e.g. 2
    /// for stereo/optical, 6 for 5.1, 8 for 7.1). Drives
    /// ``recommendedMaxAudioChannels`` instead of a hard-coded value.
    public var maxOutputChannels: Int
    /// Dolby Atmos is reachable on the current route (E-AC-3 JOC / passthrough).
    public var supportsAtmos: Bool
    /// The current route can passthrough DTS / DTS-HD bitstreams to an external
    /// decoder (AV receiver). Apple TV cannot itself decode DTS, so this is the
    /// **only** thing that makes DTS direct-play viable — see
    /// ``allowedPassthroughAudioCodecs``.
    public var supportsDTSPassthrough: Bool

    public init(
        supportsHEVC: Bool = true,
        supportsAV1: Bool = false,
        supportsHDR10: Bool = true,
        supportsHLG: Bool = true,
        supportsDolbyVision: Bool = false,
        maxOutputChannels: Int = 2,
        supportsAtmos: Bool = false,
        supportsDTSPassthrough: Bool = false
    ) {
        self.supportsHEVC = supportsHEVC
        self.supportsAV1 = supportsAV1
        self.supportsHDR10 = supportsHDR10
        self.supportsHLG = supportsHLG
        self.supportsDolbyVision = supportsDolbyVision
        self.maxOutputChannels = max(2, maxOutputChannels)
        self.supportsAtmos = supportsAtmos
        self.supportsDTSPassthrough = supportsDTSPassthrough
    }

    /// A conservative profile used where the hardware can't be probed (Linux CI,
    /// or before an audio route is established). HEVC + HDR10/HLG are assumed
    /// (true of every Apple TV 4K); AV1, Dolby Vision, Atmos, DTS passthrough and
    /// multichannel output are **not** assumed.
    public static let `default` = MediaCapabilities()
}

// MARK: - Supporting value types

/// A display HDR signal range. `rawValue`s are deliberately the exact Jellyfin
/// `VideoRangeType` tokens so a provider can map them with zero translation.
///
/// Note the deliberate omissions: there is **no** `hdr10Plus` case (Apple TV
/// cannot display HDR10+; it is played as its HDR10 base layer), and the only
/// Dolby Vision cases are Profile 5 (``dolbyVision``) and the Profile 8
/// cross-compatible variants — Profile 7 is unsupported.
public enum HDRRange: String, Sendable, Equatable, CaseIterable {
    case sdr = "SDR"
    case hlg = "HLG"
    case hdr10 = "HDR10"
    /// Dolby Vision **Profile 5** (IPT-PQ-C2, no cross-compatible base layer).
    case dolbyVision = "DOVI"
    /// Dolby Vision **Profile 8.1** (HDR10-compatible base layer).
    case dolbyVisionWithHDR10 = "DOVIWithHDR10"
    /// Dolby Vision **Profile 8.4** (HLG-compatible base layer).
    case dolbyVisionWithHLG = "DOVIWithHLG"
    /// Dolby Vision **Profile 8.2** (SDR-compatible base layer).
    case dolbyVisionWithSDR = "DOVIWithSDR"
}

/// Audio codecs that can be sent untouched to the output (the device decodes
/// them itself, or passes the bitstream through to an external decoder).
/// `rawValue`s match the lowercase codec tokens both providers already use.
public enum PassthroughAudioCodec: String, Sendable, Equatable, CaseIterable {
    case ac3
    case eac3
    case dts
    case dtsHD = "dts-hd"
}

/// Video codecs eligible for direct play (native AVFoundation decode). H.264 is
/// always present; HEVC/AV1 are gated on hardware support. `rawValue`s match the
/// lowercase codec tokens both providers already use.
public enum DirectPlayVideoCodec: String, Sendable, Equatable, CaseIterable {
    case h264
    case hevc
    case av1
}

// MARK: - Policy helpers (pure, dependency-free, Linux-testable)

extension MediaCapabilities {
    /// The HDR ranges this device/display combination may receive directly.
    ///
    /// Always includes ``HDRRange/sdr``. HLG and HDR10 are added when the display
    /// supports them. Dolby Vision contributes **only** Profile 5 + the Profile 8
    /// cross-compatible variants — never HDR10+ and never Profile 7.
    public var allowedHDRRanges: [HDRRange] {
        var ranges: [HDRRange] = [.sdr]
        if supportsHLG { ranges.append(.hlg) }
        if supportsHDR10 { ranges.append(.hdr10) }
        if supportsDolbyVision {
            ranges.append(contentsOf: [
                .dolbyVision,            // Profile 5
                .dolbyVisionWithHDR10,   // Profile 8.1
                .dolbyVisionWithHLG,     // Profile 8.4
                .dolbyVisionWithSDR      // Profile 8.2
            ])
        }
        return ranges
    }

    /// Audio codecs that may be direct-played as a bitstream. AC-3 and E-AC-3
    /// (the latter carrying Atmos as JOC) are always allowed; DTS / DTS-HD are
    /// allowed **only** when the route can passthrough them, since Apple TV
    /// cannot decode DTS itself.
    public var allowedPassthroughAudioCodecs: [PassthroughAudioCodec] {
        var codecs: [PassthroughAudioCodec] = [.ac3, .eac3]
        if supportsDTSPassthrough {
            codecs.append(contentsOf: [.dts, .dtsHD])
        }
        return codecs
    }

    /// Video codecs eligible for direct play. H.264 is always included; HEVC and
    /// AV1 are added only when the hardware decodes them.
    public var allowedDirectPlayVideoCodecs: [DirectPlayVideoCodec] {
        var codecs: [DirectPlayVideoCodec] = [.h264]
        if supportsHEVC { codecs.append(.hevc) }
        if supportsAV1 { codecs.append(.av1) }
        return codecs
    }

    /// The channel count to advertise to the server, derived from the live audio
    /// route rather than a hard-coded ceiling. Never below stereo.
    public var recommendedMaxAudioChannels: Int {
        max(2, maxOutputChannels)
    }
}

// MARK: - Hardware detection

extension MediaCapabilities {
    /// Probes the real hardware where possible and returns a populated profile.
    ///
    /// Video decode is probed via VideoToolbox (`VTIsHardwareDecodeSupported`);
    /// HDR display support tracks HEVC hardware decode (every Apple TV 4K that
    /// decodes HEVC also drives HDR10/HLG/Dolby Vision over HDMI). Audio output
    /// is a best-effort read of the current `AVAudioSession` route. On platforms
    /// without these frameworks (Linux/CI) it returns ``default``.
    public static func detected() -> MediaCapabilities {
        var caps = MediaCapabilities.default

        #if canImport(VideoToolbox)
        let hevc = VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)
        caps.supportsHEVC = hevc
        if #available(tvOS 16.0, iOS 16.0, macOS 13.0, *) {
            caps.supportsAV1 = VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)
        } else {
            caps.supportsAV1 = false
        }
        // HDR signalling over HDMI is gated on the same HEVC-capable pipeline.
        caps.supportsHDR10 = hevc
        caps.supportsHLG = hevc
        caps.supportsDolbyVision = hevc
        #endif

        #if canImport(AVFoundation) && (os(iOS) || os(tvOS) || os(watchOS) || os(visionOS))
        let channels = detectedMaxOutputChannels()
        caps.maxOutputChannels = channels
        // Best-effort: a >2-channel route implies a spatial-capable receiver, the
        // necessary (not sufficient) condition for Atmos via E-AC-3 JOC. There is
        // no public API that confirms Atmos directly, so we stay conservative.
        caps.supportsAtmos = channels > 2
        #endif

        return caps
    }

    #if canImport(AVFoundation) && (os(iOS) || os(tvOS) || os(watchOS) || os(visionOS))
    /// Best-effort maximum output channel count from the active audio session.
    private static func detectedMaxOutputChannels() -> Int {
        let session = AVAudioSession.sharedInstance()
        let sessionMax = session.maximumOutputNumberOfChannels
        let routeMax = session.currentRoute.outputs
            .map { $0.channels?.count ?? 0 }
            .max() ?? 0
        let channels = max(sessionMax, routeMax)
        return channels > 0 ? channels : 2
    }
    #endif
}
