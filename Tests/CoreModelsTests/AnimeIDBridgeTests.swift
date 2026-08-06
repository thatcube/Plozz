import CoreModels
import XCTest

/// Anime trackers and media servers never share an identifier: AniList and
/// MyAnimeList have their own numbering, while Plex and Jellyfin describe the
/// same show as AniDB/TMDb/TVDb/IMDb. Without a bridge the alias ledger has
/// nothing to match on and correctly declines to merge, so one show becomes two
/// entries — the copy you own, and one to go and request.
final class AnimeIDBridgeTests: XCTestCase {
    /// The real shape of the problem, taken from a device: a server row and a
    /// tracker row for Chainsaw Man with not one namespace in common.
    private let chainsawMan = AnimeIDMapping(
        aniDB: "15914",
        aniList: "127230",
        myAnimeList: "44511",
        tmdb: "114410",
        tvdb: "397934",
        imdb: "tt13616990"
    )

    func testBridgesTrackerIDsToServerIDs() {
        let bridge = AnimeIDBridge(mappings: [chainsawMan])

        // What the AniList/MAL watchlist row knows.
        let bridged = bridge.bridgedIdentities(for: [
            (namespace: .aniList, value: "127230"),
            (namespace: .myAnimeList, value: "44511")
        ])

        let namespaces = Set(bridged.map(\.namespace))
        XCTAssertTrue(namespaces.contains(.aniDB))
        XCTAssertTrue(namespaces.contains(.tmdb))
        XCTAssertTrue(namespaces.contains(.tvdb))
        XCTAssertTrue(namespaces.contains(.imdb))
        // And doesn't hand back what the caller already had.
        XCTAssertFalse(namespaces.contains(.aniList))
    }

    func testBridgesServerIDsToTrackerIDs() {
        let bridge = AnimeIDBridge(mappings: [chainsawMan])

        let bridged = bridge.bridgedIdentities(for: [
            (namespace: .aniDB, value: "15914")
        ])

        let namespaces = Set(bridged.map(\.namespace))
        XCTAssertTrue(namespaces.contains(.aniList))
        XCTAssertTrue(namespaces.contains(.myAnimeList))
    }

    /// The whole point: two evidence sets that shared nothing now share ids, so
    /// the resolver can merge them without ever falling back to title matching.
    func testEvidenceFromBothSidesEndsUpSharingIdentity() throws {
        let bridge = AnimeIDBridge(mappings: [chainsawMan])

        let trackerEvidence = try XCTUnwrap(MediaAliasEvidence(
            kind: .series,
            strong: [
                MediaAliasStrongEvidence(kind: .series, namespace: .aniList, value: "127230")!,
                MediaAliasStrongEvidence(kind: .series, namespace: .myAnimeList, value: "44511")!
            ]
        ))
        let serverEvidence = try XCTUnwrap(MediaAliasEvidence(
            kind: .series,
            strong: [
                MediaAliasStrongEvidence(kind: .series, namespace: .aniDB, value: "15914")!,
                MediaAliasStrongEvidence(kind: .series, namespace: .tmdb, value: "114410")!
            ]
        ))

        // Before: not one namespace in common — nothing to merge on.
        XCTAssertTrue(
            Set(trackerEvidence.strong.map(\.namespace))
                .isDisjoint(with: Set(serverEvidence.strong.map(\.namespace)))
        )

        let bridgedTracker = trackerEvidence.bridgingAnimeIdentities(using: bridge)
        let bridgedServer = serverEvidence.bridgingAnimeIdentities(using: bridge)

        let shared = Set(bridgedTracker.strong).intersection(Set(bridgedServer.strong))
        XCTAssertFalse(
            shared.isEmpty,
            "Both sides must end up carrying at least one identical strong id"
        )
    }

    /// An unknown show is left exactly as it was — the bridge never invents an
    /// identity, because a wrong merge routes playback to a different work.
    func testUnknownIdentitiesAreUntouched() throws {
        let bridge = AnimeIDBridge(mappings: [chainsawMan])
        let evidence = try XCTUnwrap(MediaAliasEvidence(
            kind: .series,
            strong: [
                MediaAliasStrongEvidence(kind: .series, namespace: .aniList, value: "999999")!
            ]
        ))

        XCTAssertEqual(
            evidence.bridgingAnimeIdentities(using: bridge).strong,
            evidence.strong
        )
    }

    func testEmptyBridgeChangesNothing() throws {
        let evidence = try XCTUnwrap(MediaAliasEvidence(
            kind: .series,
            strong: [
                MediaAliasStrongEvidence(kind: .series, namespace: .aniList, value: "127230")!
            ]
        ))

        XCTAssertEqual(
            evidence.bridgingAnimeIdentities(using: .empty).strong,
            evidence.strong
        )
    }

    /// A series-scoped namespace names the same catalogue as its plain form, so
    /// an episode row carrying `SeriesAniList` resolves like the show it is from.
    func testSeriesScopedNamespacesShareTheirCatalogue() {
        let bridge = AnimeIDBridge(mappings: [chainsawMan])

        let bridged = bridge.bridgedIdentities(for: [
            (namespace: .seriesAniList, value: "127230")
        ])

        XCTAssertTrue(Set(bridged.map(\.namespace)).contains(.aniDB))
    }
}
