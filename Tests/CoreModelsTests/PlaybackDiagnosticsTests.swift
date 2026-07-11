import XCTest
@testable import CoreModels

final class PlaybackDiagnosticsHDRTests: XCTestCase {
    typealias HDR = PlaybackDiagnostics.HDRFormat

    func testDolbyVisionDetectedFromCodecTag() {
        XCTAssertEqual(PlaybackDiagnostics.classifyHDR(videoCodec: "dvh1", transferFunction: nil), .dolbyVision)
        XCTAssertEqual(PlaybackDiagnostics.classifyHDR(videoCodec: "dvhe", transferFunction: "SMPTE_ST_2084_PQ"), .dolbyVision)
        XCTAssertEqual(PlaybackDiagnostics.classifyHDR(videoCodec: "DVAV", transferFunction: nil), .dolbyVision)
    }

    func testHDR10DetectedFromPQTransferFunction() {
        XCTAssertEqual(PlaybackDiagnostics.classifyHDR(videoCodec: "hvc1", transferFunction: "SMPTE_ST_2084_PQ"), .hdr10)
        XCTAssertEqual(PlaybackDiagnostics.classifyHDR(videoCodec: "hvc1", transferFunction: "smpte_st_2084"), .hdr10)
    }

    func testHLGDetectedFromTransferFunction() {
        XCTAssertEqual(PlaybackDiagnostics.classifyHDR(videoCodec: "hvc1", transferFunction: "ITU_R_2100_HLG"), .hlg)
        XCTAssertEqual(PlaybackDiagnostics.classifyHDR(videoCodec: "hvc1", transferFunction: "Aribb67_HLG"), .hlg)
    }

    func testSDRWhenTransferFunctionIsRec709OrMissing() {
        XCTAssertEqual(PlaybackDiagnostics.classifyHDR(videoCodec: "avc1", transferFunction: "ITU_R_709_2"), .sdr)
        XCTAssertEqual(PlaybackDiagnostics.classifyHDR(videoCodec: "avc1", transferFunction: nil), .sdr)
        XCTAssertEqual(PlaybackDiagnostics.classifyHDR(videoCodec: nil, transferFunction: ""), .sdr)
    }

    func testDolbyVisionTakesPrecedenceOverTransferFunction() {
        // A DV codec with a PQ base layer is still reported as Dolby Vision.
        XCTAssertEqual(PlaybackDiagnostics.classifyHDR(videoCodec: "dvh1", transferFunction: "SMPTE_ST_2084_PQ"), .dolbyVision)
    }

    func testFriendlyCodecNames() {
        XCTAssertEqual(PlaybackDiagnostics.friendlyCodecName("avc1"), "H.264")
        XCTAssertEqual(PlaybackDiagnostics.friendlyCodecName("hvc1"), "HEVC")
        XCTAssertEqual(PlaybackDiagnostics.friendlyCodecName("hevc"), "HEVC")
        XCTAssertEqual(PlaybackDiagnostics.friendlyCodecName("ec-3"), "Dolby Digital+")
        XCTAssertEqual(PlaybackDiagnostics.friendlyCodecName("eac3"), "Dolby Digital+")
        XCTAssertEqual(PlaybackDiagnostics.friendlyCodecName("truehd"), "Dolby TrueHD")
        XCTAssertEqual(PlaybackDiagnostics.friendlyCodecName("subrip"), "SubRip")
        XCTAssertEqual(PlaybackDiagnostics.friendlyCodecName("mp4a"), "AAC")
        XCTAssertEqual(PlaybackDiagnostics.friendlyCodecName("xyz9"), "XYZ9")
        XCTAssertNil(PlaybackDiagnostics.friendlyCodecName(nil))
        XCTAssertNil(PlaybackDiagnostics.friendlyCodecName(""))
    }

