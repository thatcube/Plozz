import XCTest
import CoreModels
@testable import ProviderJellyfin

final class JellyfinCapabilityProfileTests: XCTestCase {
    private func encoded(_ profile: JellyfinCapabilityProfile) throws -> [String: Any] {
        let data = try JSONEncoder().encode(profile)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testDirectPlayProfilesCoverAppleTVContainers() throws {
        let profile = JellyfinCapabilityProfile.appleTV(capabilities: .init(supportsHEVC: true))
        let json = try encoded(profile)
        let direct = try XCTUnwrap(json["DirectPlayProfiles"] as? [[String: Any]])
        let videoContainers = direct
            .filter { ($0["Type"] as? String) == "Video" }
            .compactMap { $0["Container"] as? String }
        XCTAssertTrue(videoContainers.contains("mp4,m4v"))
        XCTAssertTrue(videoContainers.contains("mov"))
        // Transport-stream profile: mpegts + m2ts/mts in one entry.
        XCTAssertTrue(videoContainers.contains { $0.contains("mpegts") })
        // MKV is intentionally absent — AVPlayer cannot demux it, so it must
        // fall through to the HLS transcoding profile.
        XCTAssertFalse(videoContainers.contains { $0.contains("mkv") })
    }

    func testHEVCDirectPlayGatedByCapability() throws {
        let withHEVC = try encoded(.appleTV(capabilities: .init(supportsHEVC: true)))
        let withoutHEVC = try encoded(.appleTV(capabilities: .init(supportsHEVC: false)))

        func mp4VideoCodec(_ json: [String: Any]) throws -> String {
            let direct = try XCTUnwrap(json["DirectPlayProfiles"] as? [[String: Any]])
            let mp4 = try XCTUnwrap(direct.first { ($0["Container"] as? String) == "mp4,m4v" })
            return try XCTUnwrap(mp4["VideoCodec"] as? String)
        }

        XCTAssertTrue(try mp4VideoCodec(withHEVC).contains("hevc"))
        XCTAssertFalse(try mp4VideoCodec(withoutHEVC).contains("hevc"))
    }

    func testTranscodingProfileIsSeekableHLS() throws {
        let json = try encoded(.appleTV())
        let transcoding = try XCTUnwrap(json["TranscodingProfiles"] as? [[String: Any]])
        let hls = try XCTUnwrap(transcoding.first { ($0["Protocol"] as? String) == "hls" })
        XCTAssertEqual(hls["Container"] as? String, "mp4")
        XCTAssertEqual(hls["BreakOnNonKeyFrames"] as? Bool, true)
        XCTAssertEqual(hls["MinSegments"] as? Int, 2)
        XCTAssertTrue((hls["VideoCodec"] as? String ?? "").contains("h264"))
    }

    func testCodecProfilesIncludeH264Conditions() throws {
        let json = try encoded(.appleTV())
        let codecs = try XCTUnwrap(json["CodecProfiles"] as? [[String: Any]])
        let h264 = try XCTUnwrap(codecs.first { ($0["Codec"] as? String) == "h264" })
        let conditions = try XCTUnwrap(h264["Conditions"] as? [[String: Any]])
        let properties = conditions.compactMap { $0["Property"] as? String }
        XCTAssertTrue(properties.contains("VideoLevel"))
        XCTAssertTrue(properties.contains("VideoProfile"))
        // Conditions must be advisory, not required, so unknown properties don't
        // force a needless transcode.
        XCTAssertTrue(conditions.allSatisfy { ($0["IsRequired"] as? Bool) == false })
    }

    // MARK: - HDR / Dolby Vision correctness

    private func hevcVideoRange(_ json: [String: Any]) throws -> String {
        let codecs = try XCTUnwrap(json["CodecProfiles"] as? [[String: Any]])
        let hevc = try XCTUnwrap(codecs.first { ($0["Codec"] as? String) == "hevc" })
        let conditions = try XCTUnwrap(hevc["Conditions"] as? [[String: Any]])
        let range = try XCTUnwrap(conditions.first { ($0["Property"] as? String) == "VideoRangeType" })
        return try XCTUnwrap(range["Value"] as? String)
    }

    func testHDR10PlusTokenNeverEmitted() throws {
        let caps = MediaCapabilities(
            supportsHEVC: true,
            supportsHDR10: true,
            supportsHLG: true,
            supportsDolbyVision: true
        )
        let tokens = try hevcVideoRange(encoded(.appleTV(capabilities: caps))).split(separator: "|").map(String.init)
        XCTAssertFalse(tokens.contains("HDR10Plus"))
    }

    func testDolbyVisionRangesOnlyProfile5And8WhenSupported() throws {
        let withDoVi = MediaCapabilities(supportsHEVC: true, supportsDolbyVision: true)
        let tokens = try hevcVideoRange(encoded(.appleTV(capabilities: withDoVi))).split(separator: "|").map(String.init)
        let doviTokens = tokens.filter { $0.hasPrefix("DOVI") }
        XCTAssertEqual(
            Set(doviTokens),
            ["DOVI", "DOVIWithHDR10", "DOVIWithHLG", "DOVIWithSDR"]
        )
        // No Profile 7 / dual-layer tokens.
        XCTAssertFalse(tokens.contains { $0.contains("Profile7") || $0.contains("EL") })
    }

    func testDolbyVisionRangesAbsentWhenUnsupported() throws {
        let noDoVi = MediaCapabilities(supportsHEVC: true, supportsDolbyVision: false)
        let tokens = try hevcVideoRange(encoded(.appleTV(capabilities: noDoVi))).split(separator: "|").map(String.init)
        XCTAssertFalse(tokens.contains { $0.hasPrefix("DOVI") })
    }

    // MARK: - DTS passthrough

    private func directPlayAudio(_ json: [String: Any], containerPrefix: String) throws -> String {
        let direct = try XCTUnwrap(json["DirectPlayProfiles"] as? [[String: Any]])
        let entry = try XCTUnwrap(
            direct.first { ($0["Container"] as? String)?.hasPrefix(containerPrefix) == true },
            "No direct-play entry for container prefix: \(containerPrefix)"
        )
        return try XCTUnwrap(entry["AudioCodec"] as? String)
    }

    func testDTSDirectPlayGatedOnPassthrough() throws {
        let withDTS = MediaCapabilities(supportsDTSPassthrough: true)
        let withoutDTS = MediaCapabilities(supportsDTSPassthrough: false)

        // TS container entry is now "mpegts,m2ts,mts" — match by prefix.
        for containerPrefix in ["mp4", "mov", "mpegts"] {
            let on = try directPlayAudio(encoded(.appleTV(capabilities: withDTS)), containerPrefix: containerPrefix)
            let off = try directPlayAudio(encoded(.appleTV(capabilities: withoutDTS)), containerPrefix: containerPrefix)
            XCTAssertTrue(on.split(separator: ",").contains("dts"), "expected dts in \(containerPrefix)")
            XCTAssertFalse(off.split(separator: ",").contains("dts"), "unexpected dts in \(containerPrefix)")
        }
    }

    func testEAC3AtmosDirectPlayAlwaysPresent() throws {
        // eac3 (Atmos JOC carrier) must remain direct-playable regardless of DTS.
        let stereo = MediaCapabilities(supportsDTSPassthrough: false)
        let audio = try directPlayAudio(encoded(.appleTV(capabilities: stereo)), containerPrefix: "mp4")
        XCTAssertTrue(audio.split(separator: ",").contains("eac3"))
    }

    // MARK: - Channel-aware transcoding

    func testMaxAudioChannelsReflectsRecommended() throws {
        let surround = MediaCapabilities(maxOutputChannels: 8)
        let stereo = MediaCapabilities(maxOutputChannels: 2)

        func maxChannels(_ caps: MediaCapabilities) throws -> String {
            let json = try encoded(.appleTV(capabilities: caps))
            let transcoding = try XCTUnwrap(json["TranscodingProfiles"] as? [[String: Any]])
            let hls = try XCTUnwrap(transcoding.first)
            return try XCTUnwrap(hls["MaxAudioChannels"] as? String)
        }

        XCTAssertEqual(try maxChannels(surround), "8")
        XCTAssertEqual(try maxChannels(stereo), "2")
    }

    // MARK: - Wire shape

    func testProfileEncodesExpectedTopLevelKeys() throws {
        let json = try encoded(.appleTV())
        XCTAssertEqual(
            Set(json.keys),
            [
                "MaxStreamingBitrate", "MaxStaticBitrate", "MusicStreamingTranscodingBitrate",
                "DirectPlayProfiles", "TranscodingProfiles", "CodecProfiles", "SubtitleProfiles"
            ]
        )
    }

    // MARK: - Opus / Vorbis: native vs. hybrid

    func testOpusAbsentFromNativeMP4Profile() throws {
        // AVPlayer cannot decode Opus in an MP4/MOV/TS container — the file plays
        // video with no sound. Opus must NOT appear in the base audio list when
        // the hybrid engine is disabled.
        let json = try encoded(.appleTV(capabilities: .default, hybridEngineEnabled: false))
        let direct = try XCTUnwrap(json["DirectPlayProfiles"] as? [[String: Any]])
        for entry in direct where (entry["Type"] as? String) == "Video" {
            let audio = (entry["AudioCodec"] as? String) ?? ""
            XCTAssertFalse(audio.split(separator: ",").contains("opus"),
                           "Opus must not be advertised for native (AVPlayer-only) playback in \(entry["Container"] ?? "?")")
        }
    }

    func testOpusPresentInHybridMP4Profile() throws {
        // When the hybrid engine is on, mpv decodes Opus, so we can advertise it
        // even in Apple containers (the router sends Opus-in-MP4 to mpv).
        let json = try encoded(.appleTV(capabilities: .default, hybridEngineEnabled: true))
        let direct = try XCTUnwrap(json["DirectPlayProfiles"] as? [[String: Any]])
        let mp4 = try XCTUnwrap(direct.first { ($0["Container"] as? String) == "mp4,m4v" })
        XCTAssertTrue((mp4["AudioCodec"] as? String ?? "").split(separator: ",").contains("opus"),
                      "Opus must be advertised in MP4 when hybrid engine is enabled")
    }

    func testVorbisAbsentFromNativeProfile() throws {
        let json = try encoded(.appleTV(capabilities: .default, hybridEngineEnabled: false))
        let direct = try XCTUnwrap(json["DirectPlayProfiles"] as? [[String: Any]])
        for entry in direct where (entry["Type"] as? String) == "Video" {
            let audio = (entry["AudioCodec"] as? String) ?? ""
            XCTAssertFalse(audio.split(separator: ",").contains("vorbis"),
                           "Vorbis must not be advertised in native profile")
        }
    }

    // MARK: - M2TS / TS containers

    func testM2TSInTransportStreamProfile() throws {
        // m2ts and mts should be included alongside mpegts for direct play.
        let json = try encoded(.appleTV(capabilities: .init(supportsHEVC: true)))
        let direct = try XCTUnwrap(json["DirectPlayProfiles"] as? [[String: Any]])
        let containers = direct
            .filter { ($0["Type"] as? String) == "Video" }
            .compactMap { $0["Container"] as? String }
        let hasM2TS = containers.contains { $0.contains("m2ts") }
        XCTAssertTrue(hasM2TS, "m2ts must be included in the transport-stream direct-play profile")
    }

    // MARK: - Subtitle profiles (External SRT, Encode ASS)

    private func subtitleProfiles(_ json: [String: Any]) throws -> [[String: Any]] {
        try XCTUnwrap(json["SubtitleProfiles"] as? [[String: Any]])
    }

    func testSRTSubtitleHasExternalMethod() throws {
        let subs = try subtitleProfiles(encoded(.appleTV()))
        // Both "srt" and "subrip" (the canonical IANA token) should be External.
        let srtMethods = subs.filter { ($0["Format"] as? String) == "srt" }.compactMap { $0["Method"] as? String }
        let subripMethods = subs.filter { ($0["Format"] as? String) == "subrip" }.compactMap { $0["Method"] as? String }
        XCTAssertTrue(srtMethods.contains("External") || subripMethods.contains("External"),
                      "srt/subrip must have an External subtitle profile for sidecar delivery")
    }

    func testVTTSubtitleHasExternalMethod() throws {
        let subs = try subtitleProfiles(encoded(.appleTV()))
        let vttMethods = subs.filter { ($0["Format"] as? String) == "vtt" }.compactMap { $0["Method"] as? String }
        XCTAssertTrue(vttMethods.contains("External"),
                      "vtt must have an External method for direct-play sidecar injection")
    }

    func testASSSubtitleHasEncodeMethod() throws {
        let subs = try subtitleProfiles(encoded(.appleTV()))
        let assMethods = subs.filter { ($0["Format"] as? String) == "ass" }.compactMap { $0["Method"] as? String }
        XCTAssertTrue(assMethods.contains("Encode"),
                      "ASS must use Encode (server burn-in) — the native renderer can't reproduce its styling")
    }

    func testSSASubtitleHasEncodeMethod() throws {
        let subs = try subtitleProfiles(encoded(.appleTV()))
        let ssaMethods = subs.filter { ($0["Format"] as? String) == "ssa" }.compactMap { $0["Method"] as? String }
        XCTAssertTrue(ssaMethods.contains("Encode"),
                      "SSA must use Encode (server burn-in)")
    }

    func testHLSVTTMethodStillPresent() throws {
        // Regression guard: the original Hls method for vtt must not be removed.
        let subs = try subtitleProfiles(encoded(.appleTV()))
        let vttMethods = subs.filter { ($0["Format"] as? String) == "vtt" }.compactMap { $0["Method"] as? String }
        XCTAssertTrue(vttMethods.contains("Hls"), "vtt/Hls profile must remain for HLS manifest subtitles")
    }
}
