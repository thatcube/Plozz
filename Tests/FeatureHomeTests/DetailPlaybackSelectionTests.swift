import XCTest
import CoreModels
@testable import FeatureHomeCore

final class DetailPlaybackSelectionTests: XCTestCase {
    private struct Preferences: VersionPreferenceStoring {
        let id: String?
        let descriptor: MediaVersionDescriptor?

        func preferredVersionID(forTitle titleID: String) -> String? { id }
        func setPreferredVersionID(_ versionID: String?, forTitle titleID: String) {}
        func preferredVersionDescriptor(forTitle titleID: String) -> MediaVersionDescriptor? {
            descriptor
        }
        func setPreferredVersionDescriptor(
            _ descriptor: MediaVersionDescriptor?,
            forTitle titleID: String
        ) {}
    }

    func testDescriptorCarriesAcrossEpisodeFileIDs() {
        let episode = MediaItem(
            id: "episode-4",
            title: "Episode 4",
            kind: .episode,
            seriesID: "series-1"
        )
        let versions = [
            MediaVersion(id: "episode-4-hd", height: 1080, videoRange: "SDR"),
            MediaVersion(id: "episode-4-uhd", height: 2160, videoRange: "DOVI")
        ]
        let preferences = Preferences(
            id: "episode-3-uhd",
            descriptor: MediaVersionDescriptor(
                height: 2160,
                videoRange: "DOVI"
            )
        )

        XCTAssertEqual(
            DetailPlaybackSelection.preferredVersionID(
                for: episode,
                versions: versions,
                versionOverride: nil,
                preferences: preferences,
                capabilities: .detected()
            ),
            "episode-4-uhd"
        )
    }

    func testExactFileIDStillWinsBeforeDescriptor() {
        let movie = MediaItem(id: "movie", title: "Movie", kind: .movie)
        let versions = [
            MediaVersion(id: "remembered", height: 1080, videoRange: "SDR"),
            MediaVersion(id: "descriptor-match", height: 2160, videoRange: "DOVI")
        ]
        let preferences = Preferences(
            id: "remembered",
            descriptor: MediaVersionDescriptor(
                height: 2160,
                videoRange: "DOVI"
            )
        )

        XCTAssertEqual(
            DetailPlaybackSelection.preferredVersionID(
                for: movie,
                versions: versions,
                versionOverride: nil,
                preferences: preferences,
                capabilities: .detected()
            ),
            "remembered"
        )
    }
}
