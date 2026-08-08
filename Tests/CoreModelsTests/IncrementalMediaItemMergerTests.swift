import XCTest
@testable import CoreModels

/// The incremental merger must be a drop-in for the batch merger: same cards, same
/// order, same source fan-out — just folded in a page at a time.
///
/// These tests are written as **equivalence** checks against
/// `MediaItemMerger.merge(_:)` wherever possible, because that is the property
/// that actually matters. A behaviour difference here would show up as a title
/// silently appearing twice (or vanishing) partway down a long combined browse,
/// which is exactly the class of bug that is hard to spot by eye on device.
final class IncrementalMediaItemMergerTests: XCTestCase {

    private func item(
        _ id: String,
        title: String,
        kind: MediaItemKind = .movie,
        year: Int? = nil,
        account: String,
        ids: [String: String] = [:]
    ) -> MediaItem {
        MediaItem(
            id: id,
            title: title,
            kind: kind,
            productionYear: year,
            providerIDs: ids,
            sourceAccountID: account
        )
    }

    private func merged(
        _ batches: [[MediaItem]],
        serverInfo: @escaping (String) -> SourceServerInfo? = { _ in nil },
        identitySources: @escaping (MediaItem) -> [MediaSourceRef] = { _ in [] }
    ) -> [MediaItem] {
        var merger = IncrementalMediaItemMerger(
            serverInfo: serverInfo,
            identitySources: identitySources
        )
        for batch in batches { merger.append(batch) }
        return merger.mergedItems()
    }

    private func assertMatchesBatch(
        _ batches: [[MediaItem]],
        serverInfo: @escaping (String) -> SourceServerInfo? = { _ in nil },
        identitySources: @escaping (MediaItem) -> [MediaSourceRef] = { _ in [] },
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let incremental = merged(batches, serverInfo: serverInfo, identitySources: identitySources)
        let batch = MediaItemMerger.merge(
            batches.flatMap { $0 },
            serverInfo: serverInfo,
            identitySources: identitySources
        )
        XCTAssertEqual(
            incremental.map(\.id),
            batch.map(\.id),
            "merged card order/identity diverged from the batch merger",
            file: file,
            line: line
        )
        XCTAssertEqual(
            incremental.map { Set($0.sources.map(\.accountID)) },
            batch.map { Set($0.sources.map(\.accountID)) },
            "per-card source fan-out diverged from the batch merger",
            file: file,
            line: line
        )
    }

    // MARK: Equivalence with the batch merger

    func testEmptyInputProducesNothing() {
        XCTAssertTrue(merged([]).isEmpty)
        XCTAssertTrue(merged([[]]).isEmpty)
    }

    func testDistinctTitlesArePreservedInFirstAppearanceOrder() {
        let batches = [
            [item("1", title: "Arrival", year: 2016, account: "plex")],
            [item("2", title: "Dune", year: 2021, account: "plex")],
            [item("3", title: "Sicario", year: 2015, account: "plex")]
        ]
        XCTAssertEqual(merged(batches).map(\.title), ["Arrival", "Dune", "Sicario"])
        assertMatchesBatch(batches)
    }

