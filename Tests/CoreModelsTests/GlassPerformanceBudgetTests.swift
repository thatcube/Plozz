import XCTest
@testable import CoreModels

/// Coverage for when Liquid Glass is given up on performance grounds.
///
/// Worth pinning because every interesting case is awkward to reproduce by
/// hand — it needs particular hardware, or a particular file, or both — and the
/// failure mode is silent: glass that never returns, or never goes, looks like
/// a rendering quirk rather than a rule being wrong.
final class GlassPerformanceBudgetTests: XCTestCase {
    func testAppleTVHDIsBelowTheHardwareFloor() {
        let budget = GlassPerformanceBudget.forHardware(physicalMemoryBytes: 2 * 1024 * 1024 * 1024)
        XCTAssertFalse(budget.hardwareAllowsGlass)
        XCTAssertTrue(budget.reducesTransparency)
    }

    func testAppleTV4KMeetsTheHardwareFloor() {
        let budget = GlassPerformanceBudget.forHardware(physicalMemoryBytes: 3 * 1024 * 1024 * 1024)
        XCTAssertTrue(budget.hardwareAllowsGlass)
        XCTAssertFalse(budget.reducesTransparency)
    }

    /// A failed memory query must not read as a device with no memory, which
    /// would strip the interface everywhere the reading is unavailable.
    func testUnknownMemoryFailsOpen() {
        XCTAssertTrue(GlassPerformanceBudget.forHardware(physicalMemoryBytes: 0).hardwareAllowsGlass)
    }

    func testDolbyVisionIsDemandingAtAnySize() {
        XCTAssertTrue(
            GlassPerformanceBudget.contentIsDemanding(
                hdrFormat: .dolbyVision, width: 1920, bitrate: 8_000_000
            )
        )
    }

    func testFourKHDRIsDemanding() {
        XCTAssertTrue(
            GlassPerformanceBudget.contentIsDemanding(
                hdrFormat: .hdr10, width: 3840, bitrate: nil
            )
        )
    }

    /// Resolution alone is not the signal — a 4K SDR stream is the common case
    /// and must keep its glass.
    func testFourKSDRIsNotDemanding() {
        XCTAssertFalse(
            GlassPerformanceBudget.contentIsDemanding(
                hdrFormat: .sdr, width: 3840, bitrate: 12_000_000
            )
        )
    }

    func testRemuxBitrateIsDemandingRegardlessOfFormat() {
        XCTAssertTrue(
            GlassPerformanceBudget.contentIsDemanding(
                hdrFormat: .sdr, width: 1920, bitrate: 80_000_000
            )
        )
    }

    /// A share with no metadata keeps its glass. Treating unknown as demanding
    /// would strip the interface for exactly the viewers whose libraries report
    /// the least about themselves.
    func testUnknownSourceIsNotDemanding() {
        XCTAssertFalse(
            GlassPerformanceBudget.contentIsDemanding(hdrFormat: nil, width: nil, bitrate: nil)
        )
        XCTAssertFalse(GlassPerformanceBudget.contentIsDemanding(source: nil))
    }

    func testProviderDolbyVisionTokenIsRead() {
        var video = MediaSourceMetadata.VideoStream()
        video.videoRangeType = "DOVI"
        video.width = 3840
        var source = MediaSourceMetadata()
        source.video = video
        XCTAssertTrue(GlassPerformanceBudget.contentIsDemanding(source: source))
    }

    /// The explicit profile number, for providers that report that instead of a
    /// range token.
    func testProviderDolbyVisionProfileIsRead() {
        var video = MediaSourceMetadata.VideoStream()
        video.dolbyVisionProfile = 5
        var source = MediaSourceMetadata()
        source.video = video
        XCTAssertTrue(GlassPerformanceBudget.contentIsDemanding(source: source))
    }

    /// The case that shipped broken: a network share has no video metadata at
    /// all, so the provider path classified a 4K Dolby Vision remux as SDR and
    /// left the glass up. The engine's probe is the only evidence there is.
    func testEngineProbeDrivesShareWithNoProviderMetadata() {
        let result = GlassPerformanceBudget.demand(
            for: nil,
            resolvedRange: .dolbyVision,
            probedWidth: 3840
        )
        XCTAssertTrue(result.isDemanding)
        XCTAssertTrue(result.isHDR)
    }

    /// The probe read the file; the provider's tokens are whatever a scanner
    /// once recorded. Where they disagree the probe wins.
    func testEngineProbeOverridesProviderMetadata() {
        var video = MediaSourceMetadata.VideoStream()
        video.videoRange = "SDR"
        video.width = 1920
        var source = MediaSourceMetadata()
        source.video = video
        let result = GlassPerformanceBudget.demand(
            for: source,
            resolvedRange: .dolbyVision,
            probedWidth: 3840
        )
        XCTAssertTrue(result.isDemanding)
    }

    /// A probe that resolved to SDR is a real answer, not a missing one.
    func testProbedSDRKeepsGlass() {
        let result = GlassPerformanceBudget.demand(
            for: nil,
            resolvedRange: .sdr,
            probedWidth: 3840
        )
        XCTAssertFalse(result.isDemanding)
        XCTAssertFalse(result.isHDR)
    }

    func testOrdinarySourceKeepsGlass() {
        var video = MediaSourceMetadata.VideoStream()
        video.videoRange = "SDR"
        video.width = 1920
        video.bitrate = 6_000_000
        var source = MediaSourceMetadata()
        source.video = video
        XCTAssertFalse(GlassPerformanceBudget.contentIsDemanding(source: source))
    }

    /// The two signals are independent: capable hardware still gives glass up
    /// for demanding content, and gets it back afterwards.
    func testContentSuspensionIsIndependentOfHardware() {
        var budget = GlassPerformanceBudget(hardwareAllowsGlass: true)
        XCTAssertFalse(budget.reducesTransparency)
        budget.contentIsDemanding = true
        XCTAssertTrue(budget.reducesTransparency)
        budget.contentIsDemanding = false
        XCTAssertFalse(budget.reducesTransparency)
    }

    /// An explicit "On" is documented as always using glass, so performance must
    /// not quietly override it — someone who chose it and watched glass vanish
    /// mid-film cannot tell that from a bug.
    func testExplicitOnIgnoresPerformance() {
        let starved = GlassPerformanceBudget(hardwareAllowsGlass: false, contentIsDemanding: true)
        XCTAssertFalse(
            TransparencyPreference.on.reducesTransparency(
                systemReduceTransparency: false, performance: starved
            )
        )
    }

    func testSystemPreferenceHonoursPerformance() {
        let starved = GlassPerformanceBudget(hardwareAllowsGlass: false)
        XCTAssertTrue(
            TransparencyPreference.system.reducesTransparency(
                systemReduceTransparency: false, performance: starved
            )
        )
        XCTAssertFalse(
            TransparencyPreference.system.reducesTransparency(
                systemReduceTransparency: false, performance: GlassPerformanceBudget()
            )
        )
    }

    /// Off stays off whatever the hardware says.
    func testExplicitOffStaysReduced() {
        XCTAssertTrue(
            TransparencyPreference.off.reducesTransparency(
                systemReduceTransparency: false, performance: GlassPerformanceBudget()
            )
        )
    }
}
