import XCTest
@testable import ProviderTrailers

final class TrailerStreamSelectionTests: XCTestCase {
    private let video = URL(string: "https://example.com/v")!
    private let audio = URL(string: "https://example.com/a")!
    private let other = URL(string: "https://example.com/x")!

    private func progressive(_ resolution: Int, native: Bool = true) -> TrailerStreamCandidate {
        TrailerStreamCandidate(
            url: other, resolution: resolution, isProgressive: true,
            hasVideo: true, hasAudio: true, isNativelyPlayable: native,
            videoKind: .avc1, bitrate: nil, audioNativelyPlayable: true
        )
    }

    private func videoOnly(_ resolution: Int, kind: TrailerStreamCandidate.VideoKind = .avc1, url: URL? = nil) -> TrailerStreamCandidate {
        TrailerStreamCandidate(
            url: url ?? video, resolution: resolution, isProgressive: false,
            hasVideo: true, hasAudio: false, isNativelyPlayable: kind == .avc1,
            videoKind: kind, bitrate: nil, audioNativelyPlayable: false
        )
    }

    private func audioOnly(bitrate: Int, native: Bool = true, url: URL? = nil) -> TrailerStreamCandidate {
        TrailerStreamCandidate(
            url: url ?? audio, resolution: nil, isProgressive: false,
            hasVideo: false, hasAudio: true, isNativelyPlayable: native,
            videoKind: .none, bitrate: bitrate, audioNativelyPlayable: native
        )
    }

    func testPrefersAdaptiveHiResOverLowProgressive() {
        let result = TrailerStreamSelector.selectTrailerStream(
            from: [progressive(360), videoOnly(1080), audioOnly(bitrate: 128_000)],
            allowAdaptive: true
        )
        XCTAssertEqual(result?.videoURL, video)
        XCTAssertEqual(result?.audioURL, audio)
        XCTAssertEqual(result?.resolution, 1080)
        XCTAssertTrue(result?.isAdaptive ?? false)
    }

    func testWithoutHybridFallsBackToProgressive() {
        let result = TrailerStreamSelector.selectTrailerStream(
            from: [progressive(360), videoOnly(1080), audioOnly(bitrate: 128_000)],
            allowAdaptive: false
        )
        XCTAssertEqual(result?.videoURL, other)
        XCTAssertNil(result?.audioURL)
        XCTAssertEqual(result?.resolution, 360)
    }

    func testNoAudioOnlyMeansNoAdaptive() {
        // A hi-res video-only stream with no companion audio can't be muxed → the
        // reliable progressive muxed stream is used instead.
        let result = TrailerStreamSelector.selectTrailerStream(
            from: [progressive(480), videoOnly(1080)],
            allowAdaptive: true
        )
        XCTAssertEqual(result?.videoURL, other)
        XCTAssertNil(result?.audioURL)
        XCTAssertEqual(result?.resolution, 480)
    }

    func testPrefersHardwareH264OverHigherVP9() {
        // 720p H.264 (hardware-decoded) beats 1080p VP9 (software) for reliability.
        let h264 = URL(string: "https://example.com/h264")!
        let result = TrailerStreamSelector.selectTrailerStream(
            from: [
                progressive(360),
                videoOnly(720, kind: .avc1, url: h264),
                videoOnly(1080, kind: .vp9, url: video),
                audioOnly(bitrate: 128_000)
            ],
            allowAdaptive: true
        )
        XCTAssertEqual(result?.videoURL, h264)
        XCTAssertEqual(result?.resolution, 720)
    }

    func testFallsBackToVP9WhenNoH264VideoOnly() {
        let result = TrailerStreamSelector.selectTrailerStream(
            from: [videoOnly(1080, kind: .vp9), audioOnly(bitrate: 160_000)],
            allowAdaptive: true
        )
        XCTAssertEqual(result?.videoURL, video)
        XCTAssertEqual(result?.resolution, 1080)
        XCTAssertTrue(result?.isAdaptive ?? false)
    }

    func testAdaptiveResolutionIsCapped() {
        // A 2160p video-only is ignored above the cap; the 1080p track wins.
        let uhd = URL(string: "https://example.com/uhd")!
        let result = TrailerStreamSelector.selectTrailerStream(
            from: [videoOnly(2160, kind: .avc1, url: uhd), videoOnly(1080, kind: .avc1, url: video), audioOnly(bitrate: 128_000)],
            allowAdaptive: true,
            maxAdaptiveResolution: 1080
        )
        XCTAssertEqual(result?.videoURL, video)
        XCTAssertEqual(result?.resolution, 1080)
    }

    func testPrefersNativeAACAudioByBitrate() {
        let aac = URL(string: "https://example.com/aac")!
        let opus = URL(string: "https://example.com/opus")!
        let result = TrailerStreamSelector.selectTrailerStream(
            from: [
                videoOnly(1080),
                audioOnly(bitrate: 160_000, native: false, url: opus),
                audioOnly(bitrate: 128_000, native: true, url: aac)
            ],
            allowAdaptive: true
        )
        // AAC (native) is chosen over the higher-bitrate Opus.
        XCTAssertEqual(result?.audioURL, aac)
    }

    func testProgressiveOnlyReturnsProgressive() {
        let result = TrailerStreamSelector.selectTrailerStream(
            from: [progressive(720), progressive(360)],
            allowAdaptive: true
        )
        XCTAssertEqual(result?.resolution, 720)
        XCTAssertNil(result?.audioURL)
    }

    func testEmptyCandidatesReturnNil() {
        XCTAssertNil(TrailerStreamSelector.selectTrailerStream(from: [], allowAdaptive: true))
    }

    func testAdaptiveMustStrictlyBeatProgressive() {
        // Equal resolution → keep the reliable progressive muxed stream.
        let result = TrailerStreamSelector.selectTrailerStream(
            from: [progressive(1080), videoOnly(1080), audioOnly(bitrate: 128_000)],
            allowAdaptive: true
        )
        XCTAssertEqual(result?.videoURL, other)
        XCTAssertNil(result?.audioURL)
    }
}
