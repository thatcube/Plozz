import XCTest
import CoreModels
@testable import AppShell

/// Fan-out parity for the **eager identity index** seam (Angle B): proves the
/// real ``WatchMutationFactory`` (the fan-out the action coordinator and the
/// player both call) derives **exactly** the index snapshot's target set, so a
/// title played from any surface converges on every server the detail picker
/// would show — origin-agnostic and N-account complete.
///
/// The integration contract on this branch: every read surface stamps
/// `item.sources`/`additionalSources` from the shared ``IdentityIndexSnapshot``
/// before building the mutation, after which the factory's targets equal the
/// snapshot's set. These tests build the snapshot through the real
/// ``IdentityIndex`` actor (faithful identity keying) and feed
/// `snapshot.sourceRefs(for:)` into the factory exactly as the app does.
final class WatchFanOutParityTests: XCTestCase {
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

    private func server(_ kind: ProviderKind) -> SourceServerInfo {
        SourceServerInfo(providerKind: kind)
    }

    /// Same movie on Jellyfin + Plex: the factory's targets equal the index
    /// snapshot's targets whether the watch originates from the Plex copy or the
    /// Jellyfin copy. This is the core "same set regardless of entry path" claim,
    /// proven against the REAL factory and a REAL index snapshot — and proven for
    /// BOTH origins (the Plex-as-destination leg that was the live bug).
    func testFactoryTargetsEqualSnapshotTargetsBothOrigins() async {
        let index = IdentityIndex()
        await index.ingest([movie("jf-1", account: "jf")], accountID: "jf", serverInfo: server(.jellyfin))
        await index.ingest([movie("px-1", account: "plex")], accountID: "plex", serverInfo: server(.plex))
        let snapshot = await index.snapshot()

        for origin in [movie("jf-1", account: "jf"), movie("px-1", account: "plex")] {
            let additional = snapshot.sourceRefs(for: origin)
            let factoryTargets = Set(
                WatchMutationFactory.targets(
                    for: origin,
                    primaryAccountID: "jf",
                    additionalSources: additional
                ).map(\.id)
            )
            let snapshotTargets = Set(snapshot.targets(for: origin).map(\.id))

            XCTAssertEqual(
                factoryTargets, snapshotTargets,
                "Factory fan-out must equal the index snapshot's set for origin \(origin.sourceAccountID ?? "?")"
            )
            XCTAssertEqual(factoryTargets, ["jf:jf-1", "plex:px-1"])
        }
    }

    /// N-account (3 servers, both providers): the played-toggle mutation built
    /// from the snapshot reaches all of them, with no 2-account hard-coding.
    func testPlayedToggleCarriesAllKnownAccounts() async {
        let index = IdentityIndex()
        await index.ingest([movie("1", account: "jf-mine")], accountID: "jf-mine", serverInfo: server(.jellyfin))
        await index.ingest([movie("2", account: "jf-sis")], accountID: "jf-sis", serverInfo: server(.jellyfin))
        await index.ingest([movie("3", account: "plex-sis")], accountID: "plex-sis", serverInfo: server(.plex))
        let snapshot = await index.snapshot()

        let played = movie("1", account: "jf-mine") // entered from one server's row
        let mutation = WatchMutationFactory.playedToggle(
            item: played,
            played: true,
            primaryAccountID: "jf-mine",
            additionalSources: snapshot.sourceRefs(for: played)
        )
        XCTAssertEqual(
            Set((mutation?.targets ?? []).map(\.id)),
            ["jf-mine:1", "jf-sis:2", "plex-sis:3"],
            "Marking watched must fan out to every account the index knows, not just two"
        )
    }

    /// Cold / unknown item: the index has never seen this title, so the fan-out
    /// still converges on the origin server (fail-toward-writing — never drop the
    /// write just because the index is cold or the title is genuinely single-source).
    func testUnknownItemStillTargetsItsOwnServer() async {
        let index = IdentityIndex()
        let snapshot = await index.snapshot() // empty
        let lone = movie("solo", account: "plex")

        let mutation = WatchMutationFactory.playedToggle(
            item: lone,
            played: true,
            primaryAccountID: "plex",
            additionalSources: snapshot.sourceRefs(for: lone)
        )
        XCTAssertEqual(
            (mutation?.targets ?? []).map(\.id), ["plex:solo"],
            "A cold/unknown title must still target its own origin server"
        )
    }

    /// playbackStop (the player's convergence path) is likewise origin-agnostic:
    /// a finish from the Plex copy and from the Jellyfin copy converge on the same
    /// complete set, sourced from the index snapshot.
    func testPlaybackStopFanOutIsIdenticalAcrossOrigins() async {
        let index = IdentityIndex()
        await index.ingest([movie("jf-9", account: "jf")], accountID: "jf", serverInfo: server(.jellyfin))
        await index.ingest([movie("px-9", account: "plex")], accountID: "plex", serverInfo: server(.plex))
        let snapshot = await index.snapshot()

        func stopTargets(from origin: MediaItem, primary: String) -> Set<String> {
            let mutation = WatchMutationFactory.playbackStop(
                item: origin,
                position: 0,
                watchedPercent: 100,
                primaryAccountID: primary,
                additionalSources: snapshot.sourceRefs(for: origin)
            )
            return Set((mutation?.targets ?? []).map(\.id))
        }

        let fromPlex = stopTargets(from: movie("px-9", account: "plex"), primary: "plex")
        let fromJelly = stopTargets(from: movie("jf-9", account: "jf"), primary: "jf")

        XCTAssertEqual(fromPlex, fromJelly,
                       "Plex-origin and Jellyfin-origin finishes must converge on the same servers")
        XCTAssertEqual(fromPlex, ["jf:jf-9", "plex:px-9"])
    }

