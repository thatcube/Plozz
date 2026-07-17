import XCTest
@testable import CoreModels

final class SourceDynamicRangeTests: XCTestCase {
    func testMissingMetadataStaysUnknownWhileAwaitingEngineProbe() {
        let resolution = EffectiveDynamicRange.awaitingEngineProbe(metadata: nil)

        XCTAssertEqual(resolution, .awaitingEngineProbe(hint: nil))
        XCTAssertNil(resolution.bestAvailable)
        XCTAssertTrue(resolution.isAwaitingEngineProbe)
    }

    func testProviderHintsRecognizeSupportedRanges() {
        XCTAssertEqual(hint(rangeType: "DOVIWithHDR10"), .dolbyVision)
        XCTAssertEqual(hint(rangeType: "HDR10Plus"), .hdr10Plus)
        XCTAssertEqual(hint(rangeType: "HDR10"), .hdr10)
        XCTAssertEqual(hint(rangeType: "HLG"), .hlg)
        XCTAssertEqual(hint(rangeType: "SDR"), .sdr)
        XCTAssertEqual(hint(rangeType: nil, transfer: "smpte2084"), .hdr10)
        XCTAssertEqual(hint(rangeType: nil, transfer: "arib-std-b67"), .hlg)
    }

    func testEngineProbeOverridesProviderHint() {
        let hintedHDR = EffectiveDynamicRange.awaitingEngineProbe(
            metadata: metadata(rangeType: "HDR10")
        )
        let correctedSDR = hintedHDR.applyingEngineProbe(
            EngineProbedSourceFacts(range: .sdr)
        )
        XCTAssertEqual(correctedSDR, .resolved(.sdr, authority: .engineProbe))

        let hintedSDR = EffectiveDynamicRange.awaitingEngineProbe(
            metadata: metadata(rangeType: "SDR")
        )
        let correctedDolbyVision = hintedSDR.applyingEngineProbe(
            EngineProbedSourceFacts(range: .dolbyVision)
        )
        XCTAssertEqual(
            correctedDolbyVision,
            .resolved(.dolbyVision, authority: .engineProbe)
        )
    }

    func testProbeWithoutRangeDoesNotEraseHint() {
        let initial = EffectiveDynamicRange.awaitingEngineProbe(
            metadata: metadata(rangeType: "HLG")
        )

        XCTAssertEqual(
            initial.applyingEngineProbe(EngineProbedSourceFacts(videoWidth: 3840)),
            initial
        )
    }

    func testNativeFallbackPreservesExistingSDRBehavior() {
        XCTAssertEqual(
            EffectiveDynamicRange.native(metadata: nil),
            .resolved(.sdr, authority: .nativeFallback)
        )
        XCTAssertEqual(
            EffectiveDynamicRange.native(metadata: metadata(rangeType: "DOVI")),
            .resolved(.dolbyVision, authority: .providerMetadata)
        )
    }

    private func hint(
        rangeType: String?,
        transfer: String? = nil
    ) -> SourceDynamicRange? {
        SourceDynamicRange.providerHint(
            from: metadata(rangeType: rangeType, transfer: transfer)
        )
    }

    private func metadata(
        rangeType: String?,
        transfer: String? = nil
    ) -> MediaSourceMetadata {
        MediaSourceMetadata(
            video: .init(
                videoRangeType: rangeType,
                colorTransfer: transfer
            )
        )
    }
}
