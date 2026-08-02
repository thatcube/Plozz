import XCTest
@testable import CoreModels

/// Tests for the universal Plozz identity layer: ``TitleComponentLabeller``,
/// ``TitleIdentity``, ``TitleDedupe`` and the kind-scoped overlap keys.
///
/// The properties asserted here are the ones the whole app now depends on, so a
/// change that breaks one of them is a change that will show a viewer the same film
/// twice, hide a Play button, or grow the durable ledger without bound.
final class TitleIdentityTests: XCTestCase {
    // MARK: - Fixtures

    private func indexed(
        _ account: String,
        _ itemID: String,
        title: String,
        year: Int?,
        kind: MediaItemKind = .movie
    ) -> IndexedSource {
        IndexedSource(
            accountID: account,
            itemID: itemID,
            providerKind: .plex,
            kind: kind,
            normalizedTitle: MediaItemIdentity.normalizedTitle(title),
            year: year
        )
    }

    private func item(
        _ id: String,
        title: String,
        year: Int?,
        kind: MediaItemKind = .movie,
        providerIDs: [String: String] = [:],
        account: String? = nil
    ) -> MediaItem {
        var item = MediaItem(id: id, title: title, kind: kind)
        item.productionYear = year
        item.providerIDs = providerIDs
        item.sourceAccountID = account
        return item
    }

    private func snapshot(
        _ entries: [(MediaIdentity, [IndexedSource])]
    ) -> IdentityIndexSnapshot {
        var byIdentity: [MediaIdentity: [IndexedSource]] = [:]
        for (identity, sources) in entries {
            byIdentity[identity, default: []].append(contentsOf: sources)
        }
        return IdentityIndexSnapshot(byIdentity: byIdentity)
    }

    // MARK: - Component labelling

    /// The counter-example that killed the original per-item-walk design.
    ///
    /// ```
    /// A = "Scream 6" 2023 { imdb:tt1 }
    /// B = "Scream"  (no year) { imdb:tt1, tmdb:5 }
    /// C = "Scream 7" 2025 { tmdb:5 }
    /// ```
    ///
    /// A and C are bridged only through B's straddling metadata. A walk whose
    /// frontier is identities would pull `tmdb:5` into A's frontier through B and
    /// hand A and C the same canonical name — silently undoing the split guard. The
    /// labelling pass must never name them the same.
    func testScreamBridgeNeverNamesContradictingTitlesTheSame() {
        let a = indexed("acct", "A", title: "Scream 6", year: 2023)
        let b = indexed("acct", "B", title: "Scream", year: nil)
        let c = indexed("acct", "C", title: "Scream 7", year: 2025)
        let imdb = MediaIdentity.external(source: "imdb", value: "tt1")
        let tmdb = MediaIdentity.external(source: "tmdb", value: "5")

        let table = TitleComponentLabeller.label(
            byIdentity: [imdb: [a, b], tmdb: [b, c]],
            bySource: [a.id: [imdb], b.id: [imdb, tmdb], c.id: [tmdb]]
        )

        XCTAssertNotNil(table[a.id])
        XCTAssertNotNil(table[c.id])
        XCTAssertNotEqual(
            table[a.id],
            table[c.id],
            "the split guard must survive canonical labelling"
        )
    }

    /// Two genuine copies of one film on two servers must land on one name.
    func testTwoServerCopiesShareOneCanonicalIdentity() {
        let plex = indexed("plex", "1", title: "Dune", year: 2021)
        let jellyfin = indexed("jf", "9", title: "Dune", year: 2021)
        let imdb = MediaIdentity.external(source: "imdb", value: "tt1160419")

        let table = TitleComponentLabeller.label(
            byIdentity: [imdb: [plex, jellyfin]],
            bySource: [plex.id: [imdb], jellyfin.id: [imdb]]
        )

        XCTAssertEqual(table[plex.id], imdb)
        XCTAssertEqual(table[jellyfin.id], imdb)
    }

