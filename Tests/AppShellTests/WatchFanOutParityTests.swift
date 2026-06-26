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
}