    func testHDRFromProviderRangeTokens() {
        XCTAssertEqual(PlaybackDiagnostics.classifyHDR(videoRange: "HDR", videoRangeType: "DOVI"), .dolbyVision)
        XCTAssertEqual(PlaybackDiagnostics.classifyHDR(videoRange: "HDR", videoRangeType: "HDR10"), .hdr10)
        XCTAssertEqual(PlaybackDiagnostics.classifyHDR(videoRange: "HDR", videoRangeType: "HLG"), .hlg)
        XCTAssertEqual(PlaybackDiagnostics.classifyHDR(videoRange: "SDR", videoRangeType: "SDR"), .sdr)
        XCTAssertEqual(PlaybackDiagnostics.classifyHDR(videoRange: "HDR", videoRangeType: "HDR10Plus"), .hdr10Plus)
        XCTAssertEqual(
            PlaybackDiagnostics.classifyHDR(videoRange: nil, videoRangeType: nil, colorTransfer: "smpte2084"),
            .hdr10
        )
        XCTAssertEqual(
            PlaybackDiagnostics.classifyHDR(videoRange: nil, videoRangeType: nil, isDolbyVision: true),
            .dolbyVision
        )
        XCTAssertEqual(PlaybackDiagnostics.classifyHDR(videoRange: nil, videoRangeType: nil), .unknown)
    }

    func testSourceFilenameHandlesWindowsAndPOSIXPaths() {
        XCTAssertEqual(
            PlaybackRequest.sourceFileName(from: #"D:\Media\Movies\Film.mkv"#),
            "Film.mkv"
        )
        XCTAssertEqual(
            PlaybackRequest.sourceFileName(from: "/media/movies/Film.mkv"),
            "Film.mkv"
        )
    }

    func testFriendlyContainerNames() {
        XCTAssertEqual(PlaybackDiagnostics.friendlyContainerName("mkv"), "Matroska")
        XCTAssertEqual(PlaybackDiagnostics.friendlyContainerName("mp4"), "MP4")
        XCTAssertEqual(PlaybackDiagnostics.friendlyContainerName("webm"), "WebM")
        XCTAssertEqual(PlaybackDiagnostics.friendlyContainerName("xyz"), "XYZ")
        XCTAssertNil(PlaybackDiagnostics.friendlyContainerName(nil))
    }

    func testSourceFileNameText() {
        var diagnostics = PlaybackDiagnostics(sourceFileName: "Movie (2024) 2160p.mkv")
        XCTAssertEqual(diagnostics.sourceFileNameText, "Movie (2024) 2160p.mkv")

        diagnostics.sourceFileName = "   "
        XCTAssertEqual(diagnostics.sourceFileNameText, PlaybackDiagnostics.placeholder)
    }

    func testContainerLabelPairsFriendlyNameWithRawToken() {
        XCTAssertEqual(PlaybackDiagnostics.containerLabel("mkv"), "Matroska (MKV)")
        XCTAssertEqual(PlaybackDiagnostics.containerLabel("webm"), "WebM")
        XCTAssertEqual(PlaybackDiagnostics.containerLabel("mp4"), "MP4")
        XCTAssertEqual(PlaybackDiagnostics.containerLabel("xyz"), "XYZ")
        XCTAssertNil(PlaybackDiagnostics.containerLabel(nil))
        XCTAssertNil(PlaybackDiagnostics.containerLabel("  "))
    }

    func testFriendlyAudioNamePrefersSpatialProfile() {
        XCTAssertEqual(PlaybackDiagnostics.friendlyAudioName(codec: "eac3", profile: "Dolby Atmos"), "Dolby Atmos")
        XCTAssertEqual(PlaybackDiagnostics.friendlyAudioName(codec: "dts", profile: "DTS:X"), "DTS:X")
        XCTAssertEqual(PlaybackDiagnostics.friendlyAudioName(codec: "eac3", profile: nil), "Dolby Digital+")
        XCTAssertEqual(PlaybackDiagnostics.friendlyAudioName(codec: "aac", profile: "LC"), "AAC")
    }

    func testChannelDescription() {
        XCTAssertEqual(PlaybackDiagnostics.channelDescription(layout: "5.1(side)", channels: 6), "5.1")
        XCTAssertEqual(PlaybackDiagnostics.channelDescription(layout: nil, channels: 8), "7.1")
        XCTAssertEqual(PlaybackDiagnostics.channelDescription(layout: nil, channels: 2), "Stereo")
        XCTAssertEqual(PlaybackDiagnostics.channelDescription(layout: "stereo", channels: 2), "Stereo")
        XCTAssertEqual(PlaybackDiagnostics.channelDescription(layout: nil, channels: 3), "3ch")
        XCTAssertNil(PlaybackDiagnostics.channelDescription(layout: nil, channels: nil))
    }

    func testAudioOutputDescriptionReportsAtmosPassthroughExpectation() {
        let atmosRoute = MediaCapabilities(maxOutputChannels: 6, supportsAtmos: true)
        XCTAssertEqual(
            PlaybackDiagnostics.audioOutputDescription(
                codec: "eac3",
                profile: "Dolby Atmos",
                channels: 6,
                capabilities: atmosRoute
            ),
            "E-AC-3 JOC Atmos passthrough expected"
        )

        let stereoRoute = MediaCapabilities(maxOutputChannels: 2, supportsAtmos: false)
        XCTAssertEqual(
            PlaybackDiagnostics.audioOutputDescription(
                codec: "eac3",
                profile: "Dolby Atmos",
                channels: 6,
                capabilities: stereoRoute
            ),
            "Atmos present; route may fall back to 5.1"
        )
    }
}

final class PlaybackDiagnosticsFormattingTests: XCTestCase {
    func testBitrateFormatting() {
        XCTAssertEqual(PlaybackDiagnostics.formatBitrate(12_300_000), "12.3 Mbps")
        XCTAssertEqual(PlaybackDiagnostics.formatBitrate(850_000), "850 Kbps")
        XCTAssertEqual(PlaybackDiagnostics.formatBitrate(512), "512 bps")
        XCTAssertEqual(PlaybackDiagnostics.formatBitrate(0), "—")
        XCTAssertEqual(PlaybackDiagnostics.formatBitrate(nil), "—")
        XCTAssertEqual(PlaybackDiagnostics.formatBitrate(-5), "—")
    }

