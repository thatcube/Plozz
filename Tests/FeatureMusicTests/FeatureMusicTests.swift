import XCTest
import CoreModels
@testable import FeatureMusic

final class MusicFormatTests: XCTestCase {
    func testDurationUnderAnHour() {
        XCTAssertEqual(MusicFormat.duration(187), "3:07")
        XCTAssertEqual(MusicFormat.duration(0), "0:00")
        XCTAssertEqual(MusicFormat.duration(59), "0:59")
    }

    func testDurationOverAnHour() {
        XCTAssertEqual(MusicFormat.duration(3753), "1:02:33")
    }

    func testDurationHandlesNilAndInvalid() {
        XCTAssertEqual(MusicFormat.duration(nil), "--:--")
        XCTAssertEqual(MusicFormat.duration(-5), "--:--")
        XCTAssertEqual(MusicFormat.duration(.infinity), "--:--")
    }
}

final class MusicPagePagingTests: XCTestCase {
    func testCountAndHasMore() {
        let page = MusicPage(
            albums: [MusicAlbum(id: "a", title: "A"), MusicAlbum(id: "b", title: "B")],
            startIndex: 0,
            totalCount: 10
        )
        XCTAssertEqual(page.count, 2)
        XCTAssertEqual(page.endIndex, 2)
        XCTAssertTrue(page.hasMore)
    }

    func testNoMoreWhenExhausted() {
        let page = MusicPage(
            tracks: [MusicTrack(id: "t", title: "T")],
            startIndex: 9,
            totalCount: 10
        )
        XCTAssertFalse(page.hasMore)
    }
}

final class MusicTrackSubtitleTests: XCTestCase {
    func testSubtitleCombinesArtistAndAlbum() {
        let track = MusicTrack(id: "t", title: "Song", albumTitle: "LP", artistName: "Artist")
        XCTAssertEqual(track.subtitle, "Artist · LP")
    }

    func testSubtitleFallsBackToWhateverIsPresent() {
        XCTAssertEqual(MusicTrack(id: "t", title: "S", artistName: "Only Artist").subtitle, "Only Artist")
        XCTAssertNil(MusicTrack(id: "t", title: "S").subtitle)
    }
}
