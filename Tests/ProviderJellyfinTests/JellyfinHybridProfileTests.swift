import XCTest
import CoreModels
@testable import ProviderJellyfin

/// Verifies the capability-expansion policy: turning the hybrid engine on/off
/// changes exactly the advertised direct-play formats while keeping advertise ⇔
/// route in lockstep with the display-aware range gates.
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
        // Sort keys so the comparison is deterministic (the profile contains
        // dictionaries whose key order is otherwise unstable across encodings).
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let a = try encoder.encode(JellyfinCapabilityProfile.appleTV(capabilities: caps))
        let b = try encoder.encode(JellyfinCapabilityProfile.appleTV(capabilities: caps, hybridEngineEnabled: false))
        XCTAssertEqual(a, b)
    }

    // MARK: On — extra formats advertised

    func testHybridOnAdvertisesMatroska() throws {
        let json = try encoded(.appleTV(capabilities: caps, hybridEngineEnabled: true))
        let containers = try videoContainers(json)
        XCTAssertTrue(containers.contains { $0.contains("mkv") })
    }

    func testHybridOnAdvertisesTSFamilyContainers() throws {
        let json = try encoded(.appleTV(capabilities: caps, hybridEngineEnabled: true))
        let containers = try videoContainers(json)
        XCTAssertTrue(containers.contains { $0.contains("m2ts") })
        XCTAssertTrue(containers.contains { $0.contains("ts") })
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

    // MARK: MKV direct-play is governed by the global (display-aware) range policy

    func testHybridOnAddsNoContainerScopedCodecRestriction() throws {
        // The hybrid flag advertises the MKV container via a DirectPlayProfile, but
        // adds NO container-scoped codec profile: a raw MKV is decoded on-device
        // for every display-supported range (incl. Dolby Vision), so the global
        // HEVC/AV1 codec profiles govern it. No mkv/webm-scoped codec profile may
        // exist that would restrict MKV below the global policy.
        let json = try encoded(.appleTV(capabilities: caps, hybridEngineEnabled: true))
        let codecs = try XCTUnwrap(json["CodecProfiles"] as? [[String: Any]])
        XCTAssertFalse(codecs.contains { ($0["Container"] as? String) != nil },
                       "MKV must not carry a container-scoped codec restriction; the global policy governs it")
    }

    func testHybridOnDropsInterlacedCodecRestriction() throws {
        let json = try encoded(.appleTV(capabilities: caps, hybridEngineEnabled: true))
        let codecs = try XCTUnwrap(json["CodecProfiles"] as? [[String: Any]])
        let h264 = try XCTUnwrap(codecs.first { ($0["Codec"] as? String) == "h264" })
        let conditions = try XCTUnwrap(h264["Conditions"] as? [[String: Any]])
        XCTAssertFalse(conditions.contains { ($0["Property"] as? String) == "IsInterlaced" })
    }

    func testHybridOnAdvertisesAV1Matroska() throws {
        // AV1-in-MKV must be advertised for on-device decode even though the Apple
        // TV has no AV1 hardware decoder — the on-device engine software-decodes it.
        let noAV1 = MediaCapabilities(supportsHEVC: true, supportsAV1: false)
        let json = try encoded(.appleTV(capabilities: noAV1, hybridEngineEnabled: true))

        let direct = try XCTUnwrap(json["DirectPlayProfiles"] as? [[String: Any]])
        let mkv = try XCTUnwrap(direct.first {
            ($0["Type"] as? String) == "Video" && (($0["Container"] as? String) ?? "").contains("mkv")
        })
        XCTAssertTrue(try XCTUnwrap(mkv["VideoCodec"] as? String).contains("av1"))
    }

    func testHybridOnAdvertisesDoViCapableMatroskaHEVC() throws {
        // With a DoVi-capable device (HEVC HW decode ⇒ supportsDolbyVision), the
        // MKV container is advertised and the global hevc profile permits DoVi, so
        // a DoVi-in-MKV is direct-played to the on-device engine (not transcoded).
        let doviCaps = MediaCapabilities(supportsHEVC: true, supportsDolbyVision: true)
        let json = try encoded(.appleTV(capabilities: doviCaps, hybridEngineEnabled: true))

        let direct = try XCTUnwrap(json["DirectPlayProfiles"] as? [[String: Any]])
        let mkv = try XCTUnwrap(direct.first {
            ($0["Type"] as? String) == "Video" && (($0["Container"] as? String) ?? "").contains("mkv")
        })
        XCTAssertTrue(try XCTUnwrap(mkv["VideoCodec"] as? String).contains("hevc"))

        let codecs = try XCTUnwrap(json["CodecProfiles"] as? [[String: Any]])
        let globalHevc = try XCTUnwrap(codecs.first {
            ($0["Codec"] as? String) == "hevc" && $0["Container"] == nil
        })
        let conditions = try XCTUnwrap(globalHevc["Conditions"] as? [[String: Any]])
        let range = try XCTUnwrap(conditions.first { ($0["Property"] as? String) == "VideoRangeType" })
        XCTAssertTrue(try XCTUnwrap(range["Value"] as? String).contains("DOVI"))
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

    // MARK: Subtitle delivery — hybrid embeds image/styled subs (no burn-in transcode)

    private func subtitleMethods(_ json: [String: Any], format: String) throws -> [String] {
        let subs = try XCTUnwrap(json["SubtitleProfiles"] as? [[String: Any]])
        return subs
            .filter { ($0["Format"] as? String) == format }
            .compactMap { $0["Method"] as? String }
    }

    func testHybridOnEmbedsImageSubtitles() throws {
        // Plozzigen renders bitmap subs, so the server must keep them embedded in the
        // direct-played container instead of forcing a burn-in (video) transcode.
        let json = try encoded(.appleTV(capabilities: caps, hybridEngineEnabled: true))
        for format in ["pgssub", "dvdsub", "dvbsub", "xsub"] {
            XCTAssertEqual(try subtitleMethods(json, format: format), ["Embed"],
                           "\(format) must be Embed when the hybrid engine is wired in")
        }
    }

    func testHybridOnEmbedsStyledSubtitles() throws {
        // Plozzigen (libass) renders ASS/SSA faithfully, so embed rather than burn in.
        let json = try encoded(.appleTV(capabilities: caps, hybridEngineEnabled: true))
        XCTAssertEqual(try subtitleMethods(json, format: "ass"), ["Embed"])
        XCTAssertEqual(try subtitleMethods(json, format: "ssa"), ["Embed"])
    }

    func testHybridOffBurnsInImageAndStyledSubtitles() throws {
        // Native-only build: AVPlayer can't draw image/styled subs, so the server
        // must burn them in (Encode). Non-regression for today's behaviour.
        let json = try encoded(.appleTV(capabilities: caps, hybridEngineEnabled: false))
        for format in ["pgssub", "dvdsub", "dvbsub", "xsub", "ass", "ssa"] {
            XCTAssertEqual(try subtitleMethods(json, format: format), ["Encode"],
                           "\(format) must be Encode (burn-in) without the hybrid engine")
        }
    }

    func testHybridDoesNotChangeTextSubtitleDelivery() throws {
        // Text/sidecar formats are unaffected by the hybrid flag.
        let on = try encoded(.appleTV(capabilities: caps, hybridEngineEnabled: true))
        let off = try encoded(.appleTV(capabilities: caps, hybridEngineEnabled: false))
        for format in ["srt", "subrip"] {
            XCTAssertEqual(try subtitleMethods(on, format: format), ["External"])
            XCTAssertEqual(try subtitleMethods(off, format: format), ["External"])
        }
        XCTAssertEqual(try subtitleMethods(on, format: "vtt").sorted(), ["External", "Hls"])
    }
}