    func testBufferFormatting() {
        XCTAssertEqual(PlaybackDiagnostics.formatBuffer(12), "12.0s")
        XCTAssertEqual(PlaybackDiagnostics.formatBuffer(0), "0.0s")
        XCTAssertEqual(PlaybackDiagnostics.formatBuffer(nil), "—")
        XCTAssertEqual(PlaybackDiagnostics.formatBuffer(.infinity), "—")
        XCTAssertEqual(PlaybackDiagnostics.formatBuffer(-1), "—")
    }

    func testFrameRateFormatting() {
        XCTAssertEqual(PlaybackDiagnostics.formatFrameRate(23.976), "23.98 fps")
        XCTAssertEqual(PlaybackDiagnostics.formatFrameRate(60), "60.00 fps")
        XCTAssertEqual(PlaybackDiagnostics.formatFrameRate(0), "—")
        XCTAssertEqual(PlaybackDiagnostics.formatFrameRate(nil), "—")
    }

    func testResolutionFormattingAndQualityLabels() {
        XCTAssertEqual(PlaybackDiagnostics.formatResolution(.init(width: 3840, height: 2160)), "3840×2160 (4K)")
        XCTAssertEqual(PlaybackDiagnostics.formatResolution(.init(width: 1920, height: 1080)), "1920×1080 (1080p)")
        XCTAssertEqual(PlaybackDiagnostics.formatResolution(.init(width: 1280, height: 720)), "1280×720 (720p)")
        XCTAssertEqual(PlaybackDiagnostics.formatResolution(nil), "—")
        XCTAssertEqual(PlaybackDiagnostics.formatResolution(.init(width: 0, height: 0)), "—")
    }

