import XCTest
@testable import CoreModels

final class MediaCapabilitiesPolicyTests: XCTestCase {

    // MARK: HDR ranges

    func testSDROnlyDeviceAdvertisesOnlySDR() {
        let caps = MediaCapabilities(
            supportsHDR10: false,
            supportsHLG: false,
            supportsDolbyVision: false
        )
        XCTAssertEqual(caps.allowedHDRRanges, [.sdr])
    }

    func testHDR10AndHLGWithoutDolbyVision() {
        let caps = MediaCapabilities(
            supportsHDR10: true,
            supportsHLG: true,
            supportsDolbyVision: false
        )
        XCTAssertEqual(caps.allowedHDRRanges, [.sdr, .hlg, .hdr10])
    }

    func testDolbyVisionAdvertisesProfile5And8VariantsOnly() {
        let caps = MediaCapabilities(
            supportsHDR10: true,
            supportsHLG: true,
            supportsDolbyVision: true
        )
        // P5 (DOVI) + the three P8 cross-compatible variants — and nothing else.
        XCTAssertEqual(caps.allowedHDRRanges, [
            .sdr, .hlg, .hdr10,
            .dolbyVision, .dolbyVisionWithHDR10, .dolbyVisionWithHLG, .dolbyVisionWithSDR
        ])
    }

    func testNeverAdvertisesHDR10Plus() {
        // No combination of capabilities should ever surface an HDR10+ token.
        for hdr10 in [true, false] {
            for hlg in [true, false] {
                for dovi in [true, false] {
                    let caps = MediaCapabilities(
                        supportsHDR10: hdr10,
                        supportsHLG: hlg,
                        supportsDolbyVision: dovi
                    )
                    let raws = caps.allowedHDRRanges.map(\.rawValue)
                    XCTAssertFalse(
                        raws.contains(where: { $0.localizedCaseInsensitiveContains("HDR10Plus") }),
                        "HDR10+ must never be advertised (hdr10=\(hdr10) hlg=\(hlg) dovi=\(dovi))"
                    )
                }
            }
        }
    }

    func testHDRRangeRawValuesMatchJellyfinVideoRangeTokens() {
        XCTAssertEqual(HDRRange.sdr.rawValue, "SDR")
        XCTAssertEqual(HDRRange.hlg.rawValue, "HLG")
        XCTAssertEqual(HDRRange.hdr10.rawValue, "HDR10")
        XCTAssertEqual(HDRRange.dolbyVision.rawValue, "DOVI")
        XCTAssertEqual(HDRRange.dolbyVisionWithHDR10.rawValue, "DOVIWithHDR10")
        XCTAssertEqual(HDRRange.dolbyVisionWithHLG.rawValue, "DOVIWithHLG")
        XCTAssertEqual(HDRRange.dolbyVisionWithSDR.rawValue, "DOVIWithSDR")
    }

    // MARK: Passthrough audio (DTS gating)

    func testPassthroughAudioWithoutDTSSupport() {
        let caps = MediaCapabilities(supportsDTSPassthrough: false)
        XCTAssertEqual(caps.allowedPassthroughAudioCodecs, [.ac3, .eac3])
    }

    func testPassthroughAudioWithDTSSupportAddsDTS() {
        let caps = MediaCapabilities(supportsDTSPassthrough: true)
        XCTAssertEqual(caps.allowedPassthroughAudioCodecs, [.ac3, .eac3, .dts, .dtsHD])
    }

    func testDTSNeverAllowedWhenPassthroughUnsupported() {
        let caps = MediaCapabilities(supportsDTSPassthrough: false)
        XCTAssertFalse(caps.allowedPassthroughAudioCodecs.contains(.dts))
        XCTAssertFalse(caps.allowedPassthroughAudioCodecs.contains(.dtsHD))
    }

    // MARK: Direct-play video (AV1 / HEVC gating)

    func testDirectPlayVideoAlwaysIncludesH264() {
        let caps = MediaCapabilities(supportsHEVC: false, supportsAV1: false)
        XCTAssertEqual(caps.allowedDirectPlayVideoCodecs, [.h264])
    }

    func testDirectPlayVideoIncludesHEVCWhenSupported() {
        let caps = MediaCapabilities(supportsHEVC: true, supportsAV1: false)
        XCTAssertEqual(caps.allowedDirectPlayVideoCodecs, [.h264, .hevc])
    }

    func testAV1GatedOnSupport() {
        let withAV1 = MediaCapabilities(supportsHEVC: true, supportsAV1: true)
        XCTAssertEqual(withAV1.allowedDirectPlayVideoCodecs, [.h264, .hevc, .av1])

        let withoutAV1 = MediaCapabilities(supportsHEVC: true, supportsAV1: false)
        XCTAssertFalse(withoutAV1.allowedDirectPlayVideoCodecs.contains(.av1))
    }

    // MARK: Channel recommendation

    func testRecommendedChannelsTracksOutputChannels() {
        XCTAssertEqual(MediaCapabilities(maxOutputChannels: 6).recommendedMaxAudioChannels, 6)
        XCTAssertEqual(MediaCapabilities(maxOutputChannels: 8).recommendedMaxAudioChannels, 8)
    }

    func testRecommendedChannelsNeverBelowStereo() {
        // The initializer floors the stored value at 2…
        XCTAssertEqual(MediaCapabilities(maxOutputChannels: 1).recommendedMaxAudioChannels, 2)
        XCTAssertEqual(MediaCapabilities(maxOutputChannels: 0).recommendedMaxAudioChannels, 2)
    }

    func testRecommendedChannelsNotHardcodedToEight() {
        // Regression guard against the old hard-coded "8": a stereo route must
        // recommend 2, not 8.
        XCTAssertEqual(MediaCapabilities(maxOutputChannels: 2).recommendedMaxAudioChannels, 2)
    }

    // MARK: Default profile

    func testDefaultIsConservative() {
        let caps = MediaCapabilities.default
        XCTAssertTrue(caps.supportsHEVC)
        XCTAssertFalse(caps.supportsAV1)
        XCTAssertTrue(caps.supportsHDR10)
        XCTAssertTrue(caps.supportsHLG)
        XCTAssertFalse(caps.supportsDolbyVision)
        XCTAssertFalse(caps.supportsAtmos)
        XCTAssertFalse(caps.supportsDTSPassthrough)
        XCTAssertEqual(caps.maxOutputChannels, 2)
        XCTAssertEqual(caps.recommendedMaxAudioChannels, 2)
    }

    func testEquatableAndSendableValueSemantics() {
        let a = MediaCapabilities(supportsAV1: true, maxOutputChannels: 8)
        var b = a
        XCTAssertEqual(a, b)
        b.supportsAV1 = false
        XCTAssertNotEqual(a, b)
    }
}