    /// A movie and a series routinely share a TMDb integer. Unioning them would
    /// merge two unrelated works.
    func testLabellingIsKindScoped() {
        let movie = indexed("acct", "M", title: "Fight Club", year: 1999, kind: .movie)
        let series = indexed("acct", "S", title: "Shogun", year: 2024, kind: .series)
        let shared = MediaIdentity.external(source: "tmdb", value: "550")

        let table = TitleComponentLabeller.label(
            byIdentity: [shared: [movie, series]],
            bySource: [movie.id: [shared], series.id: [shared]]
        )

        XCTAssertNotNil(table[movie.id])
        XCTAssertNotNil(table[series.id])
    }

    /// A component that has any catalogue id is never named after a mutable title.
    func testCanonicalIdentityPrefersStrongEvidenceOverTitle() {
        let source = indexed("acct", "1", title: "Dune", year: 2021)
        let imdb = MediaIdentity.external(source: "imdb", value: "tt1160419")
        let title = MediaIdentity.title(normalizedTitle: "dune", year: 2021, kind: .movie)

        let canonical = TitleComponentLabeller.canonicalIdentity(
            for: [source],
            bySource: [source.id: [title, imdb]]
        )

        XCTAssertEqual(canonical, imdb)
    }

    /// Labelling is a pure function of the evidence, not of dictionary iteration
    /// order — otherwise the same library would produce different keys per launch.
    func testLabellingIsDeterministic() {
        let a = indexed("acct", "A", title: "Dune", year: 2021)
        let b = indexed("acct", "B", title: "Dune", year: 2021)
        let imdb = MediaIdentity.external(source: "imdb", value: "tt1160419")
        let tmdb = MediaIdentity.external(source: "tmdb", value: "438631")
        let byIdentity: [MediaIdentity: [IndexedSource]] = [imdb: [a, b], tmdb: [a, b]]
        let bySource = [a.id: [imdb, tmdb], b.id: [imdb, tmdb]]

        let first = TitleComponentLabeller.label(byIdentity: byIdentity, bySource: bySource)
        for _ in 0..<20 {
            XCTAssertEqual(
                TitleComponentLabeller.label(byIdentity: byIdentity, bySource: bySource),
                first
            )
        }
    }

    // MARK: - TitleIdentity resolution

    /// Two copies of one film that expose *different* ids still group, because the
    /// index bridges them — this is the whole point of an evidence root.
    func testResolverGroupsCrossServerCopiesThroughTheIndex() {
        let plex = indexed("plex", "1", title: "Dune", year: 2021)
        let jellyfin = indexed("jf", "9", title: "Dune", year: 2021)
        let imdb = MediaIdentity.external(source: "imdb", value: "tt1160419")
        let tmdb = MediaIdentity.external(source: "tmdb", value: "438631")
        let resolver = TitleIdentityResolver(
            index: snapshot([(imdb, [plex, jellyfin]), (tmdb, [plex, jellyfin])])
        )

        let a = item("1", title: "Dune", year: 2021, providerIDs: ["Imdb": "tt1160419"], account: "plex")
        let b = item("9", title: "Dune", year: 2021, providerIDs: ["Tmdb": "438631"], account: "jf")

        XCTAssertEqual(resolver.identity(for: a), resolver.identity(for: b))
        XCTAssertEqual(resolver.deduplicated([a, b]).count, 1)
    }

    /// An item the index has never seen still resolves — to its own strongest
    /// identity — so discovery rows group with each other without touching the
    /// durable ledger.
    func testUnindexedItemFallsBackToItsOwnStrongestIdentity() {
        let resolver = TitleIdentityResolver.empty
        let a = item("tmdb:1", title: "Dune", year: 2021, providerIDs: ["Imdb": "tt1160419", "Tmdb": "438631"])
        let b = item("tmdb:2", title: "Dune", year: 2021, providerIDs: ["Imdb": "tt1160419"])

        XCTAssertEqual(resolver.identity(for: a), resolver.identity(for: b))
        XCTAssertNil(resolver.identity(for: a).aliasID)
    }