    func testQualityLabelBuckets() {
        XCTAssertEqual(PlaybackDiagnostics.VideoResolution(width: 7680, height: 4320).qualityLabel, "8K")
        XCTAssertEqual(PlaybackDiagnostics.VideoResolution(width: 2560, height: 1440).qualityLabel, "1440p")
        XCTAssertEqual(PlaybackDiagnostics.VideoResolution(width: 640, height: 480).qualityLabel, "480p")
        XCTAssertEqual(PlaybackDiagnostics.VideoResolution(width: 320, height: 240).qualityLabel, "SD")
    }

    func testInstanceConvenienceTextUsesFormatters() {
        let diagnostics = PlaybackDiagnostics(
            resolution: .init(width: 1920, height: 1080),
            indicatedBitrate: 8_000_000,
            observedBitrate: nil,
            bufferedSecondsAhead: 30,
            droppedVideoFrames: 4,
            frameRate: 24
        )
        XCTAssertEqual(diagnostics.resolutionText, "1920×1080 (1080p)")
        XCTAssertEqual(diagnostics.indicatedBitrateText, "8.0 Mbps")
        XCTAssertEqual(diagnostics.observedBitrateText, "—")
        XCTAssertEqual(diagnostics.bufferText, "30.0s")
        XCTAssertEqual(diagnostics.droppedFramesText, "4")
        XCTAssertEqual(diagnostics.frameRateText, "24.00 fps")
    }

    func testModeAndHDRDisplayNames() {
        XCTAssertEqual(PlaybackDiagnostics.PlaybackMode.directPlay.displayName, "Direct Play")
        XCTAssertEqual(PlaybackDiagnostics.PlaybackMode.remux.displayName, "Remux (server, lossless)")
        XCTAssertEqual(PlaybackDiagnostics.PlaybackMode.transcode.displayName, "Transcode (server)")
        XCTAssertEqual(PlaybackDiagnostics.HDRFormat.dolbyVision.displayName, "Dolby Vision")
        XCTAssertEqual(PlaybackDiagnostics.HDRFormat.hdr10.displayName, "HDR10 (PQ)")
        XCTAssertEqual(PlaybackDiagnostics.HDRFormat.hlg.displayName, "HDR (HLG)")
        XCTAssertEqual(PlaybackDiagnostics.HDRFormat.sdr.displayName, "SDR")
    }

    func testSampleRateFormatting() {
        XCTAssertEqual(PlaybackDiagnostics.formatSampleRate(48000), "48 kHz")
        XCTAssertEqual(PlaybackDiagnostics.formatSampleRate(44100), "44.1 kHz")
        XCTAssertNil(PlaybackDiagnostics.formatSampleRate(0))
        XCTAssertNil(PlaybackDiagnostics.formatSampleRate(nil))
    }

    func testByteFormatting() {
        XCTAssertEqual(PlaybackDiagnostics.formatBytes(1_073_741_824), "1.00 GB")
        XCTAssertEqual(PlaybackDiagnostics.formatBytes(52_428_800), "50 MB")
        XCTAssertNil(PlaybackDiagnostics.formatBytes(0))
        XCTAssertNil(PlaybackDiagnostics.formatBytes(nil))
    }

    func testBufferStatusBuckets() {
        XCTAssertEqual(PlaybackDiagnostics.bufferStatus(seconds: 0.5), "Buffering")
        XCTAssertEqual(PlaybackDiagnostics.bufferStatus(seconds: 5), "Low")
        XCTAssertEqual(PlaybackDiagnostics.bufferStatus(seconds: 30), "Healthy")
        XCTAssertEqual(PlaybackDiagnostics.bufferStatus(seconds: nil), "—")
    }

    func testLanguageDisplayName() {
        XCTAssertEqual(PlaybackDiagnostics.languageDisplayName("en"), "English")
        XCTAssertEqual(PlaybackDiagnostics.languageDisplayName("fra"), "French")
        XCTAssertNil(PlaybackDiagnostics.languageDisplayName(nil))
    }

