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

    // MARK: Plain content in a hybrid container → native (server remuxes to HLS)

    func testSDRMatroskaIsNative() {
        // FIX A: plain SDR H.264 in an MKV is no longer direct-played to mpv. The
        // server remuxes the container to HLS and AVPlayer plays it (the lag fix).
        let mkv = source(container: "mkv", videoCodec: "h264", videoRangeType: "SDR", audioCodec: "ac3")
        XCTAssertEqual(route(mkv), .native)
    }

    func testSDRHEVCMatroskaIsNative() {
        // The reported bug: plain HEVC·SDR·1080p in an MKV → must stay native.
        let mkv = source(container: "mkv", videoCodec: "hevc", videoCodecTag: "hvc1", videoRangeType: "SDR", audioCodec: "eac3")
        XCTAssertEqual(route(mkv), .native)
    }

    func testWebMWithHybridOnlyCodecIsHybrid() {
        // WebM carrying VP9 (a codec AVPlayer can't decode) + Opus → on-device.
        let webm = source(container: "webm", videoCodec: "vp9", audioCodec: "opus")
        XCTAssertEqual(route(webm), .hybrid)
    }

    func testPlainM2TSIsNative() {
        // Plain H.264 transport stream → server remuxes to seekable HLS → native.
        let m2ts = source(container: "m2ts", videoCodec: "h264", audioCodec: "ac3")
        XCTAssertEqual(route(m2ts), .native)
    }

    // MARK: Plain HDR10 / HLG in a hybrid container → native (server remux)

    func testHDR10MatroskaIsNative() {
        // FIX A: plain HDR10 (not DoVi) in an MKV is remuxed to HLS by the server;
        // AVPlayer presents the HDR10 base on the efficient hardware path.
        let mkv = source(container: "mkv", videoCodec: "hevc", videoRangeType: "HDR10", colorTransfer: "smpte2084", audioCodec: "eac3")
        XCTAssertEqual(route(mkv), .native)
    }

    func testHLGMatroskaIsNative() {
        let mkv = source(container: "mkv", videoCodec: "hevc", videoRangeType: "HLG", colorTransfer: "arib-std-b67", audioCodec: "ac3")
        XCTAssertEqual(route(mkv), .native)
    }

    func testAV1MatroskaIsHybrid() {
        // AV1 has no AVPlayer hardware path on Apple TV; the on-device engine
        // software-decodes it from an MKV.
        let mkv = source(container: "mkv", videoCodec: "av1", videoRangeType: "SDR", audioCodec: "aac")
        XCTAssertEqual(route(mkv), .hybrid)
    }

    func testHDR10MatroskaWithColorTransferOnlyIsNative() {
        // A non-DoVi HDR MKV (even when only the coarse color-transfer signals HDR)
        // is remuxed to HLS — not sent to mpv.
        let mkv = source(container: "mkv", videoCodec: "hevc", colorTransfer: "smpte2084", audioCodec: "ac3")
        XCTAssertEqual(route(mkv), .native)
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

    // MARK: - Transport stream containers → native (server remuxes to HLS)

    func testM2TSContainerIsNative() {
        // FIX A: a plain H.264 transport stream is remuxed to a seekable HLS
        // playlist by the server — AVPlayer then plays it (no broken file seeking).
        let m2ts = source(container: "m2ts", videoCodec: "h264", videoRangeType: "SDR", audioCodec: "ac3")
        XCTAssertEqual(route(m2ts), .native)
    }

    func testMTSContainerIsNative() {
        let mts = source(container: "mts", videoCodec: "h264", videoRangeType: "SDR", audioCodec: "ac3")
        XCTAssertEqual(route(mts), .native)
    }

    func testRawTSContainerIsNative() {
        let ts = source(container: "ts", videoCodec: "h264", videoRangeType: "SDR", audioCodec: "aac")
        XCTAssertEqual(route(ts), .native)
    }

    func testMPEGTSContainerIsNative() {
        let mpegts = source(container: "mpegts", videoCodec: "h264", videoRangeType: "SDR", audioCodec: "aac")
        XCTAssertEqual(route(mpegts), .native)
    }

    func testHEVCHDR10M2TSIsNative() {
        // Plain HDR10 HEVC in a transport stream → remuxed to HLS → native.
        let m2ts = source(container: "m2ts", videoCodec: "hevc", videoRangeType: "HDR10", colorTransfer: "smpte2084", audioCodec: "eac3")
        XCTAssertEqual(route(m2ts), .native)
    }

    func testDTSInTransportStreamIsHybrid() {
        // DTS audio in a TS the server may not be able to remux losslessly →
        // decoded on-device.
        let ts = source(container: "ts", videoCodec: "h264", videoRangeType: "SDR", audioCodec: "dts")
        XCTAssertEqual(route(ts), .hybrid)
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
        // HDR10+ (SMPTE ST 2094-40) has an HDR10 base layer and is routed the same
        // as HDR10: native in any container AVPlayer or the server can serve.
        let mp4 = source(container: "mp4", videoCodec: "hevc", colorTransfer: "smpte2094-40", audioCodec: "aac")
        XCTAssertEqual(route(mp4), .native)
    }

    func testHDR10PlusInMKVIsNative() {
        // Plain HDR10+ in an MKV → server remuxes to HLS → native (not mpv).
        let mkv = source(container: "mkv", videoCodec: "hevc", colorTransfer: "smpte2094-40", audioCodec: "aac")
        XCTAssertEqual(route(mkv), .native)
    }

    // MARK: - Hybrid-container audio that needs on-device decode (incl. passthrough)

    func testDTSInMatroskaIsHybrid() {
        let mkv = source(container: "mkv", videoCodec: "hevc", videoRangeType: "SDR", audioCodec: "dts")
        XCTAssertEqual(route(mkv), .hybrid)
    }

    func testDTSInMatroskaIsHybridEvenWithPassthrough() {
        // Unlike an Apple container, DTS in a hybrid container can't be reached by
        // AVPlayer's passthrough (it can't demux the container), so it must be
        // decoded on-device even when the route supports DTS bitstreaming.
        let mkv = source(container: "mkv", videoCodec: "hevc", videoRangeType: "SDR", audioCodec: "dca")
        let passthrough = MediaCapabilities(maxOutputChannels: 8, supportsDTSPassthrough: true)
        XCTAssertEqual(route(mkv, caps: passthrough), .hybrid)
    }

    func testTrueHDInMatroskaIsHybrid() {
        let mkv = source(container: "mkv", videoCodec: "hevc", videoRangeType: "SDR", audioCodec: "truehd")
        XCTAssertEqual(route(mkv), .hybrid)
    }

    func testOpusInMatroskaIsHybrid() {
        let mkv = source(container: "mkv", videoCodec: "hevc", videoRangeType: "SDR", audioCodec: "opus")
        XCTAssertEqual(route(mkv), .hybrid)
    }
}
