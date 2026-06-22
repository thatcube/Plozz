import Foundation
import CoreModels

/// The Jellyfin **DeviceProfile** Plozz sends in the body of
/// `POST /Items/{id}/PlaybackInfo` so the server can decide, per media source,
/// whether Apple TV can *direct play* a file or whether it must be transcoded /
/// remuxed to a seekable HLS stream.
///
/// This is distinct from `JellyfinDeviceProfile`, which is only the device
/// *identity* carried in the `Authorization` header. This type describes
/// **codec/container capabilities** and mirrors Swiftfin's native (AVFoundation)
/// profile: AVPlayer can demux `mp4/m4v/mov/mpegts/3gp/avi` but **not** MKV, so
/// MKV (and any unsupported codec) falls through to the HLS transcoding profile.
///
/// Direct play is always preferred (best quality, no server CPU); transcoding is
/// the last-resort fallback. The HLS transcoding profile uses fMP4 segments with
/// `BreakOnNonKeyFrames`, which makes far-seeking reliable in `AVPlayer`.
public struct JellyfinCapabilityProfile: Encodable, Sendable, Equatable {
    public var maxStreamingBitrate: Int
    public var maxStaticBitrate: Int
    public var musicStreamingTranscodingBitrate: Int
    public var directPlayProfiles: [DirectPlayProfile]
    public var transcodingProfiles: [TranscodingProfile]
    public var codecProfiles: [CodecProfile]
    public var subtitleProfiles: [SubtitleProfile]

    enum CodingKeys: String, CodingKey {
        case maxStreamingBitrate = "MaxStreamingBitrate"
        case maxStaticBitrate = "MaxStaticBitrate"
        case musicStreamingTranscodingBitrate = "MusicStreamingTranscodingBitrate"
        case directPlayProfiles = "DirectPlayProfiles"
        case transcodingProfiles = "TranscodingProfiles"
        case codecProfiles = "CodecProfiles"
        case subtitleProfiles = "SubtitleProfiles"
    }
}

// MARK: - Builders

extension JellyfinCapabilityProfile {
    /// ~120 Mbit/s: enough headroom for high-bitrate 4K remuxes on a LAN while
    /// still capping pathological files.
    public static let defaultMaxBitrate = 120_000_000

    /// Builds the native (AVFoundation / `AVPlayer`) profile for Apple TV,
    /// mirroring Swiftfin's `.native` profile, from the shared
    /// ``CoreModels/MediaCapabilities`` source of truth.
    ///
    /// - Parameter hybridEngineEnabled: when `true`, the dual-engine (VLCKit)
    ///   build is active, so the profile additionally advertises the **extra**
    ///   direct-play formats the on-device hybrid engine can handle — the MKV /
    ///   WebM container (SDR and display-supported HDR10/HLG; only Dolby Vision
    ///   still transcodes so it reaches `AVPlayer`), AV1, and DTS / DTS-HD / TrueHD
    ///   audio (decoded on-device, no
    ///   passthrough required). Defaults to `false`, which emits **byte-for-byte**
    ///   the current native-only profile (non-regression). This must stay in
    ///   lockstep with `EngineRouter`: every extra format advertised here is one
    ///   the router sends to the hybrid engine.
    public static func appleTV(
        capabilities: MediaCapabilities = .default,
        hybridEngineEnabled: Bool = false,
        maxBitrate: Int = defaultMaxBitrate
    ) -> JellyfinCapabilityProfile {
        JellyfinCapabilityProfile(
            maxStreamingBitrate: maxBitrate,
            maxStaticBitrate: maxBitrate,
            musicStreamingTranscodingBitrate: 384_000,
            directPlayProfiles: directPlay(capabilities, hybrid: hybridEngineEnabled),
            transcodingProfiles: [transcoding(capabilities)],
            codecProfiles: codec(capabilities, hybrid: hybridEngineEnabled),
            subtitleProfiles: subtitles()
        )
    }

    /// Probes the real hardware/audio route via
    /// ``CoreModels/MediaCapabilities/detected()`` where available, otherwise
    /// falls back to ``CoreModels/MediaCapabilities/default``.
    public static func detected(
        hybridEngineEnabled: Bool = false,
        maxBitrate: Int = defaultMaxBitrate
    ) -> JellyfinCapabilityProfile {
        appleTV(capabilities: .detected(), hybridEngineEnabled: hybridEngineEnabled, maxBitrate: maxBitrate)
    }

