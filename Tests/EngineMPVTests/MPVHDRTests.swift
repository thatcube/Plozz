#if canImport(Libmpv) && canImport(UIKit)
import XCTest
import CoreMedia
@testable import EngineMPV
import CoreModels

/// Unit tests for `MPVHDR` — the pure HDR-classification and display-criteria
/// helpers for the mpv engine. These verify:
///   1. DoVi source tokens (`DOVI`, `DOVIWithHDR10`, `DOVIWithSDR`,
///      `DOVIWithHLG`) all classify as `.dolbyVision` (not `.pq`).
///   2. `.dolbyVision` produces a `CMVideoFormatDescription` with codec type
///      `dvh1` (0x64766831) — the FourCC that tells `AVDisplayManager` to
///      negotiate a true Dolby Vision HDMI handshake.
///   3. HDR10 still produces `hvc1` (plain HEVC) so existing HDR10 behaviour
///      is untouched.
///   4. Metal pixel format and `target-trc` for DoVi stay on the PQ path
///      (libplacebo renders to PQ BT.2020 regardless of DoVi profile).
final class MPVHDRModeClassificationTests: XCTestCase {

    // MARK: Dolby Vision classification

    func testDoViMode_DOVI() {
        let v = video(rangeType: "DOVI")
        XCTAssertEqual(MPVHDR.mode(from: v), .dolbyVision)
    }

    func testDoViMode_DOVIWithHDR10() {
        let v = video(rangeType: "DOVIWithHDR10")
        XCTAssertEqual(MPVHDR.mode(from: v), .dolbyVision)
    }

    func testDoViMode_DOVIWithSDR() {
        let v = video(rangeType: "DOVIWithSDR")
        XCTAssertEqual(MPVHDR.mode(from: v), .dolbyVision)
    }

    func testDoViMode_DOVIWithHLG() {
        // Must NOT fall through to .hlg even though the token contains "HLG".
        let v = video(rangeType: "DOVIWithHLG")
        XCTAssertEqual(MPVHDR.mode(from: v), .dolbyVision)
    }

    func testDoViMode_lowercaseToken() {
        let v = video(rangeType: "dovi")
        XCTAssertEqual(MPVHDR.mode(from: v), .dolbyVision)
    }

    // MARK: HDR10 / HLG / SDR unchanged

    func testHDR10Mode() {
        XCTAssertEqual(MPVHDR.mode(from: video(rangeType: "HDR10")), .pq)
    }

    func testHLGMode() {
        XCTAssertEqual(MPVHDR.mode(from: video(rangeType: "HLG")), .hlg)
    }

    func testSDRMode_noMetadata() {
        XCTAssertEqual(MPVHDR.mode(from: nil), .sdr)
    }

    func testSDRMode_genericSDR() {
        XCTAssertEqual(MPVHDR.mode(from: video(rangeType: "SDR")), .sdr)
    }

    // MARK: isHDR

    func testDoViIsHDR() {
        XCTAssertTrue(MPVHDRMode.dolbyVision.isHDR)
    }
}

final class MPVHDRFormatDescriptionTests: XCTestCase {

    // MARK: Dolby Vision → dvh1

    func testDoViFormatDescription_usesdvh1() throws {
        let v = video(rangeType: "DOVI", codec: "hevc")
        let desc = try XCTUnwrap(MPVHDR.formatDescription(for: .dolbyVision, video: v),
                                 "Expected a CMVideoFormatDescription for .dolbyVision")
        let codecType = CMVideoFormatDescriptionGetCodecType(desc)
        XCTAssertEqual(codecType, MPVHDR.dolbyVisionCodecType,
                       "DoVi display criteria must use 'dvh1' (0x64766831), got \(fourCCString(codecType))")
    }

    func testDoViFormatDescription_Profile5_usesdvh1() throws {
        // Profile 5: BL-only HEVC, no base-layer compatibility; still dvh1.
        let v = video(rangeType: "DOVI", codec: "hevc")
        let desc = try XCTUnwrap(MPVHDR.formatDescription(for: .dolbyVision, video: v))
        XCTAssertEqual(CMVideoFormatDescriptionGetCodecType(desc), MPVHDR.dolbyVisionCodecType)
    }