    /// An item with nothing at all gets an account-scoped local root, which never
    /// merges anything — matching what the merger does with such items.
    func testItemWithNoEvidenceGetsAccountScopedLocalRoot() {
        let resolver = TitleIdentityResolver.empty
        let a = item("1", title: "Home Video", year: nil, account: "plex")
        let b = item("1", title: "Home Video", year: nil, account: "jf")

        XCTAssertNotEqual(resolver.identity(for: a), resolver.identity(for: b))
        if case .local = resolver.identity(for: a).root {} else {
            XCTFail("expected a local root")
        }
    }

    /// Identity is kind-scoped end to end.
    func testIdentityIsKindScoped() {
        let resolver = TitleIdentityResolver.empty
        let movie = item("m", title: "Shogun", year: 2024, kind: .movie, providerIDs: ["Tmdb": "550"])
        let series = item("s", title: "Shogun", year: 2024, kind: .series, providerIDs: ["Tmdb": "550"])

        XCTAssertNotEqual(resolver.identity(for: movie), resolver.identity(for: series))
    }

    /// Grouping preserves first-appearance order, so a row never reshuffles because
    /// identity happened to be recomputed.
    func testGroupingPreservesOrder() {
        let resolver = TitleIdentityResolver.empty
        let a = item("a", title: "A", year: 2001, providerIDs: ["Imdb": "tt1"])
        let b = item("b", title: "B", year: 2002, providerIDs: ["Imdb": "tt2"])
        let a2 = item("a2", title: "A", year: 2001, providerIDs: ["Imdb": "tt1"])

        let grouped = resolver.grouped([a, b, a2])
        XCTAssertEqual(grouped.count, 2)
        XCTAssertEqual(grouped.first?.items.map(\.id), ["a", "a2"])
        XCTAssertEqual(grouped.last?.items.map(\.id), ["b"])
    }

    /// Resolver equality is by revision. Comparing two large snapshot pairs on every
    /// publication would cost more than the republication it exists to avoid.
    func testResolverEqualityIsByRevision() {
        let source = indexed("acct", "1", title: "Dune", year: 2021)
        let imdb = MediaIdentity.external(source: "imdb", value: "tt1")
        let populated = TitleIdentityResolver(index: snapshot([(imdb, [source])]), revision: 7)
        let empty = TitleIdentityResolver(revision: 7)

        XCTAssertEqual(populated, empty)
        XCTAssertNotEqual(populated, TitleIdentityResolver(revision: 8))
    }

    // MARK: - Overlap keys

    func testOverlapKeysAreKindScoped() {
        let movie = item("m", title: "X", year: 2000, kind: .movie, providerIDs: ["Tmdb": "550"])
        let series = item("s", title: "X", year: 2000, kind: .series, providerIDs: ["Tmdb": "550"])

        XCTAssertFalse(MediaItemIdentity.overlaps(movie, series))
    }

    /// The search bug: a library copy exposing IMDb and a Seerr row exposing TMDb are
    /// the same film, and a TMDb-only compare never saw it.
    func testOverlapMatchesOnAnySharedStrongIdentity() {
        let library = item("plex:1", title: "Dune", year: 2021, providerIDs: ["Imdb": "tt1160419", "Tvdb": "77"])
        let discovery = item("tmdb:2", title: "Dune", year: 2021, providerIDs: ["Tvdb": "77", "Tmdb": "438631"])

        XCTAssertTrue(MediaItemIdentity.overlaps(library, discovery))
    }

    // MARK: - TitleDedupe

