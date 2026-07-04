import XCTest
import CoreModels

/// The pure hero CTA decision that drives Play vs. Request vs. download status vs.
/// no-button for featured (Seerr) titles, and Play/Resume for ordinary library
/// items. Kept exhaustive so the UI's button choice can never drift.
final class HeroCTATests: XCTestCase {
    private func item(_ availability: MediaAvailabilityStatus?, download: Double? = nil) -> MediaItem {
        MediaItem(id: "x", title: "T", kind: .movie, availability: availability, downloadProgress: download)
    }

    func testOrdinaryLibraryItemIsAlwaysPlay() {
        XCTAssertEqual(item(nil).heroCTA(seerConnected: false), .play)
        XCTAssertEqual(item(nil).heroCTA(seerConnected: true), .play)
    }

    func testOwnedFeaturedIsPlayRegardlessOfConnection() {
        XCTAssertEqual(item(.available).heroCTA(seerConnected: false), .play)
        XCTAssertEqual(item(.available).heroCTA(seerConnected: true), .play)
        XCTAssertEqual(item(.partiallyAvailable).heroCTA(seerConnected: true), .play)
    }

    func testRequestableOnlyWhenConnected() {
        XCTAssertEqual(item(.unknown).heroCTA(seerConnected: true), .request)
        XCTAssertEqual(item(.deleted).heroCTA(seerConnected: true), .request)
        // Not connected → no Play/Request button (still shown in the carousel).
        XCTAssertEqual(item(.unknown).heroCTA(seerConnected: false), .unavailable)
        XCTAssertEqual(item(.deleted).heroCTA(seerConnected: false), .unavailable)
    }

    func testPendingShowsRequestedOnlyWhenConnected() {
        XCTAssertEqual(item(.pending).heroCTA(seerConnected: true), .requested)
        XCTAssertEqual(item(.pending).heroCTA(seerConnected: false), .unavailable)
    }

    func testProcessingShowsDownloadingWithProgress() {
        XCTAssertEqual(item(.processing, download: 0.42).heroCTA(seerConnected: true), .downloading(progress: 0.42))
        XCTAssertEqual(item(.processing, download: nil).heroCTA(seerConnected: true), .downloading(progress: nil))
        XCTAssertEqual(item(.processing, download: 0.42).heroCTA(seerConnected: false), .unavailable)
    }
}
