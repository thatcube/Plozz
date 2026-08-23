import XCTest
import CoreModels
@testable import ProviderJellyfin

/// Jellyfin computes a leaf's `PlayedPercentage` as position ÷ runtime, so a
/// response carrying both has already told us the runtime even when it omits
/// `RunTimeTicks`. Without recovering it the card draws a progress bar it cannot
/// label — "S1, E2" beside a bar showing real progress and no duration.
final class JellyfinRuntimeInferenceTests: XCTestCase {

    /// The case this exists for: 25% through a 20-minute episode.
    func testRuntimeIsRecoveredFromPositionAndPercentage() {
        let inferred = JellyfinProvider.runtimeInferredFromProgress(
            position: 300, fraction: 0.25
        )
        XCTAssertEqual(try XCTUnwrap(inferred), 1200, accuracy: 1)
    }

    /// A series' percentage counts watched episodes and carries no position, so
    /// nothing is inferred — a series genuinely has no runtime and must not be
    /// given a fabricated one.
    func testAContainerWithNoPositionInfersNothing() {
        XCTAssertNil(
            JellyfinProvider.runtimeInferredFromProgress(position: nil, fraction: 0.5)
        )
    }

    /// Dividing by a near-zero fraction magnifies whatever the server rounded, so
    /// the very start of an episode is not a safe basis.
    func testATinyFractionIsRefused() {
        XCTAssertNil(
            JellyfinProvider.runtimeInferredFromProgress(position: 5, fraction: 0.001)
        )
    }

    /// A result outside any plausible runtime is dropped: an absent duration reads
    /// as incomplete, a wrong one reads as broken.
    func testAnImplausibleResultIsRefused() {
        XCTAssertNil(
            JellyfinProvider.runtimeInferredFromProgress(position: 86_000, fraction: 0.02)
        )
    }

    /// Nothing to divide by.
    func testNoProgressInfersNothing() {
        XCTAssertNil(
            JellyfinProvider.runtimeInferredFromProgress(position: 300, fraction: nil)
        )
    }
}
