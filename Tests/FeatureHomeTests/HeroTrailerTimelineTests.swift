import XCTest
@testable import FeatureHome
import CoreModels

final class HeroTrailerTimelineTests: XCTestCase {
    func testTrailerTimelineIncludesStillLeadInAndFullTrailer() {
        XCTAssertEqual(
            HeroTrailerTimeline.duration(
                autoAdvanceSeconds: 12,
                mode: .trailer,
                trailerDuration: 57.1
            ),
            60.1,
            accuracy: 0.001
        )
    }

    func testNoTrailerFallsBackToConfiguredDwell() {
        XCTAssertEqual(
            HeroTrailerTimeline.duration(
                autoAdvanceSeconds: 12,
                mode: .trailer,
                trailerDuration: 0
            ),
            12
        )
    }

    func testOffAndThemeMusicNeverAdoptTrailerDuration() {
        for mode in [HeroBackgroundMode.off, .themeMusic] {
            XCTAssertEqual(
                HeroTrailerTimeline.duration(
                    autoAdvanceSeconds: 20,
                    mode: mode,
                    trailerDuration: 90
                ),
                20
            )
        }
    }
}