    func testBaseFromSourceMetadataBuildsCompositeLines() {
        let metadata = MediaSourceMetadata(
            container: "mkv",
            video: .init(
                codec: "hevc",
                codecTag: "dvh1",
                profile: "Main 10",
                width: 1920,
                height: 1080,
                bitDepth: 10,
                bitrate: 4_830_000,
                frameRate: 24,
                videoRange: "HDR",
                videoRangeType: "DOVI",
                colorTransfer: "smpte2084"
            ),
            audio: .init(
                codec: "eac3",
                profile: "Dolby Atmos",
                channels: 6,
                channelLayout: "5.1",
                sampleRate: 48000,
                bitrate: 768_000
            ),
            subtitle: .init(codec: "subrip", language: "eng")
        )
        let capabilities = MediaCapabilities(maxOutputChannels: 6, supportsAtmos: true)
        let d = PlaybackDiagnostics.base(
            from: metadata,
            mode: .directPlay,
            capabilities: capabilities,
            sourceProvider: .plex
        )

        XCTAssertEqual(d.containerText, "Matroska (MKV)")
        XCTAssertEqual(d.hdr, .dolbyVision)
        XCTAssertEqual(d.videoLineText, "HEVC · Dolby Vision · 1920×1080 · 4.8 Mbps · 24.00 fps")
        XCTAssertEqual(d.audioLineText, "Dolby Atmos · 48 kHz · 5.1 · 768 Kbps")
        XCTAssertEqual(d.audioOutputText, "E-AC-3 JOC Atmos passthrough expected")
        XCTAssertEqual(d.subtitleText, "SubRip · English")
        XCTAssertEqual(d.mode, .directPlay)
        // Enriched diagnostics fields.
        XCTAssertEqual(d.sourceProviderText, "Plex")
        XCTAssertEqual(d.videoCodecTagText, "dvh1")
        XCTAssertEqual(d.dolbyVisionProfile, 5)
        XCTAssertEqual(d.dolbyVisionText, "Profile 5 (single-layer · no HDR10 fallback)")
        XCTAssertEqual(d.colorText, "10-bit · PQ (ST 2084) · DOVI")
    }

    func testBaseFromNilMetadataIsEmptyButPlaceholdered() {
        let d = PlaybackDiagnostics.base(from: nil, mode: .transcode)
        XCTAssertEqual(d.videoLineText, "—")
        XCTAssertEqual(d.audioLineText, "—")
        XCTAssertEqual(d.containerText, "—")
        XCTAssertEqual(d.subtitleText, "—")
    }
}

final class PlaybackDiagnosticsEnrichedTests: XCTestCase {
    func testFormatTimecode() {
        XCTAssertEqual(PlaybackDiagnostics.formatTimecode(0), "0:00")
        XCTAssertEqual(PlaybackDiagnostics.formatTimecode(75), "1:15")
        XCTAssertEqual(PlaybackDiagnostics.formatTimecode(3600 + 58 * 60 + 24), "1:58:24")
        XCTAssertEqual(PlaybackDiagnostics.formatTimecode(nil), "—")
        XCTAssertEqual(PlaybackDiagnostics.formatTimecode(.infinity), "—")
    }

    func testFormatSeekWindowFlagsFullTimelineVsServerWindow() {
        // A true app-owned remux: the whole movie is seekable.
        XCTAssertEqual(
            PlaybackDiagnostics.formatSeekWindow(start: 0, end: 7104, duration: 7104),
            "0:00–1:58:24 of 1:58:24 · full timeline"
        )
        // A throttled server HLS window: only a short trailing span is seekable.
        XCTAssertEqual(
            PlaybackDiagnostics.formatSeekWindow(start: 30, end: 51, duration: 7104),
            "0:30–0:51 of 1:58:24 · server window 21s"
        )
        XCTAssertEqual(
            PlaybackDiagnostics.formatSeekWindow(start: nil, end: nil, duration: 7104),
            "—"
        )
    }

