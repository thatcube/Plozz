import XCTest
@testable import CoreModels

/// Tests the **fan-out diagnostics** seam: the snapshot's cross-server counters and
/// the pure `[FANOUT]` line builders that make the on-device convergence chain
/// readable. These are pure (no OSLog), so they run on every toolchain and lock in
/// the exact signal the maintainer reads back from the device console.
final class FanoutDiagnosticsTests: XCTestCase {
    private func movie(_ id: String, account: String, tmdb: String) -> MediaItem {
        var item = MediaItem(id: id, title: "Film", kind: .movie, productionYear: 2010, providerIDs: ["Tmdb": tmdb])
        item.sourceAccountID = account
        return item
    }

    private func indexed(_ account: String, _ itemID: String, tmdb: String) -> IndexedSource {
        IndexedSource(accountID: account, itemID: itemID, kind: .movie)
    }

    // MARK: - Snapshot diagnostics counters

    func testCrossServerCountOnlyCountsUnionsAcrossAccounts() {
        let shared: MediaIdentity = .external(source: "tmdb", value: "100")
        let lonely: MediaIdentity = .external(source: "tmdb", value: "200")
        let snapshot = IdentityIndexSnapshot(byIdentity: [
            // Same title on two accounts → a genuine cross-server union.
            shared: [indexed("a", "1", tmdb: "100"), indexed("b", "2", tmdb: "100")],
            // Title on a single account → not a union.
            lonely: [indexed("a", "3", tmdb: "200")]
        ])
        XCTAssertEqual(snapshot.identityCount, 2)
        XCTAssertEqual(snapshot.crossServerIdentityCount, 1)
        XCTAssertEqual(snapshot.indexedAccountIDs, ["a", "b"])
    }

    func testEmptySnapshotReportsZeroes() {
        let snapshot = IdentityIndexSnapshot.empty
        XCTAssertEqual(snapshot.identityCount, 0)
        XCTAssertEqual(snapshot.crossServerIdentityCount, 0)
        XCTAssertTrue(snapshot.indexedAccountIDs.isEmpty)
    }

    // MARK: - Line builders

    func testIndexStateLineSurfacesUnionCount() {
        let snapshot = IdentityIndexSnapshot(byIdentity: [
            .external(source: "tmdb", value: "100"): [indexed("a", "1", tmdb: "100"), indexed("b", "2", tmdb: "100")]
        ])
        let line = FanoutDiagnostics.indexStateLine(snapshot, phase: "warm")
        XCTAssertTrue(line.contains("warm:"))
        XCTAssertTrue(line.contains("identities=1"))
        XCTAssertTrue(line.contains("crossServer=1"))
        XCTAssertTrue(line.contains("accounts=2"))
    }

    func testStopLineWithOriginOnlyTargetIsVisible() {
        let item = movie("1", account: "a", tmdb: "100")
        let line = FanoutDiagnostics.stopLine(
            title: item.title,
            kind: item.kind,
            itemID: item.id,
            originAccountID: "a",
            identities: MediaItemIdentity.identities(for: item),
            indexUnion: [],
            mutationTargets: [WatchMutationTarget(accountID: "a", itemID: "1", providerKind: .plex)],
            played: true,
            resumePosition: nil,
            watchedPercent: 95
        )
        XCTAssertTrue(line.contains("tmdb:100"))
        XCTAssertTrue(line.contains("indexUnion=0"))
        XCTAssertTrue(line.contains("targets=1"))
        XCTAssertTrue(line.contains("a:1:plex"))
    }

    func testStopLineWithNilMutationExplainsItself() {
        let line = FanoutDiagnostics.stopLine(
            title: "Film", kind: .movie, itemID: "1", originAccountID: nil,
            identities: [], indexUnion: [], mutationTargets: nil,
            played: nil, resumePosition: nil, watchedPercent: 2
        )
        XCTAssertTrue(line.contains("identity=none"))
        XCTAssertTrue(line.contains("mutation=nil"))
    }

    func testDrainTargetLineFormatsOutcome() {
        let target = WatchMutationTarget(accountID: "b", itemID: "9", providerKind: .jellyfin)
        let line = FanoutDiagnostics.drainTargetLine(target, outcome: "setPlayed(true)=OK")
        XCTAssertEqual(line, "drain.target acct=b item=9 kind=jellyfin -> setPlayed(true)=OK")
    }
}
