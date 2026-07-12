import XCTest
@testable import CoreModels

final class LocalRemuxModelsTests: XCTestCase {
    private func descriptor(
        container: String = "mkv",
        videoRangeType: String = "DOVIWithHDR10",
        dolbyVisionProfile: Int? = 8,
        videoProfile: String? = nil,
        bitDepth: Int? = nil,
        audioCodec: String = "eac3",
        audioChannels: Int? = 6
    ) -> LocalRemuxSourceDescriptor {
        LocalRemuxSourceDescriptor(
            itemID: "item1",
            mediaSourceID: "src1",
            provider: .jellyfin,
            originalSource: .publicURL(
                try! SecretFreeURLSource(
                    url: URL(string: "https://example.test/Videos/item1/stream.mkv")!
                )
            ),
            referencePlaybackSource: .publicURL(
                try! SecretFreeURLSource(
                    url: URL(string: "https://example.test/videos/item1/master.m3u8")!
                )
            ),
            durationSeconds: 7200,
            byteRangeSupported: true,
            sourceMetadata: MediaSourceMetadata(
                container: container,
                video: .init(
                    codec: "hevc",
                    profile: videoProfile,
                    bitDepth: bitDepth,
                    videoRangeType: videoRangeType,
                    dolbyVisionProfile: dolbyVisionProfile
                ),
                audio: .init(codec: audioCodec, channels: audioChannels)
            )
        )
    }

    func testDolbyVisionEAC3MatroskaIsEligibleForLocalRemux() {
        let caps = MediaCapabilities(supportsHEVC: true, supportsDolbyVision: true)
        if case .ineligible(let reason) = descriptor().eligibility(capabilities: caps) {
            XCTFail("Expected eligible local-remux source, got \(reason)")
        }
        XCTAssertTrue(descriptor().shouldPreferLocalRemux(capabilities: caps))
    }

    func testProfileSevenStaysOffLocalRemuxPath() {
        let caps = MediaCapabilities(supportsHEVC: true, supportsDolbyVision: true)
        let eligibility = descriptor(videoRangeType: "DOVI", dolbyVisionProfile: 7).eligibility(capabilities: caps)
        XCTAssertEqual(eligibility, .ineligible("Dolby Vision Profile 7 stays on the hybrid engine"))
    }

    func testTrueHDStaysOffLocalRemuxPath() {
        let caps = MediaCapabilities(supportsHEVC: true, supportsDolbyVision: true)
        let eligibility = descriptor(audioCodec: "truehd").eligibility(capabilities: caps)
        XCTAssertEqual(eligibility, .ineligible("TrueHD stays on the hybrid engine"))
    }

    // MARK: - Widened gate (B2 debug flag: com.plozz.playback.remuxHevcAny)

    /// A display route with NO Dolby Vision — proves HDR10/SDR HEVC qualify for the
    /// widened gate without needing the DoVi route the narrow gate requires.
    private let nonDoViCaps = MediaCapabilities(
        supportsHEVC: true, supportsHDR10: true, supportsDolbyVision: false)

    func testHDR10HevcEAC3IsEligibleWhenWidened() {
        let source = descriptor(
            videoRangeType: "HDR10", dolbyVisionProfile: nil,
            videoProfile: "Main 10", bitDepth: 10, audioCodec: "eac3", audioChannels: 6)
        if case .ineligible(let reason) = source.eligibility(
            capabilities: nonDoViCaps, allowAnyDecodableHEVC: true) {
            XCTFail("Expected HDR10 HEVC E-AC-3 5.1 to be eligible when widened, got \(reason)")
        }
        XCTAssertTrue(source.shouldPreferLocalRemux(
            capabilities: nonDoViCaps, allowAnyDecodableHEVC: true))
    }

    func testSDRTenBitHevcEAC3IsEligibleWhenWidened() {
        let source = descriptor(
            videoRangeType: "SDR", dolbyVisionProfile: nil,
            videoProfile: "Main 10", bitDepth: 10, audioCodec: "eac3", audioChannels: 6)
        if case .ineligible(let reason) = source.eligibility(
            capabilities: nonDoViCaps, allowAnyDecodableHEVC: true) {
            XCTFail("Expected SDR 10-bit HEVC E-AC-3 5.1 to be eligible when widened, got \(reason)")
        }
    }

    func testDoViProfileSevenStaysIneligibleWhenWidened() {
        let eligibility = descriptor(videoRangeType: "DOVI", dolbyVisionProfile: 7)
            .eligibility(capabilities: nonDoViCaps, allowAnyDecodableHEVC: true)
        XCTAssertEqual(eligibility, .ineligible("Dolby Vision Profile 7 stays on the hybrid engine"))
    }

    func testTrueHDStaysIneligibleWhenWidened() {
        let eligibility = descriptor(
            videoRangeType: "HDR10", dolbyVisionProfile: nil, audioCodec: "truehd")
            .eligibility(capabilities: nonDoViCaps, allowAnyDecodableHEVC: true)
        XCTAssertEqual(eligibility, .ineligible("TrueHD stays on the hybrid engine"))
    }

    func testHevcRangeExtensionsStayIneligibleWhenWidened() {
        let eligibility = descriptor(
            videoRangeType: "SDR", dolbyVisionProfile: nil,
            videoProfile: "Rext 4:2:2 10", bitDepth: 12)
            .eligibility(capabilities: nonDoViCaps, allowAnyDecodableHEVC: true)
        XCTAssertEqual(
            eligibility,
            .ineligible("HEVC Range Extensions (4:2:2/4:4:4/12-bit) stay on the hybrid engine"))
    }

    func testHDR10HevcStaysIneligibleByDefaultGate() {
        // Flag OFF (default): HDR10/SDR HEVC must NOT be diverted off the existing
        // routing — only single-layer Dolby Vision qualifies. Guards isolation.
        let eligibility = descriptor(videoRangeType: "HDR10", dolbyVisionProfile: nil)
            .eligibility(capabilities: nonDoViCaps)
        XCTAssertEqual(
            eligibility, .ineligible("Current display route does not advertise Dolby Vision"))
    }

    func testNonHevcCodecStaysIneligibleWhenWidened() {
        // H.264 is B4's scope, not B2's — the widened HEVC gate must leave it alone.
        var meta = descriptor().sourceMetadata
        meta.video = .init(codec: "h264", videoRangeType: "SDR")
        let source = LocalRemuxSourceDescriptor(
            itemID: "item1", provider: .jellyfin,
            originalSource: .publicURL(
                try! SecretFreeURLSource(
                    url: URL(string: "https://example.test/x.mkv")!
                )
            ),
            byteRangeSupported: true, sourceMetadata: meta)
        let eligibility = source.eligibility(
            capabilities: nonDoViCaps, allowAnyDecodableHEVC: true)
        XCTAssertEqual(eligibility, .ineligible("Video is not HEVC"))
    }
}
