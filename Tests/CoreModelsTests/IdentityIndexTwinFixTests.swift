import XCTest
@testable import CoreModels

/// Regression coverage for the cross-server episode↔movie twin bug: a TV episode's
/// `sources` array was contaminated with an unrelated movie ref frozen in a
/// pre-kind-scoping on-disk cache, so playback/mark-watched retargeted onto the
/// movie. The fix stamps `MediaSourceRef.kind` and enforces a cross-kind boundary
/// (via ``MediaSourceRef/retainingKindCompatible(_:itemKind:selfIDs:)``) in the
/// merger and at every routing boundary, plus guards `IdentityIndex.restore`.
final class IdentityIndexTwinFixTests: XCTestCase {

    private func item(
        _ id: String,
        title: String,
        kind: MediaItemKind,
        account: String,
        ids: [String: String] = [:],
        season: Int? = nil,
        episode: Int? = nil,
        sources: [MediaSourceRef] = []
    ) -> MediaItem {
        var m = MediaItem(
            id: id,
            title: title,
            kind: kind,
            seasonNumber: season,
            episodeNumber: episode,
            providerIDs: ids,
            sourceAccountID: account
        )
        m.sources = sources
        return m
    }

    // MARK: retainingKindCompatible primitive

    func testRetainDropsTypedCrossKindPeer() {
        let selfRef = MediaSourceRef(accountID: "A", itemID: "11564", kind: .episode)
        let moviePeer = MediaSourceRef(accountID: "B", itemID: "4171", kind: .movie)
        let kept = MediaSourceRef.retainingKindCompatible(
            [selfRef, moviePeer], itemKind: .episode, selfIDs: ["A:11564"]
        )
        XCTAssertEqual(kept.map(\.id), ["A:11564"], "A movie ref must not survive on an episode")
    }

    func testRetainDropsUntypedPeerButKeepsUntypedSelf() {
        // Legacy refs decoded from a pre-`kind` cache carry nil kind. Only the item's
        // own self-ref is trusted; an untyped *peer* is the stale twin and is dropped.
        let untypedSelf = MediaSourceRef(accountID: "A", itemID: "11564")
        let untypedPeer = MediaSourceRef(accountID: "B", itemID: "4171")
        let kept = MediaSourceRef.retainingKindCompatible(
            [untypedSelf, untypedPeer], itemKind: .episode, selfIDs: ["A:11564"]
        )
        XCTAssertEqual(kept.map(\.id), ["A:11564"])
    }

    func testRetainKeepsTypedSameKindPeer() {
        // A legitimate same-episode twin on another server must pass untouched.
        let selfRef = MediaSourceRef(accountID: "A", itemID: "11564", kind: .episode)
        let twin = MediaSourceRef(accountID: "B", itemID: "9001", kind: .episode)
        let kept = MediaSourceRef.retainingKindCompatible(
            [selfRef, twin], itemKind: .episode, selfIDs: ["A:11564"]
        )
        XCTAssertEqual(Set(kept.map(\.id)), ["A:11564", "B:9001"])
    }

    // MARK: Merger sanitation

