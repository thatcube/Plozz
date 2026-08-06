import XCTest
import CoreModels
import FeatureHomeCore

/// A season reaching the player directly is a real, shipped bug: Plex and
/// Jellyfin both return SEASONS in a show's Recently Added, so one lands in the
/// hero, and a Play tap handed the season's ratingKey straight to the player.
/// The container holds no media, so Plex answered `notFound` and the viewer got
/// "We couldn't find what you were looking for" — while the same title played
/// fine from its detail page, because that path walks down to an episode.
final class HeroSeasonPlayTargetTests: XCTestCase {

    func testSeasonResolvesToNextUpEpisodeRatherThanPlayingItself() async {
        let episodes = [
            episode("e1", season: 1, number: 1, played: true),
            episode("e2", season: 1, number: 2, played: false),
        ]
        let provider = FakeMediaProvider(allItems: episodes)
        provider.childrenByParent = ["season-1": episodes]

        let target = await HeroPlayTargetResolver.playbackTarget(
            for: season("season-1", number: 1),
            provider: provider
        )

        XCTAssertEqual(target?.id, "e2", "a season must resolve to its next-up episode")
        XCTAssertEqual(target?.kind, .episode)
    }

    /// The season's own account must survive resolution, or best-source routing
    /// sends playback at the wrong server.
    func testResolvedEpisodeInheritsTheSeasonsAccount() async {
        let episodes = [episode("e1", season: 2, number: 1, played: false)]
        let provider = FakeMediaProvider(allItems: episodes)
        provider.childrenByParent = ["season-2": episodes]

        var input = season("season-2", number: 2)
        input.sourceAccountID = "account-A"

        let target = await HeroPlayTargetResolver.playbackTarget(
            for: input,
            provider: provider
        )

        XCTAssertEqual(target?.sourceAccountID, "account-A")
    }

    /// A season whose episodes can't be fetched must yield nil so the caller
    /// opens the detail page, rather than falling through to the player.
    func testSeasonWithNoEpisodesResolvesToNil() async {
        let provider = FakeMediaProvider(allItems: [])
        provider.childrenByParent = ["season-3": []]

        let target = await HeroPlayTargetResolver.playbackTarget(
            for: season("season-3", number: 3),
            provider: provider
        )

        XCTAssertNil(target)
    }

    func testContainerKindsAreFlaggedForResolution() {
        XCTAssertTrue(MediaItemKind.series.needsPlaybackTargetResolution)
        XCTAssertTrue(MediaItemKind.season.needsPlaybackTargetResolution)
        // Directly playable kinds must keep going straight to the player.
        XCTAssertFalse(MediaItemKind.movie.needsPlaybackTargetResolution)
        XCTAssertFalse(MediaItemKind.episode.needsPlaybackTargetResolution)
        XCTAssertFalse(MediaItemKind.video.needsPlaybackTargetResolution)
        // Deliberately unchanged pass-through kinds.
        XCTAssertFalse(MediaItemKind.folder.needsPlaybackTargetResolution)
        XCTAssertFalse(MediaItemKind.collection.needsPlaybackTargetResolution)
        XCTAssertFalse(MediaItemKind.unknown.needsPlaybackTargetResolution)
    }

    private func season(_ id: String, number: Int) -> MediaItem {
        var item = MediaItem(id: id, title: "Season \(number)", kind: .season)
        item.seasonNumber = number
        return item
    }

    private func episode(
        _ id: String,
        season: Int,
        number: Int,
        played: Bool
    ) -> MediaItem {
        var item = MediaItem(id: id, title: "Episode \(number)", kind: .episode)
        item.seasonNumber = season
        item.episodeNumber = number
        item.isPlayed = played
        return item
    }
}
