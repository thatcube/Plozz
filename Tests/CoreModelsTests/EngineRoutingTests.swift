import XCTest
@testable import CoreModels

final class EngineRoutingTests: XCTestCase {

    // MARK: Helpers

    private func source(
        container: String? = nil,
        videoCodec: String? = nil,
        videoRange: String? = nil,
        videoRangeType: String? = nil,
        colorTransfer: String? = nil,
        audioCodec: String? = nil
    ) -> MediaSourceMetadata {
        MediaSourceMetadata(
            container: container,
            video: MediaSourceMetadata.VideoStream(
                codec: videoCodec,
                videoRange: videoRange,
                videoRangeType: videoRangeType,
                colorTransfer: colorTransfer
            ),
            audio: MediaSourceMetadata.AudioStream(codec: audioCodec)
        )
    }

    private func route(
        _ source: MediaSourceMetadata?,
        caps: MediaCapabilities = .default,
        isTranscoding: Bool = false,
        hybridAvailable: Bool = true
    ) -> PlaybackEngineKind {
        EngineRouter.selectEngine(
            source: source,
            capabilities: caps,
            isTranscoding: isTranscoding,
            hybridAvailable: hybridAvailable
        )
    }

    // MARK: Non-regression: hybrid unavailable / transcoding / unknown → native

    func testAlwaysNativeWhenHybridUnavailable() {
        // Even a raw MKV routes native when no hybrid engine is wired in — the
        // byte-for-byte today's behaviour (server transcode is the safety net).
        let mkv = source(container: "mkv", videoCodec: "hevc", audioCodec: "dts")
        XCTAssertEqual(route(mkv, hybridAvailable: false), .native)
    }

    func testTranscodedStreamIsAlwaysNative() {
        let mkv = source(container: "mkv", videoCodec: "hevc", audioCodec: "dts")
        XCTAssertEqual(route(mkv, isTranscoding: true), .native)
    }

    func testNilSourceIsNative() {
        XCTAssertEqual(route(nil), .native)
    }

    func testCommonAppleFileIsNative() {
        let mp4 = source(container: "mp4", videoCodec: "h264", videoRangeType: "SDR", audioCodec: "aac")
        XCTAssertEqual(route(mp4), .native)
    }

    // MARK: Dolby Vision in an Apple container → native; DoVi in an MKV → hybrid

    func testDolbyVisionMP4IsNative() {
        let mp4 = source(container: "mp4", videoCodec: "hevc", videoRangeType: "DOVIWithHDR10", audioCodec: "eac3")
        XCTAssertEqual(route(mp4), .native)
    }

    func testHDR10MP4IsNative() {
        let mp4 = source(container: "mp4", videoCodec: "hevc", videoRangeType: "HDR10", colorTransfer: "smpte2084", audioCodec: "eac3")
        XCTAssertEqual(route(mp4), .native)
    }

    func testDolbyVisionMatroskaIsHybrid() {
        // AVPlayer can't demux MKV and a DoVi transcode is unreliable, so DoVi in
        // an MKV is decoded on-device (HEVC base layer) — like Infuse.
        let mkv = source(container: "mkv", videoCodec: "hevc", videoRange: "DOVI", videoRangeType: "DOVI", audioCodec: "truehd")
        XCTAssertEqual(route(mkv), .hybrid)
    }

    func testDolbyVisionProfile8MatroskaIsHybrid() {
        let mkv = source(container: "mkv", videoCodec: "hevc", videoRangeType: "DOVIWithHDR10", audioCodec: "ac3")
        XCTAssertEqual(route(mkv), .hybrid)
    }

    func testHLGViaColorTransferIsNative() {
        let mp4 = source(container: "mp4", videoCodec: "hevc", colorTransfer: "arib-std-b67", audioCodec: "aac")
        XCTAssertEqual(route(mp4), .native)
    }

    // MARK: Matroska → hybrid

    func testSDRMatroskaIsHybrid() {
        let mkv = source(container: "mkv", videoCodec: "h264", videoRangeType: "SDR", audioCodec: "ac3")
        XCTAssertEqual(route(mkv), .hybrid)
    }

    func testWebMIsHybrid() {
        let webm = source(container: "webm", videoCodec: "vp9", audioCodec: "opus")
        XCTAssertEqual(route(webm), .hybrid)
    }

    // MARK: Plain HDR10 / HLG in an MKV → hybrid (DoVi-only forces native)

    func testHDR10MatroskaIsHybrid() {
        // Plain HDR10 (not DoVi) in an MKV is decoded on-device — no transcode.
        let mkv = source(container: "mkv", videoCodec: "hevc", videoRangeType: "HDR10", colorTransfer: "smpte2084", audioCodec: "eac3")
        XCTAssertEqual(route(mkv), .hybrid)
    }

    func testHLGMatroskaIsHybrid() {
        let mkv = source(container: "mkv", videoCodec: "hevc", videoRangeType: "HLG", colorTransfer: "arib-std-b67", audioCodec: "ac3")
        XCTAssertEqual(route(mkv), .hybrid)
    }

    func testAV1MatroskaIsHybrid() {
        // AV1 has no AVPlayer hardware path on Apple TV; the on-device engine
        // software-decodes it from an MKV.
        let mkv = source(container: "mkv", videoCodec: "av1", videoRangeType: "SDR", audioCodec: "aac")
        XCTAssertEqual(route(mkv), .hybrid)
    }

    func testHDR10MatroskaWithColorTransferOnlyIsHybrid() {
        // Even when only the coarse color-transfer signals HDR (no range token),
        // a non-DoVi HDR MKV still routes to the on-device engine.
        let mkv = source(container: "mkv", videoCodec: "hevc", colorTransfer: "smpte2084", audioCodec: "ac3")
        XCTAssertEqual(route(mkv), .hybrid)
    }

    // MARK: DTS / TrueHD audio → hybrid (unless DTS passthrough → native)

    func testDTSInAppleContainerWithoutPassthroughIsHybrid() {
        let mp4 = source(container: "mp4", videoCodec: "h264", videoRangeType: "SDR", audioCodec: "dts")
        XCTAssertEqual(route(mp4, caps: .default), .hybrid)
    }

    func testDTSInAppleContainerWithPassthroughIsNative() {
        let mp4 = source(container: "mp4", videoCodec: "h264", videoRangeType: "SDR", audioCodec: "dca")
        let passthrough = MediaCapabilities(maxOutputChannels: 8, supportsDTSPassthrough: true)
        XCTAssertEqual(route(mp4, caps: passthrough), .native)
    }

    func testTrueHDIsHybridEvenWithPassthrough() {
        // AVPlayer can't decode TrueHD at all, so it always goes hybrid.
        let mp4 = source(container: "mp4", videoCodec: "h264", videoRangeType: "SDR", audioCodec: "truehd")
        let passthrough = MediaCapabilities(maxOutputChannels: 8, supportsDTSPassthrough: true)
        XCTAssertEqual(route(mp4, caps: passthrough), .hybrid)
    }

    // MARK: Video codec → hybrid / native

    func testVC1IsHybrid() {
        let mp4 = source(container: "mp4", videoCodec: "vc1", videoRangeType: "SDR", audioCodec: "aac")
        XCTAssertEqual(route(mp4), .hybrid)
    }

    func testUnknownCodecFallsBackToNative() {
        let mp4 = source(container: "mp4", videoCodec: "some_future_codec", videoRangeType: "SDR", audioCodec: "aac")
        XCTAssertEqual(route(mp4), .native)
    }
}