    // MARK: Profile sections

    private static func directPlay(_ caps: MediaCapabilities, hybrid: Bool) -> [DirectPlayProfile] {
        let videoCodecs = caps.allowedDirectPlayVideoCodecs
        let supportsHEVC = videoCodecs.contains(.hevc)
        let supportsAV1 = videoCodecs.contains(.av1)

        var mp4Video = ["h264", "mpeg4"]
        if supportsHEVC { mp4Video.append("hevc") }
        if supportsAV1 { mp4Video.append("av1") }

        var movVideo = ["h264", "mjpeg", "mpeg4"]
        if supportsHEVC { movVideo.append("hevc") }

        var tsVideo = ["h264"]
        if supportsHEVC { tsVideo.append("hevc") }

        // DTS / DTS-HD only direct-play when the route can passthrough the
        // bitstream to an external decoder (Apple TV can't decode DTS itself).
        // `dca` is ffmpeg's alternate name for the DTS family. When the hybrid
        // engine is available it decodes DTS / DTS-HD / TrueHD on-device, so those
        // are advertised regardless of passthrough.
        let passthrough = caps.allowedPassthroughAudioCodecs
        let canBitstreamDTS = passthrough.contains(.dts) || passthrough.contains(.dtsHD)
        let dtsTokens = (hybrid || canBitstreamDTS) ? ["dts", "dca"] : []
        let trueHDTokens = hybrid ? ["truehd", "mlp"] : []

        func audio(_ base: [String], allowExtras: Bool) -> String {
            (allowExtras ? base + dtsTokens + trueHDTokens : base).joined(separator: ",")
        }

        var profiles = [
            DirectPlayProfile(
                type: "Video",
                container: "mp4,m4v",
                videoCodec: mp4Video.joined(separator: ","),
                audioCodec: audio(["aac", "ac3", "alac", "eac3", "flac", "mp3", "opus"], allowExtras: true)
            ),
            DirectPlayProfile(
                type: "Video",
                container: "mov",
                videoCodec: movVideo.joined(separator: ","),
                audioCodec: audio(["aac", "ac3", "alac", "eac3", "mp3", "pcm_s16be", "pcm_s16le", "pcm_s24be", "pcm_s24le"], allowExtras: true)
            ),
            DirectPlayProfile(
                type: "Video",
                container: "mpegts",
                videoCodec: tsVideo.joined(separator: ","),
                audioCodec: audio(["aac", "ac3", "eac3", "mp3"], allowExtras: true)
            ),
            DirectPlayProfile(
                type: "Video",
                container: "3gp,3g2",
                videoCodec: "h264,mpeg4",
                audioCodec: "aac,amr_nb"
            ),
            DirectPlayProfile(
                type: "Video",
                container: "avi",
                videoCodec: "mjpeg",
                audioCodec: "pcm_mulaw,pcm_s16le"
            ),
            DirectPlayProfile(type: "Audio", container: "m4a,m4b", audioCodec: "aac,alac"),
            DirectPlayProfile(type: "Audio", container: "mp3", audioCodec: "mp3"),
            DirectPlayProfile(type: "Audio", container: "flac", audioCodec: "flac")
        ]

        // Hybrid engine: advertise the Matroska / WebM container the on-device
        // VLCKit/mpv engine demuxes. The companion codec profiles
        // (see `codec(_:hybrid:)`) constrain MKV HEVC/AV1 to non-DoVi ranges so
        // Dolby Vision in an MKV still transcodes to HLS and renders on AVPlayer —
        // keeping the "DoVi always native" guarantee intact. HEVC and AV1 are
        // listed unconditionally here (not gated on hardware decode) because the
        // on-device engine software-decodes them regardless of VideoToolbox AV1
        // support, exactly as the router expects (MKV → hybrid).
        if hybrid {
            let mkvVideo = ["h264", "hevc", "mpeg4", "vc1", "mpeg2video", "vp8", "vp9", "av1"]
            let mkvAudio = [
                "aac", "ac3", "eac3", "dts", "dca", "truehd", "mlp",
                "flac", "alac", "mp3", "opus", "vorbis",
                "pcm_s16le", "pcm_s24le"
            ]
            profiles.append(
                DirectPlayProfile(
                    type: "Video",
                    container: "mkv,webm",
                    videoCodec: mkvVideo.joined(separator: ","),
                    audioCodec: mkvAudio.joined(separator: ",")
                )
            )
        }

        return profiles
    }