    /// Regression for the live origin-drop bug (Brandon, build 684): a Continue-
    /// Watching tile carries no `item.sources`, and a COLD / partially-warm index
    /// knew the title only on a DIFFERENT account than the one actually played.
    /// The factory must STILL include the origin server (you watched it there) —
    /// never let a partial index silently replace it.
    func testOriginAlwaysTargetedEvenWhenIndexKnowsOnlyAnotherAccount() {
        let origin = MediaItem(
            id: "420",
            title: "The Super Mario Bros. Movie",
            kind: .movie,
            productionYear: 2023,
            providerIDs: ["Imdb": "tt6718170"],
            sourceAccountID: "remote-plex"
        )
        // Partial index union: title known ONLY on a different account.
        let additional = [MediaSourceRef(accountID: "local-plex", itemID: "6950", providerKind: .plex)]
        let targets = Set(
            WatchMutationFactory.targets(
                for: origin,
                primaryAccountID: "remote-plex",
                additionalSources: additional
            ).map(\.id)
        )
        XCTAssertTrue(
            targets.contains("remote-plex:420"),
            "Origin server must always be a target, even when a partial index knows only another account"
        )
        XCTAssertTrue(targets.contains("local-plex:6950"))
    }

    /// Locks the origin-providerKind dedup seam (regression for 000c9ab): the
    /// origin is appended FIRST and dedup is first-wins, so its `providerKind`
    /// must be resolved up front from the item's own sources ∪ the warm snapshot.
    /// When the snapshot knows the origin's kind the origin target must CARRY it
    /// (not nil); when the origin is absent from every source (cold index) it must
    /// stay nil but still be present. Without this the enriched same-account entry
    /// is dedup-dropped and the kind is silently lost.
    func testOriginTargetKeepsProviderKindFromWarmSnapshot() {
        let origin = MediaItem(
            id: "origin-item",
            title: "Dune",
            kind: .movie,
            productionYear: 2021,
            providerIDs: ["Tmdb": "438631"],
            sourceAccountID: "origin"
        )
        // Warm snapshot knows the origin account's kind (.jellyfin) plus peers.
        let warm = [
            MediaSourceRef(accountID: "origin", itemID: "origin-item", providerKind: .jellyfin),
            MediaSourceRef(accountID: "plex", itemID: "plex-item", providerKind: .plex)
        ]
        let warmTargets = WatchMutationFactory.targets(
            for: origin,
            primaryAccountID: "origin",
            additionalSources: warm
        )
        XCTAssertEqual(
            warmTargets.first { $0.accountID == "origin" }?.providerKind,
            .jellyfin,
            "Warm origin must carry the providerKind the snapshot knows, not nil"
        )
        XCTAssertEqual(warmTargets.first { $0.accountID == "plex" }?.providerKind, .plex)

        // Cold index: origin absent from every source ⇒ kind genuinely unknown.
        let coldTargets = WatchMutationFactory.targets(
            for: origin,
            primaryAccountID: "origin",
            additionalSources: []
        )
        let coldOrigin = coldTargets.first { $0.accountID == "origin" }
        XCTAssertNotNil(coldOrigin, "Origin must still be present when its kind is unknown")
        XCTAssertNil(coldOrigin?.providerKind, "Cold origin (absent from sources) yields nil kind")
    }

    /// A movie / series mutation persists the title's identities and is marked
    /// `expansionPending`, so a drain re-resolves the index union as it warms (the
    /// warm-race fix). A genuinely id-less, year-less title carries no identities
    /// and stays non-pending (nothing to index-match), preserving single-source
    /// convergence.
    func testMovieMutationCarriesIdentitiesAndExpansionPending() {
        let strong = MediaItem(
            id: "420", title: "Mario", kind: .movie, productionYear: 2023,
            providerIDs: ["Imdb": "tt6718170"], sourceAccountID: "a"
        )
        let m = WatchMutationFactory.playbackStop(
            item: strong, position: 1647, watchedPercent: 29.7, primaryAccountID: "a"
        )
        XCTAssertEqual(m?.expansionPending, true)
        XCTAssertEqual(m?.identities, [.external(source: "imdb", value: "tt6718170")])

        let idless = MediaItem(id: "x", title: "Family Clip", kind: .movie, sourceAccountID: "a")
        let m2 = WatchMutationFactory.playbackStop(
            item: idless, position: 50, watchedPercent: 10, primaryAccountID: "a"
        )
        XCTAssertEqual(m2?.expansionPending, false)
        XCTAssertEqual(m2?.identities, [])
    }
}