    func testDolbyVisionDescription() {
        XCTAssertEqual(
            PlaybackDiagnostics.dolbyVisionDescription(profile: 5),
            "Profile 5 (single-layer · no HDR10 fallback)"
        )
        XCTAssertEqual(
            PlaybackDiagnostics.dolbyVisionDescription(profile: 8),
            "Profile 8 (single-layer · HDR10-compatible)"
        )
        XCTAssertEqual(
            PlaybackDiagnostics.dolbyVisionDescription(profile: 7),
            "Profile 7 (dual-layer · hybrid engine)"
        )
        XCTAssertNil(PlaybackDiagnostics.dolbyVisionDescription(profile: nil))
    }

    func testTransferFunctionLabel() {
        XCTAssertEqual(PlaybackDiagnostics.transferFunctionLabel("smpte2084"), "PQ (ST 2084)")
        XCTAssertEqual(PlaybackDiagnostics.transferFunctionLabel("arib-std-b67"), "HLG")
        XCTAssertEqual(PlaybackDiagnostics.transferFunctionLabel("bt709"), "BT.709")
        XCTAssertNil(PlaybackDiagnostics.transferFunctionLabel(nil))
    }

    func testColorDescription() {
        XCTAssertEqual(
            PlaybackDiagnostics.colorDescription(bitDepth: 10, transfer: "smpte2084", rangeType: "DOVI"),
            "10-bit · PQ (ST 2084) · DOVI"
        )
        XCTAssertEqual(
            PlaybackDiagnostics.colorDescription(bitDepth: 10, transfer: nil, rangeType: nil),
            "10-bit"
        )
        XCTAssertNil(PlaybackDiagnostics.colorDescription(bitDepth: nil, transfer: nil, rangeType: nil))
    }

    func testStreamTransportSummaryFlagsLocalAndStripsTokens() {
        let local = URL(string: "http://127.0.0.1:52344/remux/master.m3u8?token=secret")!
        XCTAssertEqual(
            PlaybackDiagnostics.streamTransportSummary(url: local),
            "App-local 127.0.0.1:52344 · HLS"
        )
        let server = URL(string: "https://media.example.com/video/start.m3u8?X-Plex-Token=abc123")!
        XCTAssertEqual(
            PlaybackDiagnostics.streamTransportSummary(url: server),
            "media.example.com · HLS"
        )
        let progressive = URL(string: "http://127.0.0.1:8888/stream.mp4")!
        XCTAssertEqual(
            PlaybackDiagnostics.streamTransportSummary(url: progressive),
            "App-local 127.0.0.1:8888 · fMP4/MP4"
        )
        XCTAssertNil(PlaybackDiagnostics.streamTransportSummary(url: nil))
    }

    func testCodecTagFlagsHev1BlackScreenRisk() {
        var hev1 = PlaybackDiagnostics()
        hev1.videoCodecTag = "hev1"
        XCTAssertEqual(hev1.videoCodecTagText, "hev1 (AVPlayer needs hvc1 — black-screen risk)")

        var hvc1 = PlaybackDiagnostics()
        hvc1.videoCodecTag = "hvc1"
        XCTAssertEqual(hvc1.videoCodecTagText, "hvc1")
    }

    func testPositionAndSeekWindowInstanceText() {
        var d = PlaybackDiagnostics()
        d.positionSeconds = 754
        d.durationSeconds = 7104
        d.seekableStartSeconds = 0
        d.seekableEndSeconds = 7104
        XCTAssertEqual(d.positionText, "12:34 / 1:58:24")
        XCTAssertEqual(d.seekWindowText, "0:00–1:58:24 of 1:58:24 · full timeline")
    }
}

final class DiagnosticsSettingsStoreTests: XCTestCase {
    func testRoundTripPersistsEnabledFlag() {
        let defaults = UserDefaults(suiteName: "DiagnosticsSettingsStoreTests")!
        defaults.removePersistentDomain(forName: "DiagnosticsSettingsStoreTests")
        let store = DiagnosticsSettingsStore(defaults: defaults)

        XCTAssertEqual(store.load(), .default)
        XCTAssertFalse(store.load().isEnabled)

        store.save(DiagnosticsSettings(isEnabled: true))
        XCTAssertTrue(store.load().isEnabled)
    }
}
