import Foundation
#if canImport(VideoToolbox)
import VideoToolbox
#endif

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

// MARK: - Hardware capabilities

extension JellyfinCapabilityProfile {
    /// What the running device's video hardware can decode. Injected explicitly
    /// so the produced profile JSON is deterministic and unit-testable; use
    /// ``detected(maxBitrate:)`` to probe the real hardware at runtime.
    public struct DecoderCapabilities: Sendable, Equatable {
        public var supportsHEVC: Bool
        public var supportsAV1: Bool
        public var supportsHDR10: Bool
        public var supportsHLG: Bool
        public var supportsDolbyVision: Bool

        public init(
            supportsHEVC: Bool = true,
            supportsAV1: Bool = false,
            supportsHDR10: Bool = true,
            supportsHLG: Bool = true,
            supportsDolbyVision: Bool = false
        ) {
            self.supportsHEVC = supportsHEVC
            self.supportsAV1 = supportsAV1
            self.supportsHDR10 = supportsHDR10
            self.supportsHLG = supportsHLG
            self.supportsDolbyVision = supportsDolbyVision
        }

        /// A conservative default used on platforms where we can't probe the
        /// hardware (e.g. Linux CI). HEVC is assumed (every Apple TV 4K decodes
        /// it); AV1 is not.
        public static let `default` = DecoderCapabilities()
    }
}

// MARK: - Builders

extension JellyfinCapabilityProfile {
    /// ~120 Mbit/s: enough headroom for high-bitrate 4K remuxes on a LAN while
    /// still capping pathological files.
    public static let defaultMaxBitrate = 120_000_000

    /// Builds the native (AVFoundation / `AVPlayer`) profile for Apple TV,
    /// mirroring Swiftfin's `.native` profile.
    public static func appleTV(
        capabilities: DecoderCapabilities = .default,
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

    /// Probes the real video hardware (VideoToolbox) where available, otherwise
    /// falls back to ``DecoderCapabilities/default``.
    public static func detected(maxBitrate: Int = defaultMaxBitrate) -> JellyfinCapabilityProfile {
        appleTV(capabilities: detectedCapabilities(), maxBitrate: maxBitrate)
    }

    static func detectedCapabilities() -> DecoderCapabilities {
        #if canImport(VideoToolbox)
        let hevc = VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)
        let av1: Bool
        if #available(tvOS 16.0, iOS 16.0, macOS 13.0, *) {
            av1 = VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)
        } else {
            av1 = false
        }
        return DecoderCapabilities(
            supportsHEVC: hevc,
            supportsAV1: av1,
            supportsHDR10: hevc,
            supportsHLG: hevc,
            supportsDolbyVision: hevc
        )
        #else
        return .default
        #endif
    }

    // MARK: Profile sections

    private static func directPlay(_ caps: DecoderCapabilities) -> [DirectPlayProfile] {
        var mp4Video = ["h264", "mpeg4"]
        if caps.supportsHEVC { mp4Video.append("hevc") }
        if caps.supportsAV1 { mp4Video.append("av1") }

        var movVideo = ["h264", "mjpeg", "mpeg4"]
        if caps.supportsHEVC { movVideo.append("hevc") }

        var tsVideo = ["h264"]
        if caps.supportsHEVC { tsVideo.append("hevc") }

        return [
            DirectPlayProfile(
                type: "Video",
                container: "mp4,m4v",
                videoCodec: mp4Video.joined(separator: ","),
                audioCodec: "aac,ac3,alac,eac3,flac,mp3,opus"
            ),
            DirectPlayProfile(
                type: "Video",
                container: "mov",
                videoCodec: movVideo.joined(separator: ","),
                audioCodec: "aac,ac3,alac,eac3,mp3,pcm_s16be,pcm_s16le,pcm_s24be,pcm_s24le"
            ),
            DirectPlayProfile(
                type: "Video",
                container: "mpegts",
                videoCodec: tsVideo.joined(separator: ","),
                audioCodec: "aac,ac3,eac3,mp3"
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

    private static func transcoding(_ caps: DecoderCapabilities) -> TranscodingProfile {
        var videoCodecs = ["h264"]
        if caps.supportsHEVC { videoCodecs.insert("hevc", at: 0) }
        if caps.supportsAV1 { videoCodecs.insert("av1", at: 0) }
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
            maxAudioChannels: "8"
        )
    }

    private static func codec(_ caps: DecoderCapabilities) -> [CodecProfile] {
        var profiles: [CodecProfile] = [
            CodecProfile(type: "Video", codec: "h264", conditions: [
                ProfileCondition(condition: "NotEquals", property: "IsAnamorphic", value: "true", isRequired: false),
                ProfileCondition(condition: "EqualsAny", property: "VideoProfile", value: "high|main|baseline|constrained baseline", isRequired: false),
                ProfileCondition(condition: "LessThanEqual", property: "VideoLevel", value: "52", isRequired: false),
                ProfileCondition(condition: "NotEquals", property: "IsInterlaced", value: "true", isRequired: false)
            ])
        ]

        if caps.supportsHEVC {
            var ranges = ["SDR"]
            if caps.supportsHLG { ranges += ["HLG"] }
            if caps.supportsHDR10 { ranges += ["HDR10", "HDR10Plus"] }
            if caps.supportsDolbyVision { ranges += ["DOVI", "DOVIWithHDR10", "DOVIWithHLG", "DOVIWithSDR"] }
            profiles.append(
                CodecProfile(type: "Video", codec: "hevc", conditions: [
                    ProfileCondition(condition: "NotEquals", property: "IsAnamorphic", value: "true", isRequired: false),
                    ProfileCondition(condition: "EqualsAny", property: "VideoProfile", value: "main|main 10", isRequired: false),
                    ProfileCondition(condition: "LessThanEqual", property: "VideoLevel", value: "183", isRequired: false),
                    ProfileCondition(condition: "NotEquals", property: "IsInterlaced", value: "true", isRequired: false),
                    ProfileCondition(condition: "EqualsAny", property: "VideoRangeType", value: ranges.joined(separator: "|"), isRequired: false)
                ])
            )
        }

        if caps.supportsAV1 {
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
