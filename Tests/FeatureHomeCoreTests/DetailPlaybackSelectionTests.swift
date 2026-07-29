import XCTest
import CoreModels
@testable import FeatureHomeCore

/// An episode's preference key is its SERIES', so a per-file id stored there can
/// only ever match the one episode it was saved from.
final class DetailPlaybackSelectionTests: XCTestCase {
    func testAnEpisodeIgnoresAStoredFileIDAndUsesTheRememberedKind() {
        // The bug this guards: picking a version on episode 3 stored that file's
        // id under the series key, so replaying episode 3 returned it while every
        // other episode matched the remembered shape — one show behaving two ways.
        var hevc = MediaVersion(id: "ep3-hevc", height: 1080)
        hevc.videoCodec = "hevc"
        var av1 = MediaVersion(id: "ep3-av1", height: 1080)
        av1.videoCodec = "av1"

        let store = VersionPreferenceStore(
            defaults: UserDefaults(suiteName: "plozz.tests.episode-id-\(UUID().uuidString)")!
        )
        // A stale explicit pick, plus the shape the viewer actually wants.
        store.setPreferredVersionID("ep3-hevc", forTitle: "series-1")
        store.setPreferredVersionDescriptor(
            MediaVersionDescriptor(version: av1),
            forTitle: "series-1"
        )

        var episode = MediaItem(id: "ep3", title: "Episode 3", kind: .episode)
        episode.seriesID = "series-1"

        XCTAssertEqual(
            DetailPlaybackSelection.preferredVersionID(
                for: episode,
                versions: [hevc, av1],
                versionOverride: nil,
                preferences: store,
                capabilities: .detected()
            ),
            "ep3-av1"
        )
    }

    func testAMovieStillHonoursItsExactFile() {
        // The id remains right where the key IS the item's own: same title, same
        // files, and the viewer picked that one.
        var small = MediaVersion(id: "movie-1080", height: 1080)
        small.videoCodec = "h264"
        var large = MediaVersion(id: "movie-2160", height: 2160)
        large.videoCodec = "hevc"

        let store = VersionPreferenceStore(
            defaults: UserDefaults(suiteName: "plozz.tests.movie-id-\(UUID().uuidString)")!
        )
        store.setPreferredVersionID("movie-1080", forTitle: "movie-1")

        let movie = MediaItem(id: "movie-1", title: "A Film", kind: .movie)

        XCTAssertEqual(
            DetailPlaybackSelection.preferredVersionID(
                for: movie,
                versions: [small, large],
                versionOverride: nil,
                preferences: store,
                capabilities: .detected()
            ),
            "movie-1080"
        )
    }
}
