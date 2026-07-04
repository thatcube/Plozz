import XCTest
import CoreModels
@testable import SeerService

/// Download-progress aggregation from Seerr's `mediaInfo.downloadStatus` and its
/// propagation onto the mapped `MediaItem`, so the hero can draw a live bar for a
/// requested title that's still being fetched by Radarr/Sonarr.
final class SeerDownloadProgressTests: XCTestCase {
    func testNilWhenNoDownloadStatus() {
        XCTAssertNil(SeerMapper.downloadProgress(from: nil))
        XCTAssertNil(SeerMapper.downloadProgress(from: []))
    }

    func testNilWhenSizesUnknown() {
        // Queued but Radarr/Sonarr hasn't reported a size yet → plain "Downloading".
        XCTAssertNil(SeerMapper.downloadProgress(from: [SeerDownloadingItem(size: nil, sizeLeft: nil)]))
        XCTAssertNil(SeerMapper.downloadProgress(from: [SeerDownloadingItem(size: 0, sizeLeft: 0)]))
    }

    func testNilWhenGrabbedButNoBytesYet() {
        // A just-grabbed item reports sizeLeft ≈ size (≈0%): reads as "Requested",
        // not a stuck "Downloading 0%".
        XCTAssertNil(SeerMapper.downloadProgress(from: [SeerDownloadingItem(size: 100, sizeLeft: 100)]))
        XCTAssertNil(SeerMapper.downloadProgress(from: [SeerDownloadingItem(size: 1000, sizeLeft: 999)]))
    }

    func testSingleItemFraction() {
        let p = SeerMapper.downloadProgress(from: [SeerDownloadingItem(size: 100, sizeLeft: 25)])
        XCTAssertEqual(p ?? -1, 0.75, accuracy: 0.0001)
    }

    func testAggregatesAcrossItems() {
        // total 300 bytes, 150 left → 0.5 fetched.
        let p = SeerMapper.downloadProgress(from: [
            SeerDownloadingItem(size: 100, sizeLeft: 100),
            SeerDownloadingItem(size: 200, sizeLeft: 50)
        ])
        XCTAssertEqual(p ?? -1, 0.5, accuracy: 0.0001)
    }

    func testClampsBelowOne() {
        // A fully-fetched title reports as available, not downloading — never 1.
        let p = SeerMapper.downloadProgress(from: [SeerDownloadingItem(size: 100, sizeLeft: 0)])
        XCTAssertNotNil(p)
        XCTAssertLessThan(p ?? 1, 1.0)
    }

    func testMappedItemCarriesProgress() {
        let result = SeerDiscoverResult(
            id: 42,
            mediaType: "movie",
            title: "Downloading Movie",
            mediaInfo: SeerMediaInfo(status: 3, downloadStatus: [SeerDownloadingItem(size: 100, sizeLeft: 40)])
        )
        let item = SeerMapper.mediaItem(from: result)
        XCTAssertEqual(item?.availability, .processing)
        XCTAssertEqual(item?.downloadProgress ?? -1, 0.6, accuracy: 0.0001)
    }
}
