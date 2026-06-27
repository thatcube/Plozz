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

    // MARK: Persistence (cold-boot convergence)

    func testExportThenRestoreRoundTripsCrossServerUnion() async {
        var clock = Date(timeIntervalSince1970: 10_000)
        let source = IdentityIndex(now: { clock })
        let info = SourceServerInfo(providerKind: .jellyfin, serverName: "JF", accountName: "me")
        await source.ingest([movie("j1", account: "jf", tmdb: "42")], accountID: "jf", serverInfo: info)
        await source.ingest([movie("p1", account: "plex", tmdb: "42")], accountID: "plex",
                            serverInfo: SourceServerInfo(providerKind: .plex))
        await source.finishRebuild(for: "jf")
        await source.finishRebuild(for: "plex")

        let exported = await source.export()
        // Survive a JSON round-trip exactly as the file store will encode it.
        let data = try! JSONEncoder().encode(exported)
        let decoded = try! JSONDecoder().decode(PersistedIdentityIndex.self, from: data)

        // A fresh, cold index seeded from disk must expose the full union at t=0.
        clock = clock.addingTimeInterval(5)
        let restored = IdentityIndex(now: { clock })
        let didRestore = await restored.restore(from: decoded, retaining: ["jf", "plex"])
        XCTAssertTrue(didRestore)

        let snapshot = await restored.snapshot()
        let refs = snapshot.sourceRefs(for: movie("probe", account: "jf", tmdb: "42"))
        XCTAssertEqual(Set(refs.map(\.id)), ["jf:j1", "plex:p1"],
                       "A restored index must expose the same cross-server union it persisted")
        XCTAssertEqual(snapshot.crossServerIdentityCount, 1)
        // Restored accounts are warm so the first post-boot stop fans out immediately.
        let jfWarm = await restored.isWarm("jf")
        XCTAssertTrue(jfWarm)
    }

    func testRestorePrunesAccountsNoLongerActive() async {
        let source = IdentityIndex()
        await source.ingest([movie("j1", account: "jf", tmdb: "42")], accountID: "jf")
        await source.ingest([movie("p1", account: "plex", tmdb: "42")], accountID: "plex")
        await source.finishRebuild(for: "jf")
        await source.finishRebuild(for: "plex")
        let exported = await source.export()

        // Plex was signed out between launches: it must not be resurrected from disk.
        let restored = IdentityIndex()
        await restored.restore(from: exported, retaining: ["jf"])

        let snapshot = await restored.snapshot()
        XCTAssertEqual(Set(snapshot.sourceRefs(for: movie("x", account: "jf", tmdb: "42")).map(\.id)), ["jf:j1"])
        let plexWarm = await restored.isWarm("plex")
        XCTAssertFalse(plexWarm, "A pruned account is never marked warm from disk")
    }

    func testRestoreDoesNotClobberAFreshLiveScan() async {
        // A live scan already warmed "jf" with its current ids; a stale disk entry
        // for the same account must not overwrite it.
        let index = IdentityIndex()
        await index.ingest([movie("fresh", account: "jf", tmdb: "42")], accountID: "jf")
        await index.finishRebuild(for: "jf")

        let stale = PersistedIdentityIndex(
            entriesByAccount: ["jf": [
                .init(identity: .external(source: "tmdb", value: "42"),
                      source: indexed("jf", "stale-old-id"))
            ]],
            builtAtByAccount: ["jf": Date(timeIntervalSince1970: 1)]
        )
        let didRestore = await index.restore(from: stale, retaining: ["jf"])
        XCTAssertFalse(didRestore, "Disk must never clobber a fresher live scan")

        let snapshot = await index.snapshot()
        XCTAssertEqual(Set(snapshot.sourceRefs(for: movie("x", account: "jf", tmdb: "42")).map(\.id)), ["jf:fresh"])
    }

    func testRestorePreservesBuiltAtSoStalenessStillReWarms() async {
        let clock = Date(timeIntervalSince1970: 100_000)
        let index = IdentityIndex(now: { clock })
        let persisted = PersistedIdentityIndex(
            entriesByAccount: ["jf": [
                .init(identity: .external(source: "tmdb", value: "42"), source: indexed("jf", "j1"))
            ]],
            // Built well over the TTL ago, so the restored account is immediately
            // stale and the background warm refreshes it.
            builtAtByAccount: ["jf": clock.addingTimeInterval(-10_000)]
        )
        await index.restore(from: persisted, retaining: ["jf"])

        let stale = await index.staleAccounts(olderThan: 600)
        XCTAssertEqual(stale, ["jf"], "A restored-but-old account must re-warm on the normal TTL path")
    }

    func testExportOnlyIncludesWarmAccounts() async {
        let index = IdentityIndex()
        await index.ingest([movie("j1", account: "jf", tmdb: "42")], accountID: "jf")
        await index.finishRebuild(for: "jf")
        // "plex" ingested but never finished (inconclusive scan) — must not persist.
        await index.ingest([movie("p1", account: "plex", tmdb: "42")], accountID: "plex")

        let exported = await index.export()
        XCTAssertEqual(Set(exported.entriesByAccount.keys), ["jf"],
                       "Only conclusively-warmed accounts are persisted")
    }

    // MARK: Population-time enrichment (Plex guid-less completeness)

    /// Build a Plex series hit as it arrives from a list endpoint that OMITTED the
    /// Guid array — i.e. no strong id, so it resolves to no identity.
    private func guidlessPlexSeries(_ id: String, account: String) -> MediaItem {
        var item = MediaItem(id: id, title: "Strange Show", kind: .series, productionYear: 2016)
        item.sourceAccountID = account
        return item
    }

    func testEnrichmentFillsGuidlessPlexSeries() async {
        // A guid-less Plex series enriched via its fuller metadata record (which
        // carries the tvdb guid) is keyed on the real id, so the store contains it.
        let listHit = guidlessPlexSeries("p100", account: "plex")
        XCTAssertTrue(MediaItemIdentity.identities(for: listHit).isEmpty, "precondition: no strong id")

        let result = await IdentityEnrichment.prepare([listHit]) { item in
            var full = item
            full.providerIDs = ["Tvdb": "555"]   // metadata endpoint supplies the Guid
            return full
        }
        XCTAssertFalse(result.inconclusive)
        XCTAssertEqual(result.indexable.count, 1)
        XCTAssertEqual(
            MediaItemIdentity.identities(for: result.indexable[0]),
            [.external(source: "tvdb", value: "555")]
        )
    }

    func testEnrichmentFetchFailureIsInconclusiveNotDropped() async {
        let listHit = guidlessPlexSeries("p100", account: "plex")
        let result = await IdentityEnrichment.prepare([listHit]) { _ in nil } // fetch failed
        XCTAssertTrue(result.inconclusive, "A failed enrichment must force a retry, never a silent drop")
        XCTAssertTrue(result.indexable.isEmpty)
    }

    func testEnrichmentGenuinelyUnmatchableIsConclusive() async {
        // Fetched fine but the series truly has no external id ⇒ skip conclusively
        // (don't force endless re-scans), and never fall back to a title match.
        let listHit = guidlessPlexSeries("p100", account: "plex")
        let result = await IdentityEnrichment.prepare([listHit]) { $0 } // returns it unchanged, still id-less
        XCTAssertFalse(result.inconclusive)
        XCTAssertTrue(result.indexable.isEmpty)
    }

    func testEnrichmentLeavesAlreadyIdentifiedItemsUntouched() async {
        // Items that already resolve to an identity must NOT trigger a fetch.
        let withID = series("p1", account: "plex", tvdb: "7")
        var fetched = false
        let result = await IdentityEnrichment.prepare([withID]) { item in fetched = true; return item }
        XCTAssertFalse(fetched, "No enrichment fetch for an item that already has a strong id")
        XCTAssertEqual(result.indexable.map(\.id), ["p1"])
    }

    func testEnrichmentNeverLoosensSeriesToTitle() async {
        // Even after a failed enrichment, a series must never resolve by title —
        // so two same-titled, differently-keyed shows can't false-merge.
        let listHit = guidlessPlexSeries("p100", account: "plex")
        let result = await IdentityEnrichment.prepare([listHit]) { _ in nil }
        XCTAssertTrue(result.indexable.isEmpty)
        // And a separately-enriched series with a real id keys only on that id.
        let enriched = await IdentityEnrichment.prepare([listHit]) { item in
            var full = item; full.providerIDs = ["Tvdb": "999"]; return full
        }
        XCTAssertEqual(
            MediaItemIdentity.identities(for: enriched.indexable[0]),
            [.external(source: "tvdb", value: "999")]
        )
    }

    /// After enrichment populates BOTH servers' series under the same strong id,
    /// the fan-out must be symmetric: a watch originating on Jellyfin reaches the
    /// (formerly guid-less) Plex copy, AND a watch originating on Plex reaches the
    /// Jellyfin copy. This is the both-directions guard for the observed
    /// Plex-as-destination gap.
    func testSymmetricFanOutToFormerlyGuidlessPlexSeries() async {
        let index = IdentityIndex()
        // Jellyfin series already carries the tvdb id.
        await index.ingest([series("j1", account: "jf", tvdb: "555")], accountID: "jf",
                           serverInfo: SourceServerInfo(providerKind: .jellyfin))
        // Plex series arrived guid-less; enrich before ingest (as indexAccount does).
        let plexListHit = guidlessPlexSeries("p1", account: "plex")
        let prepared = await IdentityEnrichment.prepare([plexListHit]) { item in
            var full = item; full.providerIDs = ["Tvdb": "555"]; return full
        }
        await index.ingest(prepared.indexable, accountID: "plex",
                          serverInfo: SourceServerInfo(providerKind: .plex))
        let snapshot = await index.snapshot()

        // Origin = Jellyfin → must include the Plex destination.
        let fromJF = series("j1", account: "jf", tvdb: "555")
        XCTAssertEqual(Set(snapshot.targets(for: fromJF).map(\.id)), ["jf:j1", "plex:p1"])
        // Origin = Plex → must include the Jellyfin destination (same set).
        let fromPlex = series("p1", account: "plex", tvdb: "555")
        XCTAssertEqual(Set(snapshot.targets(for: fromPlex).map(\.id)), ["jf:j1", "plex:p1"])
        // The series sources carry the kind so episode expansion can use them.
        XCTAssertTrue(snapshot.sources(for: fromPlex).allSatisfy { $0.kind == .series })
    }

    // MARK: Enrichment concurrency (bounded, order-independent batch)

    func testEnrichmentProcessesMixedPageConcurrently() async {
        // A realistic page: one already-identified series (no fetch), two guid-less
        // that enrich to real ids, one whose fetch fails (inconclusive), and one
        // that fetches but stays id-less (conclusive skip). Results arrive in any
        // order from the task group — the partition is by identity, not order.
        let identified = series("j1", account: "jf", tvdb: "100")
        let willEnrichA = guidlessPlexSeries("p1", account: "plex")
        let willEnrichB = guidlessPlexSeries("p2", account: "plex")
        let willFail = guidlessPlexSeries("p3", account: "plex")
        let unmatchable = guidlessPlexSeries("p4", account: "plex")

        let result = await IdentityEnrichment.prepare(
            [identified, willEnrichA, willEnrichB, willFail, unmatchable]
        ) { item in
            switch item.id {
            case "p1": var f = item; f.providerIDs = ["Tvdb": "201"]; return f
            case "p2": var f = item; f.providerIDs = ["Tvdb": "202"]; return f
            case "p3": return nil               // fetch failed → inconclusive
            default:   return item              // p4: fetched, still id-less
            }
        }

        XCTAssertTrue(result.inconclusive, "p3's failed fetch must mark the page inconclusive")
        XCTAssertEqual(
            Set(result.indexable.map(\.id)), ["j1", "p1", "p2"],
            "identified + both enriched survive; failed and unmatchable are excluded")
    }

    func testEnrichmentBoundsConcurrency() async {
        // With a cap of 2, no more than 2 enrichment fetches may be in flight at
        // once even on a large guid-less page — the bound is what keeps a cold-boot
        // scan from flooding the connection pool. Every item is still processed.
        actor Gauge {
            private var inFlight = 0
            private(set) var peak = 0
            func enter() { inFlight += 1; peak = max(peak, inFlight) }
            func leave() { inFlight -= 1 }
        }
        let gauge = Gauge()
        let items = (0..<12).map { guidlessPlexSeries("p\($0)", account: "plex") }

        let result = await IdentityEnrichment.prepare(items, concurrency: 2) { item in
            await gauge.enter()
            try? await Task.sleep(nanoseconds: 5_000_000) // 5ms so overlap is observable
            await gauge.leave()
            var f = item; f.providerIDs = ["Tvdb": item.id]; return f
        }

        let peak = await gauge.peak
        XCTAssertLessThanOrEqual(peak, 2, "concurrency cap must bound in-flight enrichment fetches")
        XCTAssertEqual(result.indexable.count, 12, "every item still enriched")
        XCTAssertFalse(result.inconclusive)
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
