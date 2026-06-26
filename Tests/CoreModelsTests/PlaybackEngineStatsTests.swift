import XCTest
@testable import CoreModels

final class PlaybackEngineStatsTests: XCTestCase {
    typealias DecodePath = PlaybackEngineStats.DecodePath

    // MARK: hwdec-current → decode path

    func testHardwareDecodeFromVideoToolbox() {
        XCTAssertEqual(PlaybackEngineStats.decodePath(fromHWDecCurrent: "videotoolbox"), .hardware)
        XCTAssertEqual(PlaybackEngineStats.decodePath(fromHWDecCurrent: "videotoolbox-copy"), .hardware)
    }

    func testSoftwareDecodeFromNoOrNone() {
        XCTAssertEqual(PlaybackEngineStats.decodePath(fromHWDecCurrent: "no"), .software)
        XCTAssertEqual(PlaybackEngineStats.decodePath(fromHWDecCurrent: "NONE"), .software)
    }

    func testUnknownDecodeFromEmptyOrNil() {
        XCTAssertEqual(PlaybackEngineStats.decodePath(fromHWDecCurrent: nil), .unknown)
        XCTAssertEqual(PlaybackEngineStats.decodePath(fromHWDecCurrent: ""), .unknown)
        XCTAssertEqual(PlaybackEngineStats.decodePath(fromHWDecCurrent: "   "), .unknown)
    }

    // MARK: apply(engineStats:) merge

    func testApplyMergesEngineStats() {
        var d = PlaybackDiagnostics()
        d.apply(engineStats: PlaybackEngineStats(
            decodePath: .software,
            hwdecName: "no",
            decoderDroppedFrames: 42,
            lateFrames: 7,
            renderedFrameRate: 18.5,
            containerFrameRate: 23.976
        ))
        XCTAssertEqual(d.decodePath, .software)
        XCTAssertEqual(d.hwdecName, "no")
        XCTAssertEqual(d.engineDecoderDropFrames, 42)
        XCTAssertEqual(d.engineLateFrames, 7)
        XCTAssertEqual(d.renderedFrameRate, 18.5)
        XCTAssertEqual(d.frameRate, 23.976) // container fps fills frameRate when empty
    }

    func testApplyNeverErasesKnownFactsWithUnknownSample() {
        var d = PlaybackDiagnostics()
        d.decodePath = .hardware
        d.frameRate = 24
        d.apply(engineStats: PlaybackEngineStats()) // all unknown/nil
        XCTAssertEqual(d.decodePath, .hardware)
        XCTAssertEqual(d.frameRate, 24)
        XCTAssertNil(d.renderedFrameRate)
    }

    func testApplyDoesNotOverwriteProviderFrameRate() {
        var d = PlaybackDiagnostics()
        d.frameRate = 23.976
        d.apply(engineStats: PlaybackEngineStats(containerFrameRate: 25))
        XCTAssertEqual(d.frameRate, 23.976)
    }

    // MARK: Formatting

    func testDecodeTextHardwareAndSoftware() {
        var d = PlaybackDiagnostics()
        d.apply(engineStats: PlaybackEngineStats(decodePath: .hardware, hwdecName: "videotoolbox"))
        XCTAssertEqual(d.decodeText, "Hardware (videotoolbox)")
        XCTAssertFalse(d.isSoftwareDecoding)

        var s = PlaybackDiagnostics()
        s.apply(engineStats: PlaybackEngineStats(decodePath: .software, hwdecName: "no"))
        XCTAssertEqual(s.decodeText, "Software (CPU)")
        XCTAssertTrue(s.isSoftwareDecoding)
    }

    func testDecodeTextHiddenWhenUnknown() {
        XCTAssertNil(PlaybackDiagnostics().decodeText)
    }

    func testRenderRateTextWithAndWithoutTarget() {
        var d = PlaybackDiagnostics()
        d.frameRate = 23.976
        d.renderedFrameRate = 18.4
        XCTAssertEqual(d.renderRateText, "18.4 / 23.98 fps")

        var n = PlaybackDiagnostics()
        n.renderedFrameRate = 23.9
        XCTAssertEqual(n.renderRateText, "23.9 fps")

        XCTAssertNil(PlaybackDiagnostics().renderRateText)
    }

    func testEngineDropsText() {
        var d = PlaybackDiagnostics()
        d.engineDecoderDropFrames = 12
        d.engineLateFrames = 3
        XCTAssertEqual(d.engineDropsText, "decoder 12 · late 3")

        var only = PlaybackDiagnostics()
        only.engineDecoderDropFrames = 5
        XCTAssertEqual(only.engineDropsText, "decoder 5")

        XCTAssertNil(PlaybackDiagnostics().engineDropsText)
    }

    func testMainThreadTextOKAndHitch() {
        var ok = PlaybackDiagnostics()
        ok.mainThreadHitchMillis = 40
        XCTAssertEqual(ok.mainThreadText, "OK")
        XCTAssertFalse(ok.hasMainThreadHitch)

        var hitch = PlaybackDiagnostics()
        hitch.mainThreadHitchMillis = 420
        XCTAssertEqual(hitch.mainThreadText, "hitch 420 ms")
        XCTAssertTrue(hitch.hasMainThreadHitch)

        XCTAssertNil(PlaybackDiagnostics().mainThreadText)
    }
}