    private static func transcoding(_ caps: MediaCapabilities) -> TranscodingProfile {
        let allowed = caps.allowedDirectPlayVideoCodecs
        var videoCodecs = ["h264"]
        if allowed.contains(.hevc) { videoCodecs.insert("hevc", at: 0) }
        if allowed.contains(.av1) { videoCodecs.insert("av1", at: 0) }
        videoCodecs.append("mpeg4")

        return TranscodingProfile(
            type: "Video",
            container: "mp4",
            protocolName: "hls",
            context: "Streaming",
            videoCodec: videoCodecs.joined(separator: ","),
            audioCodec: "aac,ac3,alac,eac3,flac",
            breakOnNonKeyFrames: true,
            enableSubtitlesInManifest: true,
            minSegments: 2,
            maxAudioChannels: String(caps.recommendedMaxAudioChannels)
        )
    }

    private static func codec(_ caps: MediaCapabilities, hybrid: Bool) -> [CodecProfile] {
        let allowed = caps.allowedDirectPlayVideoCodecs
        var profiles: [CodecProfile] = [
            CodecProfile(type: "Video", codec: "h264", conditions: [
                ProfileCondition(condition: "NotEquals", property: "IsAnamorphic", value: "true", isRequired: false),
                ProfileCondition(condition: "EqualsAny", property: "VideoProfile", value: "high|main|baseline|constrained baseline", isRequired: false),
                ProfileCondition(condition: "LessThanEqual", property: "VideoLevel", value: "52", isRequired: false),
                ProfileCondition(condition: "NotEquals", property: "IsInterlaced", value: "true", isRequired: false)
            ])
        ]

        if allowed.contains(.hevc) {
            // VideoRangeType comes straight from the shared HDR policy: SDR plus
            // any supported HLG/HDR10, and (only when DoVi is supported) the
            // Profile 5 / Profile 8 cross-compatible tokens. This deliberately
            // omits HDR10Plus and Profile 7, which Apple TV cannot present.
            let ranges = caps.allowedHDRRanges.map(\.rawValue).joined(separator: "|")
            profiles.append(
                CodecProfile(type: "Video", codec: "hevc", conditions: [
                    ProfileCondition(condition: "NotEquals", property: "IsAnamorphic", value: "true", isRequired: false),
                    ProfileCondition(condition: "EqualsAny", property: "VideoProfile", value: "main|main 10", isRequired: false),
                    ProfileCondition(condition: "LessThanEqual", property: "VideoLevel", value: "183", isRequired: false),
                    ProfileCondition(condition: "NotEquals", property: "IsInterlaced", value: "true", isRequired: false),
                    ProfileCondition(condition: "EqualsAny", property: "VideoRangeType", value: ranges, isRequired: false)
                ])
            )
        }

        if allowed.contains(.av1) {
            profiles.append(
                CodecProfile(type: "Video", codec: "av1", conditions: [
                    ProfileCondition(condition: "NotEquals", property: "IsAnamorphic", value: "true", isRequired: false),
                    ProfileCondition(condition: "NotEquals", property: "IsInterlaced", value: "true", isRequired: false)
                ])
            )
        }

        // Hybrid engine: a raw MKV is decoded on-device by VLCKit/mpv, but Dolby
        // Vision must still render on AVPlayer. Constrain MKV/WebM HEVC and AV1 to
        // SDR + display-supported HDR10/HLG (everything EXCEPT Dolby Vision) so a
        // DoVi-in-MKV fails direct play and transcodes to an HLS stream AVPlayer
        // plays — these container-scoped profiles AND with the global codec
        // profiles above. HDR10/HLG MKV now direct-plays on the on-device engine
        // (matching Infuse) instead of forcing a server transcode.
        if hybrid {
            let mkvContainer = "mkv,webm"
            // The on-device engine handles HEVC/AV1 regardless of VideoToolbox AV1
            // support, but DoVi is excluded so it routes to AVPlayer via transcode.
            let mkvRanges = caps.allowedHDRRanges
                .filter { !$0.rawValue.uppercased().hasPrefix("DOVI") }
                .map(\.rawValue)
                .joined(separator: "|")
            profiles.append(
                CodecProfile(type: "Video", codec: "hevc", container: mkvContainer, conditions: [
                    ProfileCondition(condition: "EqualsAny", property: "VideoRangeType", value: mkvRanges, isRequired: false)
                ])
            )
            profiles.append(
                CodecProfile(type: "Video", codec: "av1", container: mkvContainer, conditions: [
                    ProfileCondition(condition: "EqualsAny", property: "VideoRangeType", value: mkvRanges, isRequired: false)
                ])
            )
        }

        return profiles
    }

