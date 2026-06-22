import XCTest
import CoreModels
@testable import ProviderJellyfin

/// Verifies the capability-expansion policy: turning the hybrid (VLCKit) engine
/// on/off changes exactly the advertised direct-play formats, and keeps DoVi/HDR
/// in MKV out of direct play so the advertise ⇔ route invariant holds.
final class JellyfinHybridProfileTests: XCTestCase {
    private func encoded(_ profile: JellyfinCapabilityProfile) throws -> [String: Any] {
        let data = try JSONEncoder().encode(profile)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func videoContainers(_ json: [String: Any]) throws -> [String] {
        let direct = try XCTUnwrap(json["DirectPlayProfiles"] as? [[String: Any]])
        return direct
            .filter { ($0["Type"] as? String) == "Video" }
            .compactMap { $0["Container"] as? String }
    }

    private let caps = MediaCapabilities(supportsHEVC: true, supportsAV1: true)

    // MARK: Off (default) — byte-for-byte today

    func testHybridOffDoesNotAdvertiseMatroska() throws {
        let json = try encoded(.appleTV(capabilities: caps, hybridEngineEnabled: false))
        let containers = try videoContainers(json)
        XCTAssertFalse(containers.contains { $0.contains("mkv") })
    }

    func testDefaultProfileUnchangedByFlagAddition() throws {
        // The default (no flag) and the explicit hybrid-off profile must be
        // byte-for-byte identical, proving the flag defaults to no expansion.
        let a = try JSONEncoder().encode(JellyfinCapabilityProfile.appleTV(capabilities: caps))
        let b = try JSONEncoder().encode(JellyfinCapabilityProfile.appleTV(capabilities: caps, hybridEngineEnabled: false))
        XCTAssertEqual(a, b)
    }

    // MARK: On — extra formats advertised

    func testHybridOnAdvertisesMatroska() throws {
        let json = try encoded(.appleTV(capabilities: caps, hybridEngineEnabled: true))
        let containers = try videoContainers(json)
        XCTAssertTrue(containers.contains { $0.contains("mkv") })
    }

    func testHybridOnAddsDTSAndTrueHDToMP4Audio() throws {
        let json = try encoded(.appleTV(capabilities: caps, hybridEngineEnabled: true))
        let direct = try XCTUnwrap(json["DirectPlayProfiles"] as? [[String: Any]])
        let mp4 = try XCTUnwrap(direct.first { ($0["Container"] as? String) == "mp4,m4v" })
        let audio = try XCTUnwrap(mp4["AudioCodec"] as? String)
        XCTAssertTrue(audio.contains("dts"))
        XCTAssertTrue(audio.contains("truehd"))
    }

    func testHybridOffKeepsDTSGatedOnPassthrough() throws {
        // Without passthrough and without hybrid, mp4 audio must NOT advertise DTS.
        let json = try encoded(.appleTV(capabilities: caps, hybridEngineEnabled: false))
        let direct = try XCTUnwrap(json["DirectPlayProfiles"] as? [[String: Any]])
        let mp4 = try XCTUnwrap(direct.first { ($0["Container"] as? String) == "mp4,m4v" })
        let audio = try XCTUnwrap(mp4["AudioCodec"] as? String)
        XCTAssertFalse(audio.contains("dts"))
        XCTAssertFalse(audio.contains("truehd"))
    }

    // MARK: DoVi/HDR-in-MKV stays out of direct play (lockstep invariant)

    func testHybridOnConstrainsMatroskaHEVCToSDR() throws {
        let json = try encoded(.appleTV(capabilities: caps, hybridEngineEnabled: true))
        let codecs = try XCTUnwrap(json["CodecProfiles"] as? [[String: Any]])
        // There must be an mkv/webm-scoped hevc profile requiring SDR.
        let mkvHevc = try XCTUnwrap(codecs.first {
            ($0["Codec"] as? String) == "hevc" && (($0["Container"] as? String) ?? "").contains("mkv")
        })
        let conditions = try XCTUnwrap(mkvHevc["Conditions"] as? [[String: Any]])
        let rangeCondition = try XCTUnwrap(conditions.first { ($0["Property"] as? String) == "VideoRangeType" })
        XCTAssertEqual(rangeCondition["Value"] as? String, "SDR")
    }

    func testHybridOffHasNoContainerScopedCodecProfiles() throws {
        // The Container key must be entirely absent from codec profiles when off,
        // keeping the emitted JSON identical to today's.
        let json = try encoded(.appleTV(capabilities: caps, hybridEngineEnabled: false))
        let codecs = try XCTUnwrap(json["CodecProfiles"] as? [[String: Any]])
        XCTAssertFalse(codecs.contains { $0["Container"] != nil })
    }

    func testGlobalHEVCDoViRangesDoNotRegress() throws {
        // The global hevc codec profile must still advertise DoVi P5/P8 tokens and
        // never HDR10+ / Profile 7 — regardless of the hybrid flag.
        let json = try encoded(.appleTV(
            capabilities: MediaCapabilities(supportsHEVC: true, supportsDolbyVision: true),
            hybridEngineEnabled: true
        ))
        let codecs = try XCTUnwrap(json["CodecProfiles"] as? [[String: Any]])
        let globalHevc = try XCTUnwrap(codecs.first {
            ($0["Codec"] as? String) == "hevc" && $0["Container"] == nil
        })
        let conditions = try XCTUnwrap(globalHevc["Conditions"] as? [[String: Any]])
        let range = try XCTUnwrap(conditions.first { ($0["Property"] as? String) == "VideoRangeType" })
        let value = try XCTUnwrap(range["Value"] as? String)
        XCTAssertTrue(value.contains("DOVI"))
        XCTAssertFalse(value.contains("HDR10Plus"))
    }
}