    func testMergeDropsFrozenMovieRefFromEpisodeSources() {
        // The exact bug: a single episode row arrives (e.g. rehydrated from a stale
        // Home cache) already carrying an unrelated movie ref in `.sources`. The
        // merge must strip it so play/nav never retargets onto the movie.
        let poisoned = item(
            "11564", title: "The Day of Black Sun", kind: .episode, account: "A",
            season: 3, episode: 10,
            sources: [
                MediaSourceRef(accountID: "A", itemID: "11564", kind: .episode),
                MediaSourceRef(accountID: "B", itemID: "4171", kind: .movie) // Hell or High Water
            ]
        )
        let merged = MediaItemMerger.merge([poisoned])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].sources.map(\.id), ["A:11564"],
                       "The movie twin must be dropped from the episode's sources")
    }

    func testMergeDropsUntypedFrozenMovieRefFromEpisodeSources() {
        // Same, but the frozen refs are untyped (nil kind) as a pre-fix cache would
        // decode them. The untyped peer is still rejected; the self-ref survives.
        let poisoned = item(
            "11564", title: "The Day of Black Sun", kind: .episode, account: "A",
            season: 3, episode: 10,
            sources: [
                MediaSourceRef(accountID: "A", itemID: "11564"),
                MediaSourceRef(accountID: "B", itemID: "4171")
            ]
        )
        let merged = MediaItemMerger.merge([poisoned])
        XCTAssertEqual(merged[0].sources.map(\.id), ["A:11564"])
    }

    func testMergeDropsEpisodeRefFromMovieSources() {
        // The reverse contamination: a movie carrying a stale episode ref.
        let poisoned = item(
            "4171", title: "Hell or High Water", kind: .movie, account: "B",
            sources: [
                MediaSourceRef(accountID: "B", itemID: "4171", kind: .movie),
                MediaSourceRef(accountID: "A", itemID: "11564", kind: .episode)
            ]
        )
        let merged = MediaItemMerger.merge([poisoned])
        XCTAssertEqual(merged[0].sources.map(\.id), ["B:4171"])
    }

    func testMergePreservesLegitimateCrossServerEpisodeTwins() {
        // Two servers' copies of the *same* episode (shared series id + exact S/E)
        // are a real duplicate: they must merge and BOTH sources must survive.
        let a = item("epA", title: "The Boiling Rock", kind: .episode, account: "A",
                     ids: ["Tvdb": "555"], season: 3, episode: 15)
        let b = item("epB", title: "The Boiling Rock", kind: .episode, account: "B",
                     ids: ["Tvdb": "555"], season: 3, episode: 15)
        let merged = MediaItemMerger.merge([a, b])
        XCTAssertEqual(merged.count, 1, "Same episode on two servers must merge")
        XCTAssertEqual(Set(merged[0].sources.map(\.id)), ["A:epA", "B:epB"],
                       "Both legitimate same-kind episode sources must survive")
    }

    func testMergedGroupDropsPoisonContributedByOneMember() {
        // A legit twin pair where ONE member also carries a frozen movie ref: the
        // twins still merge, but the cross-kind poison is stripped from the result.
        let a = item("epA", title: "The Boiling Rock", kind: .episode, account: "A",
                     ids: ["Tvdb": "555"], season: 3, episode: 15,
                     sources: [
                        MediaSourceRef(accountID: "A", itemID: "epA", kind: .episode),
                        MediaSourceRef(accountID: "X", itemID: "4171", kind: .movie)
                     ])
        let b = item("epB", title: "The Boiling Rock", kind: .episode, account: "B",
                     ids: ["Tvdb": "555"], season: 3, episode: 15,
                     sources: [MediaSourceRef(accountID: "B", itemID: "epB", kind: .episode)])
        let merged = MediaItemMerger.merge([a, b])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(Set(merged[0].sources.map(\.id)), ["A:epA", "B:epB"],
                       "Legit twins kept; the cross-kind movie ref dropped")
    }

    // MARK: IdentityIndex.restore kind guard

    func testRestoreRejectsNonMovieSeriesSources() async {
        // A corrupt / older-build persisted snapshot carrying an episode-kind source
        // must not be restored — restore upholds the same movie/series invariant as
        // ingest, so a kind-scoped lookup can never serve a stale episode membership.
        let movieSource = IndexedSource(accountID: "acct", itemID: "m1", kind: .movie)
        let episodeSource = IndexedSource(accountID: "acct", itemID: "e1", kind: .episode)
        let persisted = PersistedIdentityIndex(
            entriesByAccount: [
                "acct": [
                    PersistedIdentityIndex.Entry(
                        identity: .external(source: "tmdb", value: "42"), source: movieSource
                    ),
                    PersistedIdentityIndex.Entry(
                        identity: .external(source: "tvdb:s3e10", value: "99"), source: episodeSource
                    )
                ]
            ],
            builtAtByAccount: ["acct": Date()]
        )
        let index = IdentityIndex()
        await index.restore(from: persisted, retaining: ["acct"])
        let snapshot = await index.snapshot()
        let allSourceIDs = Set(
            snapshot.sources(forIdentities: [
                .external(source: "tmdb", value: "42"),
                .external(source: "tvdb:s3e10", value: "99")
            ]).map(\.id)
        )
        XCTAssertTrue(allSourceIDs.contains("acct:m1"), "The movie source restores")
        XCTAssertFalse(allSourceIDs.contains("acct:e1"), "The episode-kind source must be rejected")
    }
}