    private static func subtitles() -> [SubtitleProfile] {
        [
            SubtitleProfile(format: "vtt", method: "Hls"),
            SubtitleProfile(format: "cc_dec", method: "Embed"),
            SubtitleProfile(format: "ttml", method: "Embed"),
            SubtitleProfile(format: "dvbsub", method: "Encode"),
            SubtitleProfile(format: "dvdsub", method: "Encode"),
            SubtitleProfile(format: "pgssub", method: "Encode"),
            SubtitleProfile(format: "xsub", method: "Encode")
        ]
    }
}

// MARK: - Profile element types

public struct DirectPlayProfile: Encodable, Sendable, Equatable {
    public var type: String
    public var container: String
    public var videoCodec: String?
    public var audioCodec: String?

    public init(type: String, container: String, videoCodec: String? = nil, audioCodec: String? = nil) {
        self.type = type
        self.container = container
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
    }

    enum CodingKeys: String, CodingKey {
        case type = "Type"
        case container = "Container"
        case videoCodec = "VideoCodec"
        case audioCodec = "AudioCodec"
    }
}

public struct TranscodingProfile: Encodable, Sendable, Equatable {
    public var type: String
    public var container: String
    public var protocolName: String
    public var context: String
    public var videoCodec: String
    public var audioCodec: String
    public var breakOnNonKeyFrames: Bool
    public var enableSubtitlesInManifest: Bool
    public var minSegments: Int
    public var maxAudioChannels: String

    enum CodingKeys: String, CodingKey {
        case type = "Type"
        case container = "Container"
        case protocolName = "Protocol"
        case context = "Context"
        case videoCodec = "VideoCodec"
        case audioCodec = "AudioCodec"
        case breakOnNonKeyFrames = "BreakOnNonKeyFrames"
        case enableSubtitlesInManifest = "EnableSubtitlesInManifest"
        case minSegments = "MinSegments"
        case maxAudioChannels = "MaxAudioChannels"
    }
}

public struct CodecProfile: Encodable, Sendable, Equatable {
    public var type: String
    public var codec: String
    /// Optional comma-separated container scope (e.g. `mkv,webm`). When set, the
    /// profile's conditions apply only to that codec **inside** those containers,
    /// letting the dual-engine build constrain MKV HEVC/AV1 to SDR without
    /// affecting the global (Apple-container) codec profiles. Omitted from the
    /// JSON when `nil`, so the default native-only profile is byte-for-byte today.
    public var container: String?
    public var conditions: [ProfileCondition]

    public init(type: String, codec: String, container: String? = nil, conditions: [ProfileCondition]) {
        self.type = type
        self.codec = codec
        self.container = container
        self.conditions = conditions
    }

    enum CodingKeys: String, CodingKey {
        case type = "Type"
        case codec = "Codec"
        case container = "Container"
        case conditions = "Conditions"
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encode(codec, forKey: .codec)
        try c.encodeIfPresent(container, forKey: .container)
        try c.encode(conditions, forKey: .conditions)
    }
}

public struct ProfileCondition: Encodable, Sendable, Equatable {
    public var condition: String
    public var property: String
    public var value: String
    public var isRequired: Bool

    enum CodingKeys: String, CodingKey {
        case condition = "Condition"
        case property = "Property"
        case value = "Value"
        case isRequired = "IsRequired"
    }
}

public struct SubtitleProfile: Encodable, Sendable, Equatable {
    public var format: String
    public var method: String

    enum CodingKeys: String, CodingKey {
        case format = "Format"
        case method = "Method"
    }
}
