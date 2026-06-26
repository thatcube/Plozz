import XCTest
@testable import CoreModels

/// Tests for the **eager identity index** (Angle B SSOT): the single
/// identity → cross-server-sources store that Home, Browse, Search, the detail
/// picker and the watch fan-out all read, so a title's resolved server set is
/// identical regardless of which entry path reached it.
///
/// The guarantees under test:
///  - the snapshot unions an identity's sources across every account, origin-
///    agnostically (a Plex card and a Jellyfin card for the same title resolve
///    the *same* set), and de-duplicates by (account,item);
///  - it generalises past two accounts / both providers with no hardcoding;
///  - `MediaItemMerger`'s enrichment seam folds the index set into a card even
///    when only one server populated the loaded row (the movie fix), without
///    letting an index placeholder overwrite a loaded row's live watch-state;
///  - strong-id series safety / ambiguity rules still hold;
///  - a cold (empty) index degrades to the caller's own sources — never dropping
///    a write.
final class IdentityIndexTests: XCTestCase {
    // MARK: Builders

    private func movie(_ id: String, account: String, tmdb: String) -> MediaItem {
        var item = MediaItem(id: id, title: "Film", kind: .movie, productionYear: 2010, providerIDs: ["Tmdb": tmdb])
        item.sourceAccountID = account
        return item
    }

    private func series(_ id: String, account: String, tvdb: String) -> MediaItem {
        var item = MediaItem(id: id, title: "Show", kind: .series, providerIDs: ["Tvdb": tvdb])
        item.sourceAccountID = account
        return item
    }

    private func indexed(
        _ account: String,
        _ itemID: String,
        kind: MediaItemKind = .movie,
        provider: ProviderKind? = nil
    ) -> IndexedSource {
        IndexedSource(accountID: account, itemID: itemID, providerKind: provider, kind: kind)
    }

    // MARK: Snapshot lookup / union

    func testSnapshotUnionsSourcesAcrossAccountsForOneIdentity() {
        let identity = MediaIdentity.external(source: "tmdb", value: "42")
        let snapshot = IdentityIndexSnapshot(byIdentity: [
            identity: [
                indexed("jf", "j1", provider: .jellyfin),
                indexed("plex", "p1", provider: .plex)
            ]
        ])
        let probe = movie("ignored", account: "jf", tmdb: "42")
        let refs = snapshot.sourceRefs(for: probe)
        XCTAssertEqual(Set(refs.map(\.id)), ["jf:j1", "plex:p1"])
    }

    func testLookupIsOriginAgnostic() {
        // The same identity resolves the identical full set whether the probing
        // item came from the Plex copy or the Jellyfin copy.
        let identity = MediaIdentity.external(source: "tmdb", value: "42")
        let snapshot = IdentityIndexSnapshot(byIdentity: [
            identity: [indexed("jf", "j1", provider: .jellyfin), indexed("plex", "p1", provider: .plex)]
        ])
        let fromJF = movie("j1", account: "jf", tmdb: "42")
        let fromPlex = movie("p1", account: "plex", tmdb: "42")
        XCTAssertEqual(
            Set(snapshot.targets(for: fromJF).map(\.id)),
            Set(snapshot.targets(for: fromPlex).map(\.id))
        )
        XCTAssertEqual(Set(snapshot.targets(for: fromJF).map(\.id)), ["jf:j1", "plex:p1"])
    }

    func testSnapshotDeduplicatesByAccountItem() {
        let identity = MediaIdentity.external(source: "tmdb", value: "42")
        let snapshot = IdentityIndexSnapshot(byIdentity: [
            identity: [indexed("jf", "j1"), indexed("jf", "j1")]
        ])
        XCTAssertEqual(snapshot.sourceRefs(for: movie("x", account: "jf", tmdb: "42")).count, 1)
    }

