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

    func testUnionKeepsMembersInGlobalArrivalOrderNotClusterOrder() {
        // Concatenating one cluster's members onto another's would order them
        // [A, D, B] instead of [A, B, D], which changes both the split-guard's
        // greedy grouping and which member fronts the card. The merged card's
        // source list is the observable consequence.
        let batches = [
            [
                item("a", title: "Dune", year: 2021, account: "acct-a", ids: ["tmdb": "438631"]),
                item("b", title: "Dune", year: 2021, account: "acct-b", ids: ["imdb": "tt1160419"]),
                item("d", title: "Dune", year: 2021, account: "acct-d", ids: ["tmdb": "438631"])
            ],
            [
                item(
                    "e",
                    title: "Dune",
                    year: 2021,
                    account: "acct-e",
                    ids: ["tmdb": "438631", "imdb": "tt1160419"]
                )
            ]
        ]
        let result = merged(batches)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(
            result[0].sources.map(\.accountID),
            ["acct-a", "acct-b", "acct-d", "acct-e"],
            "sources follow global arrival order, not the order clusters happened to fuse"
        )
        assertMatchesBatch(batches)
    }

    // MARK: Identity-index growth

    func testIndexGrowthRelinksCardsThatWereFoldedBeforeItWarmed() {
        // The index warms asynchronously. Two rows sharing no external id are two
        // cards until the index learns they are one title — and both were already
        // folded by then, so nothing new arrives to bridge them. A one-shot merge
        // re-reads the index for every item every page and self-heals; the
        // incremental one has to notice the revision moved.
        final class Index: @unchecked Sendable {
            var revision = 0
            var linked = false
            func sources(_ item: MediaItem) -> [MediaSourceRef] {
                guard linked, item.sourceAccountID == "plex" else { return [] }
                return [MediaSourceRef(accountID: "jelly", itemID: "j1", kind: .movie)]
            }
        }
        let index = Index()
        var merger = IncrementalMediaItemMerger(
            identitySources: { index.sources($0) },
            identityRevision: { index.revision }
        )
        merger.append([item("p1", title: "Dune", year: 2021, account: "plex")])
        merger.append([item("j1", title: "Dune 2021", year: 2021, account: "jelly")])
        XCTAssertEqual(merger.count, 2, "unlinked to begin with")

        index.linked = true
        index.revision += 1
        // A later page re-folds, because nothing has been read out yet.
        merger.append([item("x1", title: "Arrival", year: 2016, account: "plex")])

        let result = merger.mergedItems()
        XCTAssertEqual(result.count, 2, "Dune collapsed to one card; Arrival is its own")
        XCTAssertEqual(
            result.first { $0.title.hasPrefix("Dune") }?.id,
            "p1",
            "the earlier row still fronts the merged card"
        )
        XCTAssertEqual(result.map(\.id), ["p1", "x1"], "arrival order survives the re-fold")
    }

    func testIndexGrowthIsNotFoldedInOnceItemsHaveBeenHandedOut() {
        // The re-fold is bound to `append` on purpose: collapsing two cards shifts
        // every index after them, and the paged grid addresses items by index and
        // never re-reads a stored page. Doing it on a read would move items under
        // already-painted cells. A drained grid therefore keeps what it had.
        final class Index: @unchecked Sendable {
            var revision = 0
            var linked = false
            func sources(_ item: MediaItem) -> [MediaSourceRef] {
                guard linked, item.sourceAccountID == "plex" else { return [] }
                return [MediaSourceRef(accountID: "jelly", itemID: "j1", kind: .movie)]
            }
        }
        let index = Index()
        var merger = IncrementalMediaItemMerger(
            identitySources: { index.sources($0) },
            identityRevision: { index.revision }
        )
        merger.append([
            item("p1", title: "Dune", year: 2021, account: "plex"),
            item("j1", title: "Dune 2021", year: 2021, account: "jelly")
        ])
        // Reading the first page hands out indices 0 and 1.
        XCTAssertEqual(merger.slice(from: 0, limit: 20).count, 2)

        index.linked = true
        index.revision += 1
        // Even a further append must NOT collapse them now: index 1 is already on
        // screen, and shortening the collection would slide index 2 into its place.
        merger.append([item("x1", title: "Arrival", year: 2016, account: "plex")])
        XCTAssertEqual(
            merger.mergedItems().map(\.id), ["p1", "j1", "x1"],
            "indices already handed out stay put"
        )
    }

    func testUnchangedIndexRevisionDoesNotRefold() {
        // The re-fold is linear, so it must fire only when the index actually moved.
        var reads = 0
        var merger = IncrementalMediaItemMerger(
            identitySources: { _ in
                reads += 1
                return []
            },
            identityRevision: { 7 }
        )
        merger.append([item("a", title: "A", account: "x")])
        merger.append([item("b", title: "B", account: "x")])
        merger.append([item("c", title: "C", account: "x")])
        XCTAssertEqual(reads, 3, "one identity lookup per inserted item, never a re-fold")
    }

    func testExposedPrefixNeverMovesWhenTheSplitGuardWouldInsertACard() {
        // A sequel scraped with its predecessor's external id joins the cluster by
        // key but CONTRADICTS its member, so the split guard would open a second
        // sub-group — inserting a card between "Scream 6" and "Arrival" and sliding
        // "Arrival" down. Anything already handed out must not move.
        var merger = IncrementalMediaItemMerger()
        merger.append([
            item("s6", title: "Scream 6", year: 2023, account: "plex", ids: ["tmdb": "934433"]),
            item("ar", title: "Arrival", year: 2016, account: "plex")
        ])
        let exposed = merger.slice(from: 0, limit: 20).map(\.id)
        XCTAssertEqual(exposed, ["s6", "ar"])

        merger.append([
            item("s7", title: "Scream 7", year: 2026, account: "jelly", ids: ["tmdb": "934433"])
        ])
        let after = merger.mergedItems().map(\.id)
        XCTAssertEqual(
            Array(after.prefix(exposed.count)), exposed,
            "the exposed prefix is untouched"
        )
        XCTAssertEqual(after, ["s6", "ar", "s7"], "the contradicting title lands at the tail, still reachable")
    }

    func testBeforeExposureTheSplitGuardStillPartitionsExactlyLikeBatch() {
        // The append-only rule must not weaken the pre-exposure merge.
        let batches = [
            [item("s6", title: "Scream 6", year: 2023, account: "plex", ids: ["tmdb": "934433"])],
            [item("s7", title: "Scream 7", year: 2026, account: "jelly", ids: ["tmdb": "934433"])]
        ]
        assertMatchesBatch(batches)
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
