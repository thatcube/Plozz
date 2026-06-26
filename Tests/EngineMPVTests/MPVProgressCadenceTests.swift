#if canImport(Libmpv) && canImport(UIKit)
import XCTest
@testable import EngineMPV

@MainActor
final class MPVProgressCadenceTests: XCTestCase {
    func testSuppressesProgressAfterEndOfFile() {
        var cadence = MPVProgressCadence(interval: 10)

        XCTAssertTrue(cadence.shouldReport(at: 10, hasReachedEnd: false))
        XCTAssertFalse(
            cadence.shouldReport(at: 0, hasReachedEnd: true),
            "mpv resets time-pos near zero after EOF; the engine must not emit that as resume progress"
        )
    }

    func testNewPlaybackCadenceStartsReportingAgain() {
        var cadence = MPVProgressCadence(interval: 10)
        XCTAssertFalse(cadence.shouldReport(at: 0, hasReachedEnd: true))

        cadence.reset()

        XCTAssertTrue(
            cadence.shouldReport(at: 10, hasReachedEnd: false),
            "A fresh playback resets both EOF state and the cadence guard"
        )
    }
}
#endif