    func testMoreThanTwoAccountsBothProviders() {
        // No two-account hardcoding: five servers across both providers all resolve.
        let identity = MediaIdentity.external(source: "tmdb", value: "7")
        let sources = [
            indexed("a", "a1", provider: .jellyfin),
            indexed("b", "b1", provider: .plex),
            indexed("c", "c1", provider: .jellyfin),
            indexed("d", "d1", provider: .plex),
            indexed("e", "e1", provider: .jellyfin)
        ]
        let snapshot = IdentityIndexSnapshot(byIdentity: [identity: sources])
        let targets = snapshot.targets(for: movie("a1", account: "a", tmdb: "7"))
        XCTAssertEqual(Set(targets.map(\.id)), ["a:a1", "b:b1", "c:c1", "d:d1", "e:e1"])
    }

    func testColdSnapshotResolvesNothing() {
        XCTAssertTrue(IdentityIndexSnapshot.empty.sourceRefs(for: movie("x", account: "jf", tmdb: "42")).isEmpty)
        XCTAssertTrue(IdentityIndexSnapshot.empty.targets(for: movie("x", account: "jf", tmdb: "42")).isEmpty)
    }

    // MARK: Merger enrichment seam (the movie fix)

    func testMergerEnrichmentAddsIndexOnlyServer() {
        // A movie loaded from ONLY its Jellyfin row, but the index knows a Plex
        // copy too. After merge the card carries BOTH sources, so the fan-out
        // derived from `item.sources` reaches Plex regardless of entry path.
        let loaded = movie("j1", account: "jf", tmdb: "42")
        let snapshot = IdentityIndexSnapshot(byIdentity: [
            .external(source: "tmdb", value: "42"): [
                indexed("jf", "j1", provider: .jellyfin),
                indexed("plex", "p1", provider: .plex)
            ]
        ])
        let merged = MediaItemMerger.merge([loaded]) { snapshot.sourceRefs(for: $0) }
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(Set(merged[0].sources.map(\.id)), ["jf:j1", "plex:p1"])
    }

    func testEnrichmentNeverOverwritesLoadedWatchState() {
        // The loaded Jellyfin row has real progress; the index placeholder for the
        // same server carries none. The loaded ref must win (index appended last,
        // deduped by id) so progress isn't zeroed.
        var loaded = movie("j1", account: "jf", tmdb: "42")
        loaded.sources = [MediaSourceRef(
            accountID: "jf", itemID: "j1", providerKind: .jellyfin,
            resumePosition: 600, isPlayed: false, lastPlayedAt: Date()
        )]
        let snapshot = IdentityIndexSnapshot(byIdentity: [
            .external(source: "tmdb", value: "42"): [
                indexed("jf", "j1", provider: .jellyfin),
                indexed("plex", "p1", provider: .plex)
            ]
        ])
        let merged = MediaItemMerger.merge([loaded]) { snapshot.sourceRefs(for: $0) }
        let jfSource = merged[0].sources.first { $0.accountID == "jf" }
        XCTAssertEqual(jfSource?.resumePosition, 600, "Loaded watch-state must survive enrichment")
        XCTAssertEqual(Set(merged[0].sources.map(\.id)), ["jf:j1", "plex:p1"])
    }

    func testColdMergerLeavesSingleSourceUntouched() {
        // Empty index + a single un-merged row ⇒ exact passthrough (existing behaviour).
        let loaded = movie("j1", account: "jf", tmdb: "42")
        let merged = MediaItemMerger.merge([loaded])
        XCTAssertEqual(merged.count, 1)
        XCTAssertTrue(merged[0].sources.isEmpty)
    }

    // MARK: Safety: no false-merge / ambiguity

    func testDifferentSeriesIDsDoNotShareSources() {
        // Two series with different strong ids must index under different
        // identities — a watch on one never fans out to the other.
        let snapshot = IdentityIndexSnapshot(byIdentity: [
            .external(source: "tvdb", value: "100"): [indexed("jf", "s100", kind: .series)],
            .external(source: "tvdb", value: "200"): [indexed("plex", "s200", kind: .series)]
        ])
        let probe = series("s100", account: "jf", tvdb: "100")
        XCTAssertEqual(snapshot.sourceRefs(for: probe).map(\.id), ["jf:s100"])
    }

