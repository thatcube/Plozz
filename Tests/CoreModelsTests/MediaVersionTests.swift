import XCTest
@testable import CoreModels

/// Tests for the `MediaVersion` value type, its labels, device-compatibility
/// prediction, and the smart "recommended selection" used as the picker default.
final class MediaVersionTests: XCTestCase {

    // MARK: - Labels

    func testResolutionLabelBuckets() {
        XCTAssertEqual(MediaVersion(id: "1", height: 2160).resolutionLabel, "4K")
        XCTAssertEqual(MediaVersion(id: "2", height: 1440).resolutionLabel, "1440p")
        XCTAssertEqual(MediaVersion(id: "3", height: 1080).resolutionLabel, "1080p")
        XCTAssertEqual(MediaVersion(id: "4", height: 720).resolutionLabel, "720p")
        XCTAssertEqual(MediaVersion(id: "5", height: 480).resolutionLabel, "SD")
        XCTAssertNil(MediaVersion(id: "6").resolutionLabel)
    }

    func testHDRAndAudioLabels() {
        let doviAtmos = MediaVersion(
            id: "1", height: 2160, videoRange: "DOVI",
            audioChannels: 8, audioProfile: "Dolby Atmos"
        )
        XCTAssertTrue(doviAtmos.isHDR)
        XCTAssertEqual(doviAtmos.hdrLabel, "Dolby Vision")
        XCTAssertEqual(doviAtmos.audioLabel, "Atmos")

        let sdr51 = MediaVersion(id: "2", height: 1080, videoRange: "SDR", audioChannels: 6)
        XCTAssertFalse(sdr51.isHDR)
        XCTAssertNil(sdr51.hdrLabel)
        XCTAssertEqual(sdr51.audioLabel, "5.1")
    }

    func testDisplayLabelPrefersDerivedFactsThenName() {
        let derived = MediaVersion(id: "1", height: 2160, sizeBytes: 12_000_000_000, videoRange: "HDR10")
        XCTAssertTrue(derived.displayLabel.contains("4K"))
        XCTAssertTrue(derived.displayLabel.contains("HDR10"))

        // A name that names a source-quality token now surfaces that token (the
        // edition/source recovery the picker needs) rather than echoing the raw
        // release string verbatim.
        XCTAssertEqual(MediaVersion(id: "2", name: "Bluray Remux").displayLabel, "Remux")
        // A name with no recognised edition/source/quality still falls back whole.
        XCTAssertEqual(MediaVersion(id: "2b", name: "Server Copy").displayLabel, "Server Copy")

        XCTAssertEqual(MediaVersion(id: "3").displayLabel, "Version")
    }

    func testQualityScoreRanksHDRAndResolution() {
        let uhdHDR = MediaVersion(id: "1", height: 2160, videoRange: "HDR10")
        let uhdSDR = MediaVersion(id: "2", height: 2160, videoRange: "SDR")
        let hd = MediaVersion(id: "3", height: 1080, videoRange: "SDR")
        XCTAssertGreaterThan(uhdHDR.qualityScore, uhdSDR.qualityScore)
        XCTAssertGreaterThan(uhdSDR.qualityScore, hd.qualityScore)
    }

    // MARK: - Compatibility prediction

    func testCompatibilityUnknownWithoutCodec() {
        let v = MediaVersion(id: "1", height: 1080)
        XCTAssertEqual(v.compatibility(with: .default), .unknown)
    }

    func testCompatibilityDirectPlayForSupportedH264AAC() {
        // h264 + SDR + AAC is universally decodable on any Apple TV 4K.
        let v = MediaVersion(id: "1", height: 1080, videoCodec: "h264", videoRange: "SDR", audioCodec: "aac")
        XCTAssertEqual(v.compatibility(with: .default), .directPlay)
    }

    func testCompatibilityTranscodeWhenHDRUnsupported() {
        // A Dolby Vision file on a non-DoVi device must tone-map (transcode).
        let dovi = MediaVersion(id: "1", height: 2160, videoCodec: "hevc", videoRange: "DOVI", audioCodec: "aac")
        XCTAssertEqual(dovi.compatibility(with: .default), .transcode)

        let doviCapable = MediaCapabilities(supportsDolbyVision: true)
        XCTAssertEqual(dovi.compatibility(with: doviCapable), .directPlay)
    }

    func testCompatibilityTranscodeWhenVideoCodecUnsupported() {
        let av1 = MediaVersion(id: "1", height: 2160, videoCodec: "av1", videoRange: "SDR", audioCodec: "aac")
        XCTAssertEqual(av1.compatibility(with: .default), .transcode) // default has no AV1
        XCTAssertEqual(av1.compatibility(with: MediaCapabilities(supportsAV1: true)), .directPlay)
    }

    func testCompatibilityTranscodeForDTSWithoutPassthrough() {
        let dts = MediaVersion(id: "1", height: 1080, videoCodec: "h264", videoRange: "SDR", audioCodec: "dts")
        XCTAssertEqual(dts.compatibility(with: .default), .transcode)
        XCTAssertEqual(dts.compatibility(with: MediaCapabilities(supportsDTSPassthrough: true)), .directPlay)
    }

    func testCompatibilityBadgeStrings() {
        XCTAssertEqual(VersionPlaybackCompatibility.directPlay.badge, "Direct Play")
        XCTAssertEqual(VersionPlaybackCompatibility.transcode.badge, "Transcode")
        XCTAssertEqual(VersionPlaybackCompatibility.unknown.badge, "")
    }

    // MARK: - Recommended selection (smart default)

    func testRecommendedSelectionPicksBestDirectPlayable() {
        // On a default (non-DoVi) device the 4K DoVi version transcodes, so the
        // recommended default is the best version that *direct plays* — the 1080p.
        let versions = [
            MediaVersion(id: "4k", height: 2160, isDefault: true, videoCodec: "hevc", videoRange: "DOVI", audioCodec: "aac"),
            MediaVersion(id: "1080", height: 1080, videoCodec: "h264", videoRange: "SDR", audioCodec: "aac")
        ]
        XCTAssertEqual(versions.recommendedSelection(for: .default)?.id, "1080")
    }

    func testRecommendedSelectionPrefersDirectPlayUHDWhenCapable() {
        // A DoVi-capable device direct-plays the 4K, so it wins.
        let versions = [
            MediaVersion(id: "4k", height: 2160, videoCodec: "hevc", videoRange: "DOVI", audioCodec: "aac"),
            MediaVersion(id: "1080", height: 1080, videoCodec: "h264", videoRange: "SDR", audioCodec: "aac")
        ]
        XCTAssertEqual(versions.recommendedSelection(for: MediaCapabilities(supportsDolbyVision: true))?.id, "4k")
    }

    func testRecommendedSelectionFallsBackToServerDefaultWhenNoneDirectPlay() {
        // Device can't HEVC-decode anything offered → fall back to server default.
        let caps = MediaCapabilities(supportsHEVC: false)
        let versions = [
            MediaVersion(id: "a", height: 2160, videoCodec: "hevc", videoRange: "SDR", audioCodec: "aac"),
            MediaVersion(id: "b", height: 2160, isDefault: true, videoCodec: "hevc", videoRange: "SDR", audioCodec: "aac")
        ]
        XCTAssertEqual(versions.recommendedSelection(for: caps)?.id, "b")
    }

    func testRecommendedSelectionEmptyIsNil() {
        XCTAssertNil([MediaVersion]().recommendedSelection(for: .default))
    }
}
