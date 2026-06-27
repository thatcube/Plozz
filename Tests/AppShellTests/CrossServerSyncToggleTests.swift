import XCTest
import CoreModels
@testable import AppShell

/// Locks the cross-server watch-sync toggle's behaviour at the single chokepoint
/// (`WatchMutationFactory`). The toggle's whole correctness rests on OFF stripping
/// **all four** fan-out sources — extra targets, episodeOrigin, identities, and the
/// `expansionPending` flag — so the reconciler does zero cross-server probing and
/// can't silently re-expand at drain time. ON must remain byte-for-byte today's
/// behaviour.
final class CrossServerSyncToggleTests: XCTestCase {
    private func movie(_ id: String, account: String, tmdb: String = "438631") -> MediaItem {
        MediaItem(
            id: id,
            title: "Dune",
            kind: .movie,
            productionYear: 2021,
            providerIDs: ["Tmdb": tmdb],
            sourceAccountID: account
        )
    }

    private func episode(_ id: String, account: String) -> MediaItem {
        MediaItem(
            id: id,
            title: "Pilot",
            kind: .episode,
            seasonNumber: 1,
            episodeNumber: 1,
            providerIDs: ["Imdb": "tt0959621"],
            sourceAccountID: account
        )
    }

    private let union = [
        MediaSourceRef(accountID: "origin", itemID: "o-item", providerKind: .jellyfin),
        MediaSourceRef(accountID: "plex", itemID: "px-item", providerKind: .plex),
        MediaSourceRef(accountID: "jf2", itemID: "jf2-item", providerKind: .jellyfin)
    ]

    // MARK: Default ON parity

    func testDefaultOnFansOutToFullUnion() {
        let item = movie("o-item", account: "origin")
        let targets = WatchMutationFactory.targets(
            for: item, primaryAccountID: "origin", additionalSources: union
        )
        XCTAssertEqual(Set(targets.map(\.id)), ["origin:o-item", "plex:px-item", "jf2:jf2-item"])

        // Explicit `crossServerSync: true` must equal the defaulted call.
        let explicit = WatchMutationFactory.targets(
            for: item, primaryAccountID: "origin", additionalSources: union, crossServerSync: true
        )
        XCTAssertEqual(targets, explicit, "Explicit ON must match the default")
    }

    func testDefaultOnMovieKeepsIdentityExpansion() {
        let m = WatchMutationFactory.playbackStop(
            item: movie("o-item", account: "origin"),
            position: 600, watchedPercent: 30, primaryAccountID: "origin", additionalSources: union
        )
        XCTAssertEqual(m?.expansionPending, true)
        XCTAssertEqual(m?.identities, [.external(source: "tmdb", value: "438631")])
    }

    // MARK: OFF — origin-only, no expansion

    func testOffScopesTargetsToOriginOnly() {
        let targets = WatchMutationFactory.targets(
            for: movie("o-item", account: "origin"),
            primaryAccountID: "origin", additionalSources: union, crossServerSync: false
        )
        XCTAssertEqual(targets.map(\.id), ["origin:o-item"],
                       "OFF must converge on the origin server only")
        XCTAssertEqual(targets.first?.providerKind, .jellyfin,
                       "Origin still carries its resolved providerKind even when scoped")
    }

    func testOffPlayedToggleSuppressesIdentityExpansion() {
        let m = WatchMutationFactory.playedToggle(
            item: movie("o-item", account: "origin"),
            played: true, primaryAccountID: "origin", additionalSources: union, crossServerSync: false
        )
        XCTAssertEqual(m?.targets.map(\.id), ["origin:o-item"])
        XCTAssertEqual(m?.expansionPending, false, "OFF must not leave the mutation pending re-expansion")
        XCTAssertEqual(m?.identities, [], "OFF must carry no identity seeds")
        XCTAssertNotNil(m?.trakt, "Trakt mirror is independent of the server-sync toggle")
    }

    func testOffEpisodeSuppressesEpisodeOrigin() {
        let m = WatchMutationFactory.playbackStop(
            item: episode("e-1", account: "origin"),
            position: 1200, watchedPercent: 95, primaryAccountID: "origin", additionalSources: union,
            crossServerSync: false
        )
        XCTAssertEqual(m?.targets.map(\.id), ["origin:e-1"])
        XCTAssertNil(m?.episodeOrigin, "OFF must strip the episode origin seed so twins aren't fanned out")
        XCTAssertEqual(m?.expansionPending, false)
    }

    func testOffStillWritesOriginWhenIndexKnewOnlyAPeer() {
        // Partial index knew the title only on another account; OFF must still
        // write the true origin (never drop/swap the write).
        let origin = movie("420", account: "remote")
        let peerOnly = [MediaSourceRef(accountID: "local", itemID: "6950", providerKind: .plex)]
        let targets = WatchMutationFactory.targets(
            for: origin, primaryAccountID: "remote", additionalSources: peerOnly, crossServerSync: false
        )
        XCTAssertEqual(targets.map(\.id), ["remote:420"],
                       "OFF writes the origin only — never the peer the index happened to know")
    }
}
