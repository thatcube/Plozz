import XCTest
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
}