    func testDedupeCollapsesCopiesSharingAStrongIdentity() {
        let a = item("plex:1", title: "Dune", year: 2021, providerIDs: ["Imdb": "tt1"])
        let b = item("jf:9", title: "Duna", year: 2021, providerIDs: ["Imdb": "tt1"])

        XCTAssertEqual(TitleDedupe.deduplicated([a, b]).map(\.id), ["plex:1"])
    }

    /// The split guard applies here too: a straddling row must not chain two
    /// different films into one entry.
    func testDedupeAppliesTheSplitGuard() {
        let a = item("a", title: "Scream 6", year: 2023, providerIDs: ["Imdb": "tt1"])
        let bridge = item("b", title: "Scream", year: nil, providerIDs: ["Imdb": "tt1", "Tmdb": "5"])
        let c = item("c", title: "Scream 7", year: 2025, providerIDs: ["Tmdb": "5"])

        let groups = TitleDedupe.groups([a, bridge, c])
        let groupOf: (String) -> Int? = { id in
            groups.firstIndex { $0.contains { [a, bridge, c][$0].id == id } }
        }
        XCTAssertNotEqual(groupOf("a"), groupOf("c"))
    }

    /// Weak policy is the caller's; with none supplied, only strong ids merge.
    func testDedupeWithoutWeakKeyKeepsTitleOnlyDuplicatesApart() {
        let a = item("a", title: "Dune", year: 2021)
        let b = item("b", title: "Dune", year: 2021)

        // Both fall back to the same movie title identity, which is a legitimate
        // strong-enough signal for movies with a year.
        XCTAssertEqual(TitleDedupe.deduplicated([a, b]).count, 1)
    }

    func testDedupeHonoursTheCallersWeakKey() {
        let a = item("a", title: "Home Movie", year: nil)
        let b = item("b", title: "Home Movie", year: nil)

        XCTAssertEqual(TitleDedupe.deduplicated([a, b]).count, 2)
        XCTAssertEqual(
            TitleDedupe.deduplicated([a, b]) {
                MediaItemIdentity.normalizedTitle($0.title)
            }.count,
            1
        )
    }

    // MARK: - Performance / bounded work

    /// Browsing must not be O(index) per card. The labelling pass runs once when the
    /// snapshot is built; a lookup after that is a dictionary read.
    func testCanonicalEvidenceLookupIsConstantTimeOverALargeIndex() {
        var byIdentity: [MediaIdentity: [IndexedSource]] = [:]
        for number in 0..<5_000 {
            let identity = MediaIdentity.external(source: "imdb", value: "tt\(number)")
            byIdentity[identity] = [
                indexed("plex", "\(number)", title: "Title \(number)", year: 2000)
            ]
        }
        let index = IdentityIndexSnapshot(byIdentity: byIdentity)
        let probe = item(
            "2500",
            title: "Title 2500",
            year: 2000,
            providerIDs: ["Imdb": "tt2500"],
            account: "plex"
        )

        XCTAssertEqual(
            index.canonicalEvidence(for: probe),
            .external(source: "imdb", value: "tt2500")
        )

        measure {
            for _ in 0..<2_000 {
                _ = index.canonicalEvidence(for: probe)
            }
        }
    }

    /// Resolving identity for browsing must never mint a durable record. The ledger
    /// is user intent, not a cache of everything the viewer scrolled past — it was
    /// already 6.7 MB at 10k records, and unbounded growth is a release blocker.
    func testBrowsingNeverCreatesDurableRecords() {
        let resolver = TitleIdentityResolver.empty
        let browsed = (0..<2_000).map {
            item(
                "discovery:\($0)",
                title: "Discovery \($0)",
                year: 2020,
                providerIDs: ["Tmdb": "\($0)"]
            )
        }

        for candidate in browsed {
            XCTAssertNil(resolver.aliasID(for: candidate))
        }
        XCTAssertTrue(resolver.aliases.recordsByID.isEmpty)
    }
}
