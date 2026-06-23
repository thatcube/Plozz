import XCTest
import CoreModels

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

    // MARK: - YouTube URL parsing (server RemoteTrailers / Plex remote extras)

    func testParsesWatchURL() {
        XCTAssertEqual(
            MediaItem.youTubeVideoID(fromURL: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"),
            "dQw4w9WgXcQ"
        )
    }

    func testParsesWatchURLWithExtraParams() {
        XCTAssertEqual(
            MediaItem.youTubeVideoID(fromURL: "https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=ABC&t=42s"),
            "dQw4w9WgXcQ"
        )
    }

    func testParsesShortYoutuBeURL() {
        XCTAssertEqual(
            MediaItem.youTubeVideoID(fromURL: "https://youtu.be/dQw4w9WgXcQ?t=10"),
            "dQw4w9WgXcQ"
        )
    }

    func testParsesEmbedShortsAndVPaths() {
        XCTAssertEqual(MediaItem.youTubeVideoID(fromURL: "https://www.youtube.com/embed/dQw4w9WgXcQ"), "dQw4w9WgXcQ")
        XCTAssertEqual(MediaItem.youTubeVideoID(fromURL: "https://www.youtube.com/shorts/dQw4w9WgXcQ"), "dQw4w9WgXcQ")
        XCTAssertEqual(MediaItem.youTubeVideoID(fromURL: "https://www.youtube.com/v/dQw4w9WgXcQ"), "dQw4w9WgXcQ")
    }

    func testParsesNoCookieHost() {
        XCTAssertEqual(
            MediaItem.youTubeVideoID(fromURL: "https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ"),
            "dQw4w9WgXcQ"
        )
    }

    func testParsesBareID() {
        XCTAssertEqual(MediaItem.youTubeVideoID(fromURL: "dQw4w9WgXcQ"), "dQw4w9WgXcQ")
    }

    func testRejectsNonYouTubeAndMalformed() {
        XCTAssertNil(MediaItem.youTubeVideoID(fromURL: "https://vimeo.com/123456"))
        XCTAssertNil(MediaItem.youTubeVideoID(fromURL: "https://www.youtube.com/watch?v=tooLong12345"))
        XCTAssertNil(MediaItem.youTubeVideoID(fromURL: ""))
        XCTAssertNil(MediaItem.youTubeVideoID(fromURL: "not a url"))
    }

    func testYouTubeTrailerFromURLBuildsMarkedItem() {
        let trailer = MediaItem.youTubeTrailer(
            fromURL: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            title: "Dune — Trailer",
            parentTitle: "Dune"
        )
        XCTAssertEqual(trailer?.youTubeTrailerVideoID, "dQw4w9WgXcQ")
        XCTAssertEqual(trailer?.parentTitle, "Dune")
    }

    func testYouTubeTrailerFromURLNilForUnsupported() {
        XCTAssertNil(MediaItem.youTubeTrailer(fromURL: "https://vimeo.com/123456", title: "x"))
    }
}