    func testSeriesWithoutStrongIDResolvesNothing() {
        // A series carries no title identity (reboot/anime safety), so a series with
        // no external id can't resolve any index sources — it never false-merges.
        var noID = MediaItem(id: "s", title: "Show", kind: .series, productionYear: 2001)
        noID.sourceAccountID = "jf"
        let snapshot = IdentityIndexSnapshot(byIdentity: [
            .external(source: "tvdb", value: "100"): [indexed("jf", "s100", kind: .series)]
        ])
        XCTAssertTrue(snapshot.sourceRefs(for: noID).isEmpty)
    }

    // MARK: IdentityIndex actor

    func testActorIngestAndSnapshot() async {
        let index = IdentityIndex()
        let info = SourceServerInfo(providerKind: .jellyfin, serverName: "JF", accountName: "me")
        await index.ingest([movie("j1", account: "jf", tmdb: "42")], accountID: "jf", serverInfo: info)
        await index.ingest([movie("p1", account: "plex", tmdb: "42")], accountID: "plex",
                            serverInfo: SourceServerInfo(providerKind: .plex))
        await index.finishRebuild(for: "jf")
        await index.finishRebuild(for: "plex")

        let snapshot = await index.snapshot()
        let refs = snapshot.sourceRefs(for: movie("j1", account: "jf", tmdb: "42"))
        XCTAssertEqual(Set(refs.map(\.id)), ["jf:j1", "plex:p1"])
        let warm = await index.isWarm("jf")
        XCTAssertTrue(warm)
    }

    func testActorOnlyIndexesMoviesAndSeries() async {
        let index = IdentityIndex()
        var ep = MediaItem(id: "e1", title: "Ep", kind: .episode, seasonNumber: 1, episodeNumber: 1,
                           providerIDs: ["Tvdb": "100"])
        ep.sourceAccountID = "jf"
        await index.ingest([ep], accountID: "jf")
        let snapshot = await index.snapshot()
        XCTAssertEqual(snapshot.identityCount, 0, "Episodes are never indexed directly")
    }

    func testActorRemoveAndRetainAccounts() async {
        let index = IdentityIndex()
        await index.ingest([movie("j1", account: "jf", tmdb: "42")], accountID: "jf")
        await index.ingest([movie("p1", account: "plex", tmdb: "42")], accountID: "plex")

        await index.removeAccount("plex")
        var snapshot = await index.snapshot()
        XCTAssertEqual(Set(snapshot.sourceRefs(for: movie("x", account: "jf", tmdb: "42")).map(\.id)), ["jf:j1"])

        await index.retainAccounts(["nobody"])
        snapshot = await index.snapshot()
        XCTAssertTrue(snapshot.isEmpty, "retainAccounts prunes every non-retained account")
    }

    func testStaleAccountsRespectTTL() async {
        var clock = Date(timeIntervalSince1970: 1_000)
        let index = IdentityIndex(now: { clock })
        await index.ingest([movie("j1", account: "jf", tmdb: "42")], accountID: "jf")
        await index.finishRebuild(for: "jf")

        var stale = await index.staleAccounts(olderThan: 600)
        XCTAssertTrue(stale.isEmpty)

        clock = clock.addingTimeInterval(601)
        stale = await index.staleAccounts(olderThan: 600)
        XCTAssertEqual(stale, ["jf"])
    }

    // MARK: Snapshot store (the @Sendable bridge)

    func testSnapshotStoreProviderReflectsUpdates() {
        let store = IdentityIndexSnapshotStore()
        let provider = store.sourcesProvider()
        XCTAssertTrue(provider(movie("x", account: "jf", tmdb: "42")).isEmpty)

        store.update(IdentityIndexSnapshot(byIdentity: [
            .external(source: "tmdb", value: "42"): [indexed("jf", "j1"), indexed("plex", "p1")]
        ]))
        XCTAssertEqual(Set(provider(movie("x", account: "jf", tmdb: "42")).map(\.id)), ["jf:j1", "plex:p1"])
    }
}
