import XCTest
@testable import CoreModels

final class EngineRoutingTests: XCTestCase {

    // MARK: Helpers

    private func source(
        container: String? = nil,
        videoCodec: String? = nil,
        videoCodecTag: String? = nil,
        videoBitDepth: Int? = nil,
        videoProfile: String? = nil,
        videoIsInterlaced: Bool? = nil,
        videoRange: String? = nil,
        videoRangeType: String? = nil,
        colorTransfer: String? = nil,
        audioCodec: String? = nil
    ) -> MediaSourceMetadata {
        MediaSourceMetadata(
            container: container,
            video: MediaSourceMetadata.VideoStream(
                codec: videoCodec,
                codecTag: videoCodecTag,
                profile: videoProfile,
                isInterlaced: videoIsInterlaced,
                bitDepth: videoBitDepth,
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

    // MARK: HEVC hev1 (AVPlayer can't render) → on-device hybrid net

    func testHevcHev1InMP4RoutesToHybrid() {
        // AVPlayer plays audio with a black screen for hev1; the on-device engine
        // decodes it. (Only reached when it wasn't remuxed to hvc1 first.)
        let mp4 = source(container: "mp4", videoCodec: "hevc", videoCodecTag: "hev1", videoRangeType: "SDR", audioCodec: "aac")
        XCTAssertEqual(route(mp4), .hybrid)
    }

    func testHevcHvc1InMP4StaysNative() {
        let mp4 = source(container: "mp4", videoCodec: "hevc", videoCodecTag: "hvc1", videoRangeType: "SDR", audioCodec: "aac")
        XCTAssertEqual(route(mp4), .native)
    }

    func testHevcHev1ButTranscodingStaysNative() {
        // A successful hev1→hvc1 remux arrives as a transcode → AVPlayer.
        let mp4 = source(container: "mp4", videoCodec: "hevc", videoCodecTag: "hev1", videoRangeType: "SDR", audioCodec: "aac")
        XCTAssertEqual(route(mp4, isTranscoding: true), .native)
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

    func testM2TSIsHybrid() {
        let m2ts = source(container: "m2ts", videoCodec: "h264", audioCodec: "ac3")
        XCTAssertEqual(route(m2ts), .hybrid)
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

    // MARK: AV1 → hybrid unless hardware-decodable

    func testAV1InMP4IsHybridWithoutHardwareSupport() {
        // Apple TV 4K has no AV1 hardware decoder; default caps report no support.
        let mp4 = source(container: "mp4", videoCodec: "av1", videoRangeType: "SDR", audioCodec: "aac")
        XCTAssertEqual(route(mp4, caps: .default), .hybrid)
    }

    func testAV1StaysNativeWhenHardwareSupported() {
        // A future device that reports AV1 hardware support keeps it on AVPlayer.
        let mp4 = source(container: "mp4", videoCodec: "av01", videoRangeType: "SDR", audioCodec: "aac")
        let av1Caps = MediaCapabilities(supportsAV1: true)
        XCTAssertEqual(route(mp4, caps: av1Caps), .native)
    }

    // MARK: 10-bit H.264 → hybrid (8-bit H.264 / 10-bit HEVC stay native)

    func test10BitH264IsHybrid() {
        let mp4 = source(container: "mp4", videoCodec: "h264", videoBitDepth: 10, videoRangeType: "SDR", audioCodec: "aac")
        XCTAssertEqual(route(mp4), .hybrid)
    }

    func test10BitH264ViaProfileIsHybrid() {
        // When bit depth isn't reported, the "High 10" profile string is the tell.
        let mp4 = source(container: "mp4", videoCodec: "h264", videoProfile: "High 10", videoRangeType: "SDR", audioCodec: "aac")
        XCTAssertEqual(route(mp4), .hybrid)
    }

    func test8BitH264StaysNative() {
        let mp4 = source(container: "mp4", videoCodec: "h264", videoBitDepth: 8, videoRangeType: "SDR", audioCodec: "aac")
        XCTAssertEqual(route(mp4), .native)
    }

    func test10BitHEVCStaysNative() {
        // HEVC Main 10 is the basis of HDR and is fully supported on AVPlayer.
        let mp4 = source(container: "mp4", videoCodec: "hevc", videoCodecTag: "hvc1", videoBitDepth: 10, videoRangeType: "SDR", audioCodec: "aac")
        XCTAssertEqual(route(mp4), .native)
    }

    // MARK: Interlaced video

    func testInterlacedH264IsHybrid() {
        let mp4 = source(container: "mp4", videoCodec: "h264", videoIsInterlaced: true, videoRangeType: "SDR", audioCodec: "aac")
        XCTAssertEqual(route(mp4), .hybrid)
    }

    func testInterlacedWithoutHybridAvailabilityStaysNative() {
        let mp4 = source(container: "mp4", videoCodec: "h264", videoIsInterlaced: true, videoRangeType: "SDR", audioCodec: "aac")
        XCTAssertEqual(route(mp4, hybridAvailable: false), .native)
    }

    // MARK: Opus / Vorbis audio in MP4 → hybrid

    func testOpusAudioInMP4IsHybrid() {
        let mp4 = source(container: "mp4", videoCodec: "h264", videoRangeType: "SDR", audioCodec: "opus")
        XCTAssertEqual(route(mp4), .hybrid)
    }

    func testVorbisAudioInMP4IsHybrid() {
        let mp4 = source(container: "mp4", videoCodec: "h264", videoRangeType: "SDR", audioCodec: "vorbis")
        XCTAssertEqual(route(mp4), .hybrid)
    }

    func testAACAudioInMP4StaysNative() {
        let mp4 = source(container: "mp4", videoCodec: "h264", videoRangeType: "SDR", audioCodec: "aac")
        XCTAssertEqual(route(mp4), .native)
    }

    // MARK: - HEVC Range Extensions (4:2:2 / 4:4:4 / 12-bit)

    func testHEVC422IsHybrid() {
        let mp4 = source(container: "mp4", videoCodec: "hevc", videoCodecTag: "hvc1",
                         videoProfile: "Main 4:2:2 10", videoRangeType: "SDR", audioCodec: "aac")
        XCTAssertEqual(route(mp4), .hybrid)
    }

    func testHEVC444IsHybrid() {
        let mp4 = source(container: "mp4", videoCodec: "hevc", videoCodecTag: "hvc1",
                         videoProfile: "Main 4:4:4", videoRangeType: "SDR", audioCodec: "aac")
        XCTAssertEqual(route(mp4), .hybrid)
    }

    func testHEVC12BitIsHybrid() {
        let mp4 = source(container: "mp4", videoCodec: "hevc", videoCodecTag: "hvc1",
                         videoBitDepth: 12, videoRangeType: "SDR", audioCodec: "aac")
        XCTAssertEqual(route(mp4), .hybrid)
    }

    func testHEVCMain10StaysNative() {
        // Main 10 (4:2:0 10-bit) is HW-decodable and the basis of HDR — must stay native.
        let mp4 = source(container: "mp4", videoCodec: "hevc", videoCodecTag: "hvc1",
                         videoBitDepth: 10, videoProfile: "Main 10", videoRangeType: "SDR", audioCodec: "aac")
        XCTAssertEqual(route(mp4), .native)
    }

    // MARK: - Additional incompatible video codecs

    func testVP9IsHybrid() {
        let mp4 = source(container: "mp4", videoCodec: "vp9", videoRangeType: "SDR", audioCodec: "aac")
        XCTAssertEqual(route(mp4), .hybrid)
    }

    func testTheoraIsHybrid() {
        let mp4 = source(container: "mp4", videoCodec: "theora", videoRangeType: "SDR", audioCodec: "aac")
        XCTAssertEqual(route(mp4), .hybrid)
    }

    func testRealVideoIsHybrid() {
        let mp4 = source(container: "mp4", videoCodec: "rv40", videoRangeType: "SDR", audioCodec: "aac")
        XCTAssertEqual(route(mp4), .hybrid)
    }

    func testMPEG4Part2StaysNative() {
        // MPEG-4 Part 2 is AVFoundation-decodable and advertised as direct-play.
        let mp4 = source(container: "mp4", videoCodec: "mpeg4", videoRangeType: "SDR", audioCodec: "aac")
        XCTAssertEqual(route(mp4), .native)
    }

    // MARK: - WMA audio

    func testWMAProAudioInMP4IsHybrid() {
        let mp4 = source(container: "mp4", videoCodec: "h264", videoRangeType: "SDR", audioCodec: "wmapro")
        XCTAssertEqual(route(mp4), .hybrid)
    }

    func testWMAV2AudioInMP4IsHybrid() {
        let mp4 = source(container: "mp4", videoCodec: "h264", videoRangeType: "SDR", audioCodec: "wmav2")
        XCTAssertEqual(route(mp4), .hybrid)
    }

    // MARK: - Transport stream containers (M2TS / MTS / TS) → hybrid

    func testM2TSContainerIsHybrid() {
        // M2TS (Blu-ray raw stream) has no seek index; AVPlayer's file demux breaks
        // seeking. The hybrid engine (Plozzigen) handles it correctly.
        let m2ts = source(container: "m2ts", videoCodec: "h264", videoRangeType: "SDR", audioCodec: "ac3")
        XCTAssertEqual(route(m2ts), .hybrid)
    }

    func testMTSContainerIsHybrid() {
        let mts = source(container: "mts", videoCodec: "h264", videoRangeType: "SDR", audioCodec: "ac3")
        XCTAssertEqual(route(mts), .hybrid)
    }

    func testRawTSContainerIsHybrid() {
        let ts = source(container: "ts", videoCodec: "h264", videoRangeType: "SDR", audioCodec: "aac")
        XCTAssertEqual(route(ts), .hybrid)
    }

    func testMPEGTSContainerIsHybrid() {
        let mpegts = source(container: "mpegts", videoCodec: "h264", videoRangeType: "SDR", audioCodec: "aac")
        XCTAssertEqual(route(mpegts), .hybrid)
    }

    func testHEVCM2TSIsHybrid() {
        let m2ts = source(container: "m2ts", videoCodec: "hevc", videoRangeType: "HDR10", colorTransfer: "smpte2084", audioCodec: "eac3")
        XCTAssertEqual(route(m2ts), .hybrid)
    }

    func testTranscodedTSStaysNative() {
        // A transcoded (HLS) stream is always native regardless of the original container.
        let ts = source(container: "ts", videoCodec: "h264", videoRangeType: "SDR", audioCodec: "aac")
        XCTAssertEqual(route(ts, isTranscoding: true), .native)
    }

    func testM2TSWithoutHybridStaysNative() {
        let m2ts = source(container: "m2ts", videoCodec: "h264", videoRangeType: "SDR", audioCodec: "ac3")
        XCTAssertEqual(route(m2ts, hybridAvailable: false), .native)
    }

    // MARK: - HDR10+ color transfer detection

    func testHDR10PlusColorTransferIsRecognizedAsHDR() {
        // HDR10+ (SMPTE ST 2094-40) has an HDR10 base layer and should be routed
        // the same as HDR10: native in Apple containers, hybrid in MKV.
        let mp4 = source(container: "mp4", videoCodec: "hevc", colorTransfer: "smpte2094-40", audioCodec: "aac")
        // Apple container with HDR10+ → native (AVPlayer shows the HDR10 base)
        XCTAssertEqual(route(mp4), .native)
    }

    func testHDR10PlusInMKVIsHybrid() {
        let mkv = source(container: "mkv", videoCodec: "hevc", colorTransfer: "smpte2094-40", audioCodec: "aac")
        XCTAssertEqual(route(mkv), .hybrid)
    }
}