    func testDoViFormatDescription_Profile8_usesdvh1() throws {
        // Profile 8.1: BL=HDR10 HEVC, EL RPU; still dvh1 on the criteria side.
        let v = video(rangeType: "DOVIWithHDR10", codec: "hevc")
        let desc = try XCTUnwrap(MPVHDR.formatDescription(for: .dolbyVision, video: v))
        XCTAssertEqual(CMVideoFormatDescriptionGetCodecType(desc), MPVHDR.dolbyVisionCodecType)
    }

    // MARK: HDR10 / HLG fallback → hvc1 (unchanged)

    func testHDR10FormatDescription_usesHvc1() throws {
        let v = video(rangeType: "HDR10", codec: "hevc")
        let desc = try XCTUnwrap(MPVHDR.formatDescription(for: .pq, video: v))
        XCTAssertEqual(CMVideoFormatDescriptionGetCodecType(desc), kCMVideoCodecType_HEVC,
                       "HDR10 must keep 'hvc1'; got \(fourCCString(CMVideoFormatDescriptionGetCodecType(desc)))")
    }

    func testHLGFormatDescription_usesHvc1() throws {
        let v = video(rangeType: "HLG", codec: "hevc")
        let desc = try XCTUnwrap(MPVHDR.formatDescription(for: .hlg, video: v))
        XCTAssertEqual(CMVideoFormatDescriptionGetCodecType(desc), kCMVideoCodecType_HEVC)
    }

    func testSDRFormatDescription_returnsNil() {
        XCTAssertNil(MPVHDR.formatDescription(for: .sdr, video: nil))
    }

    // MARK: HDR10 fallback helper (winner's engine fallback path)

    func testHDR10FallbackFormatDescription_usesHvc1() throws {
        let v = video(rangeType: "DOVI", codec: "hevc")
        let desc = try XCTUnwrap(MPVHDR.hdr10FallbackFormatDescription(video: v),
                                 "Expected an HDR10 fallback CMVideoFormatDescription")
        XCTAssertEqual(CMVideoFormatDescriptionGetCodecType(desc), kCMVideoCodecType_HEVC,
                       "HDR10 fallback must use 'hvc1'; got \(fourCCString(CMVideoFormatDescriptionGetCodecType(desc)))")
    }

    // MARK: Metal surface stays on PQ path for DoVi

    func testDoViMetalPixelFormat_isRgba16Float() {
        XCTAssertEqual(MPVHDR.metalPixelFormat(for: .dolbyVision), .rgba16Float)
    }

    func testDoViTargetTRC_isPQ() {
        XCTAssertEqual(MPVHDR.mpvTargetTRC(for: .dolbyVision), "pq")
    }

    func testDoViColorspace_isPQBT2020() {
        let cs = MPVHDR.colorspace(for: .dolbyVision)
        XCTAssertEqual(cs?.name as String?, CGColorSpace.itur_2100_PQ as String)
    }

    // MARK: Helpers

    private func fourCCString(_ type: CMVideoCodecType) -> String {
        let bytes = [
            UInt8((type >> 24) & 0xFF),
            UInt8((type >> 16) & 0xFF),
            UInt8((type >>  8) & 0xFF),
            UInt8( type        & 0xFF)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? "0x\(String(type, radix: 16))"
    }
}

private func video(
    rangeType: String? = nil,
    range: String? = nil,
    colorTransfer: String? = nil,
    codec: String? = nil,
    width: Int = 3840,
    height: Int = 2160
) -> MediaSourceMetadata.VideoStream {
    MediaSourceMetadata.VideoStream(
        codec: codec,
        width: width,
        height: height,
        videoRange: range,
        videoRangeType: rangeType,
        colorTransfer: colorTransfer
    )
}
#endif