    func testDuplicateArrivingInALaterBatchStillCollapses() {
        // The whole point: a title that sorts differently per server arrives pages
        // apart and must still fold into the card that is already on screen.
        let batches = [
            [
                item("p1", title: "Dune", year: 2021, account: "plex", ids: ["tmdb": "438631"]),
                item("p2", title: "Arrival", year: 2016, account: "plex")
            ],
            [item("j1", title: "Dune", year: 2021, account: "jelly", ids: ["tmdb": "438631"])]
        ]
        let result = merged(batches)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.map(\.id), ["p1", "p2"])
        XCTAssertEqual(Set(result[0].sources.map(\.accountID)), ["plex", "jelly"])
        assertMatchesBatch(batches)
    }

    func testLaterItemBridgingTwoExistingClustersKeepsTheEarlierPosition() {
        // Two cards that share no key with each other, then a third that shares one
        // with each: the two must fuse into ONE card sitting where the earlier of
        // them was, exactly as a whole-collection union-find would place it.
        let batches = [
            [
                item("a", title: "Dune", year: 2021, account: "plex", ids: ["tmdb": "438631"]),
                item("filler", title: "Arrival", year: 2016, account: "plex"),
                item("b", title: "Dune", year: 2021, account: "jelly", ids: ["imdb": "tt1160419"])
            ],
            [
                item(
                    "c",
                    title: "Dune",
                    year: 2021,
                    account: "share",
                    ids: ["tmdb": "438631", "imdb": "tt1160419"]
                )
            ]
        ]
        let result = merged(batches)
        XCTAssertEqual(result.map(\.id), ["a", "filler"])
        XCTAssertEqual(Set(result[0].sources.map(\.accountID)), ["plex", "jelly", "share"])
        assertMatchesBatch(batches)
    }

    func testSameServerTwoAccountsCollapseByServerScopedItemID() {
        let info: (String) -> SourceServerInfo? = { accountID in
            SourceServerInfo(
                providerKind: .jellyfin,
                serverName: "Home",
                accountName: accountID,
                serverID: "server-1"
            )
        }
        let batches = [
            [item("42", title: "Sicario", year: 2015, account: "user-a")],
            [item("42", title: "Sicario", year: 2015, account: "user-b")]
        ]
        let result = merged(batches, serverInfo: info)
        XCTAssertEqual(result.count, 1)
        assertMatchesBatch(batches, serverInfo: info)
    }

    func testIdentityIndexMembershipMergesRowsWithNoSharedExternalID() {
        // The id-less row arrives FIRST and the index knows it is the same work as
        // a row that has not been seen yet — the "claim" direction, which a naive
        // incremental merger gets wrong because the claimed row doesn't exist yet.
        let sources: (MediaItem) -> [MediaSourceRef] = { item in
            guard item.sourceAccountID == "plex" else { return [] }
            return [MediaSourceRef(accountID: "jelly", itemID: "j1", kind: .movie)]
        }
        let batches = [
            [item("p1", title: "Dune", year: 2021, account: "plex")],
            [item("j1", title: "Dune 2021", year: 2021, account: "jelly")]
        ]
        let result = merged(batches, identitySources: sources)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].id, "p1")
        assertMatchesBatch(batches, identitySources: sources)
    }

    func testSplitGuardStillEjectsAContradictingMember() {
        // A bad shared external id must not collapse two clearly different films.
        let batches = [
            [
                item("a", title: "Scream 6", year: 2023, account: "plex", ids: ["tmdb": "934433"]),
                item("b", title: "Scream 7", year: 2026, account: "jelly", ids: ["tmdb": "934433"])
            ]
        ]
        XCTAssertEqual(merged(batches).count, 2)
        assertMatchesBatch(batches)
    }

    func testBatchBoundariesDoNotChangeTheResult() {
        // The same items fed one-at-a-time, in pairs, or all at once must produce
        // identical output — otherwise the grid would depend on page size.
        let items = [
            item("a", title: "Dune", year: 2021, account: "plex", ids: ["tmdb": "438631"]),
            item("b", title: "Arrival", year: 2016, account: "plex"),
            item("c", title: "Dune", year: 2021, account: "jelly", ids: ["tmdb": "438631"]),
            item("d", title: "Sicario", year: 2015, account: "jelly"),
            item("e", title: "Arrival", year: 2016, account: "jelly", ids: ["tmdb": "329865"])
        ]
        let oneAtATime = merged(items.map { [$0] }).map(\.id)
        let inPairs = merged([Array(items[0..<2]), Array(items[2..<4]), [items[4]]]).map(\.id)
        let allAtOnce = merged([items]).map(\.id)
        XCTAssertEqual(oneAtATime, allAtOnce)
        XCTAssertEqual(inPairs, allAtOnce)
    }

    // MARK: Slicing

    func testSliceReturnsTheRequestedWindowAndClamps() {
        var merger = IncrementalMediaItemMerger()
        merger.append((0..<10).map { item("\($0)", title: "T\($0)", account: "plex") })
        XCTAssertEqual(merger.count, 10)
        XCTAssertEqual(merger.slice(from: 3, limit: 4).map(\.id), ["3", "4", "5", "6"])
        XCTAssertEqual(merger.slice(from: 8, limit: 10).map(\.id), ["8", "9"])
        XCTAssertTrue(merger.slice(from: 20, limit: 5).isEmpty)
        XCTAssertTrue(merger.slice(from: -5, limit: 0).isEmpty)
    }
}
