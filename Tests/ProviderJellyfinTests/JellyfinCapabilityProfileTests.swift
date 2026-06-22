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
        XCTAssertTrue(videoContainers.contains("mpegts"))
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

    private func directPlayAudio(_ json: [String: Any], container: String) throws -> String {
        let direct = try XCTUnwrap(json["DirectPlayProfiles"] as? [[String: Any]])
        let entry = try XCTUnwrap(direct.first { ($0["Container"] as? String) == container })
        return try XCTUnwrap(entry["AudioCodec"] as? String)
    }

    func testDTSDirectPlayGatedOnPassthrough() throws {
        let withDTS = MediaCapabilities(supportsDTSPassthrough: true)
        let withoutDTS = MediaCapabilities(supportsDTSPassthrough: false)

        for container in ["mp4,m4v", "mov", "mpegts"] {
            let on = try directPlayAudio(encoded(.appleTV(capabilities: withDTS)), container: container)
            let off = try directPlayAudio(encoded(.appleTV(capabilities: withoutDTS)), container: container)
            XCTAssertTrue(on.split(separator: ",").contains("dts"), "expected dts in \(container)")
            XCTAssertFalse(off.split(separator: ",").contains("dts"), "unexpected dts in \(container)")
        }
    }

    func testEAC3AtmosDirectPlayAlwaysPresent() throws {
        // eac3 (Atmos JOC carrier) must remain direct-playable regardless of DTS.
        let stereo = MediaCapabilities(supportsDTSPassthrough: false)
        let audio = try directPlayAudio(encoded(.appleTV(capabilities: stereo)), container: "mp4,m4v")
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
}
