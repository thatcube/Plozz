import XCTest
import CoreModels
import CoreUI

final class OnlineTrailerTests: XCTestCase {

    // MARK: - MediaItem online-trailer marker

    func testYouTubeTrailerCarriesVideoIDMarker() {
        let trailer = MediaItem.youTubeTrailer(videoID: "abc123", title: "Dune — Trailer", parentTitle: "Dune")

        XCTAssertTrue(trailer.isYouTubeTrailer)
        XCTAssertEqual(trailer.youTubeTrailerVideoID, "abc123")
        XCTAssertEqual(trailer.id, "abc123")
        XCTAssertEqual(trailer.kind, .video)
        XCTAssertEqual(trailer.providerIDs[MediaItem.youTubeTrailerProviderKey], "abc123")
    }

    func testOrdinaryItemIsNotYouTubeTrailer() {
        let movie = MediaItem(id: "m1", title: "Dune", kind: .movie)
        XCTAssertFalse(movie.isYouTubeTrailer)
        XCTAssertNil(movie.youTubeTrailerVideoID)
    }

    // MARK: - TMDb trailer ranking

    private func video(_ key: String?, site: String = "YouTube", type: String = "Trailer", official: Bool = true, size: Int = 1080) -> TMDbArtworkResolver.Video {
        TMDbArtworkResolver.Video(key: key, site: site, type: type, official: official, size: size)
    }

    func testRankingKeepsOnlyYouTubeTrailersAndTeasers() {
        let videos = [
            video("vimeo", site: "Vimeo"),
            video("clip", type: "Clip"),
            video("featurette", type: "Featurette"),
            video("trailer"),
            video("teaser", type: "Teaser"),
            video(nil)
        ]
        XCTAssertEqual(TMDbArtworkResolver.rankedYouTubeTrailerKeys(videos), ["trailer", "teaser"])
    }

    func testRankingPrefersOfficialTrailerOverTeaser() {
        let videos = [
            video("teaser-official", type: "Teaser", official: true, size: 2160),
            video("trailer-unofficial", type: "Trailer", official: false, size: 720),
            video("trailer-official", type: "Trailer", official: true, size: 1080)
        ]
        // Trailers rank above teasers; official above unofficial.
        XCTAssertEqual(
            TMDbArtworkResolver.rankedYouTubeTrailerKeys(videos),
            ["trailer-official", "trailer-unofficial", "teaser-official"]
        )
    }

    func testRankingBreaksTiesByLargerSize() {
        let videos = [
            video("small", size: 480),
            video("large", size: 2160),
            video("medium", size: 1080)
        ]
        XCTAssertEqual(TMDbArtworkResolver.rankedYouTubeTrailerKeys(videos), ["large", "medium", "small"])
    }

    func testRankingEmptyForNoVideos() {
        XCTAssertTrue(TMDbArtworkResolver.rankedYouTubeTrailerKeys([]).isEmpty)
    }
}
