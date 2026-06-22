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
    public static func appleTV(
        capabilities: MediaCapabilities = .default,
        maxBitrate: Int = defaultMaxBitrate
    ) -> JellyfinCapabilityProfile {
        JellyfinCapabilityProfile(
            maxStreamingBitrate: maxBitrate,
            maxStaticBitrate: maxBitrate,
            musicStreamingTranscodingBitrate: 384_000,
            directPlayProfiles: directPlay(capabilities),
            transcodingProfiles: [transcoding(capabilities)],
            codecProfiles: codec(capabilities),
            subtitleProfiles: subtitles()
        )
    }

    /// Probes the real hardware/audio route via
    /// ``CoreModels/MediaCapabilities/detected()`` where available, otherwise
    /// falls back to ``CoreModels/MediaCapabilities/default``.
    public static func detected(maxBitrate: Int = defaultMaxBitrate) -> JellyfinCapabilityProfile {
        appleTV(capabilities: .detected(), maxBitrate: maxBitrate)
    }

    // MARK: Profile sections

    private static func directPlay(_ caps: MediaCapabilities) -> [DirectPlayProfile] {
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
        // `dca` is ffmpeg's alternate name for the DTS family.
        let passthrough = caps.allowedPassthroughAudioCodecs
        let dtsTokens = (passthrough.contains(.dts) || passthrough.contains(.dtsHD))
            ? ["dts", "dca"]
            : []

        func audio(_ base: [String], allowDTS: Bool) -> String {
            (allowDTS ? base + dtsTokens : base).joined(separator: ",")
        }

        return [
            DirectPlayProfile(
                type: "Video",
                container: "mp4,m4v",
                videoCodec: mp4Video.joined(separator: ","),
                audioCodec: audio(["aac", "ac3", "alac", "eac3", "flac", "mp3", "opus"], allowDTS: true)
            ),
            DirectPlayProfile(
                type: "Video",
                container: "mov",
                videoCodec: movVideo.joined(separator: ","),
                audioCodec: audio(["aac", "ac3", "alac", "eac3", "mp3", "pcm_s16be", "pcm_s16le", "pcm_s24be", "pcm_s24le"], allowDTS: true)
            ),
            DirectPlayProfile(
                type: "Video",
                container: "mpegts",
                videoCodec: tsVideo.joined(separator: ","),
                audioCodec: audio(["aac", "ac3", "eac3", "mp3"], allowDTS: true)
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

    private static func codec(_ caps: MediaCapabilities) -> [CodecProfile] {
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
    public var conditions: [ProfileCondition]

    enum CodingKeys: String, CodingKey {
        case type = "Type"
        case codec = "Codec"
        case conditions = "Conditions"
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
