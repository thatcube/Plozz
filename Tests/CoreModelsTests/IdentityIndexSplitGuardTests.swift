import XCTest
@testable import CoreModels

/// Tests for the identity index's **split-guard**: when one server mis-tags a
/// *different* work with another title's strong external id, the transitive
/// membership walk must not fold that impostor into the anchor title's resolved
/// source set. Two real-world bugs this protects against: the movie "Scream 6
/// shows up as a version of Scream 7" false-merge (split on title/year), and the
/// series "One Piece 1999 anime collapses with the 2023 live-action" false-merge
/// (split on the large production-year gap). This is the index-layer twin of
/// `MediaItemMerger.refineComponent` — it protects the detail version picker,
/// best-source playback, and the watch fan-out, all of which resolve their servers
/// through `IdentityIndexSnapshot.sources(for:)`.
///
/// The guard is deliberately conservative (a false merge is worse than a missed
/// one): it only ejects a source that *positively contradicts* the anchor — a
/// different-titled movie whose year doesn't corroborate, or a series a large
/// production-year gap apart — and never splits on an absent signal (a movie with
/// no title, a series with no year) or a cross-kind pair.
final class IdentityIndexSplitGuardTests: XCTestCase {
    /// A movie the index would have ingested, carrying the title/year the guard
    /// compares. `tmdb` is the (possibly bad, shared) external id both films key on.
    private func indexedMovie(
        _ account: String,
        _ itemID: String,
        title: String,
        year: Int?,
        provider: ProviderKind = .plex
    ) -> IndexedSource {
        IndexedSource(
            accountID: account,
            itemID: itemID,
            providerKind: provider,
            kind: .movie,
            normalizedTitle: MediaItemIdentity.normalizedTitle(title),
            year: year
        )
    }

    private func probe(_ account: String, _ itemID: String, title: String, year: Int?, tmdb: String) -> MediaItem {
        var item = MediaItem(id: itemID, title: title, kind: .movie, productionYear: year, providerIDs: ["Tmdb": tmdb])
        item.sourceAccountID = account
        return item
    }

    // MARK: - Recovered external id suppresses the title fallback (rule #1)

    func testRecoveredExternalIDSuppressesTitleFallbackBridge() {
        // An id-less loaded Plex row ("Crash" 2004, no Guid in the list payload)
        // whose index entry was enriched to a strong tmdb id. A *different* film
        // that merely shares the same normalized title + year is id-less in the
        // index (indexed only under `.title`). Recovering the row's external id must
        // suppress its title fallback (rule #1) so the walk resolves the row via its
        // catalogue id ONLY — never bridging through the shared title into the
        // unrelated same-title/year film (a false merge + mis-targeted watch write).
        let realID = MediaIdentity.external(source: "tmdb", value: "1640") // real Crash (2004)
        let rowIndexed = indexedMovie("plexA", "crashA", title: "Crash", year: 2004, provider: .plex)
        let realTwin = indexedMovie("jf", "crashJF", title: "Crash", year: 2004, provider: .jellyfin)
        // A genuinely different, id-less film sharing the title/year, on a 3rd server.
        let impostor = indexedMovie("plexB", "crashB", title: "Crash", year: 2004, provider: .plex)
        let snapshot = IdentityIndexSnapshot(byIdentity: [
            realID: [rowIndexed, realTwin],
            .title(normalizedTitle: MediaItemIdentity.normalizedTitle("Crash"), year: 2004, kind: .movie): [impostor]
        ])

        // The loaded row carries NO external id in its payload (Plex omitted Guid).
        var idlessRow = MediaItem(id: "crashA", title: "Crash", kind: .movie, productionYear: 2004)
        idlessRow.sourceAccountID = "plexA"

        let refs = Set(snapshot.sourceRefs(for: idlessRow).map(\.id))
        XCTAssertTrue(refs.contains("jf:crashJF"), "The recovered external id must still merge the legit twin")
        XCTAssertFalse(refs.contains("plexB:crashB"), "The title fallback must not bridge in a different same-title/year film once a strong id is recovered")
        XCTAssertEqual(refs, ["plexA:crashA", "jf:crashJF"])
    }

    // MARK: - The Scream 6 / Scream 7 false-merge

    func testDifferentMoviesSharingBadExternalIDAreSplitAtIndex() {
        // Both films are indexed under the SAME (wrong) tmdb id: one server tagged
        // Scream 7 with Scream 6's id.
        let sharedID = MediaIdentity.external(source: "tmdb", value: "934433")
        let scream7 = indexedMovie("plex", "s7", title: "Scream 7", year: 2026, provider: .plex)
        let scream6 = indexedMovie("jf", "s6", title: "Scream 6", year: 2023, provider: .jellyfin)
        let snapshot = IdentityIndexSnapshot(byIdentity: [sharedID: [scream7, scream6]])

        // Resolving from Scream 7's perspective returns ONLY Scream 7's server.
        let s7Refs = snapshot.sourceRefs(for: probe("plex", "s7", title: "Scream 7", year: 2026, tmdb: "934433"))
        XCTAssertEqual(Set(s7Refs.map(\.id)), ["plex:s7"], "Scream 6 must not appear as a source of Scream 7")

        // And symmetrically from Scream 6's perspective.
        let s6Refs = snapshot.sourceRefs(for: probe("jf", "s6", title: "Scream 6", year: 2023, tmdb: "934433"))
        XCTAssertEqual(Set(s6Refs.map(\.id)), ["jf:s6"], "Scream 7 must not appear as a source of Scream 6")
    }

    func testImpostorReachableOnlyThroughBadIDDoesNotLeakTransitively() {
        // Anchor S7 shares the bad id with S6. S6 ALSO carries its own imdb id that
        // links to a second Scream 6 copy on a third server. The walk must not
        // traverse THROUGH the ejected S6 to pull in that third copy.
        let badTmdb = MediaIdentity.external(source: "tmdb", value: "934433")
        let scream6Imdb = MediaIdentity.external(source: "imdb", value: "tt17663992")
        let s7 = indexedMovie("plex", "s7", title: "Scream 7", year: 2026)
        let s6a = indexedMovie("jf", "s6a", title: "Scream 6", year: 2023, provider: .jellyfin)
        let s6b = indexedMovie("emby", "s6b", title: "Scream 6", year: 2023, provider: .jellyfin)
        let snapshot = IdentityIndexSnapshot(byIdentity: [
            badTmdb: [s7, s6a],
            scream6Imdb: [s6a, s6b]
        ])
        let refs = snapshot.sourceRefs(for: probe("plex", "s7", title: "Scream 7", year: 2026, tmdb: "934433"))
        XCTAssertEqual(Set(refs.map(\.id)), ["plex:s7"], "Neither Scream 6 copy may leak into Scream 7")
    }

    // MARK: - Legit merges the guard must NOT break

    func testLocalizedTitleTwinWithMatchingYearStaysMerged() {
        // Same film on two servers, one stored under a localized title, same year:
        // the matching year rescues the shared id despite the different titles.
        let sharedID = MediaIdentity.external(source: "tmdb", value: "603")
        let english = indexedMovie("plex", "m-en", title: "The Matrix", year: 1999)
        let german = indexedMovie("jf", "m-de", title: "Matrix", year: 1999, provider: .jellyfin)
        let snapshot = IdentityIndexSnapshot(byIdentity: [sharedID: [english, german]])
        let refs = snapshot.sourceRefs(for: probe("plex", "m-en", title: "The Matrix", year: 1999, tmdb: "603"))
        XCTAssertEqual(Set(refs.map(\.id)), ["jf:m-de", "plex:m-en"], "A same-year localized twin must stay merged")
    }

    func testEditionSuffixTwinStaysMerged() {
        // "Dune" vs "Dune (2021)" — prefix compatible, so never split even if a
        // year were absent.
        let sharedID = MediaIdentity.external(source: "tmdb", value: "438631")
        let bare = indexedMovie("plex", "d1", title: "Dune", year: 2021)
        let annotated = indexedMovie("jf", "d2", title: "Dune 2021", year: nil, provider: .jellyfin)
        let snapshot = IdentityIndexSnapshot(byIdentity: [sharedID: [bare, annotated]])
        let refs = snapshot.sourceRefs(for: probe("plex", "d1", title: "Dune", year: 2021, tmdb: "438631"))
        XCTAssertEqual(Set(refs.map(\.id)), ["jf:d2", "plex:d1"])
    }

    func testSparseTwinWithNoStoredTitleIsNotSplit() {
        // A source indexed before the title/year fields existed (nil title) must
        // never be ejected — absent signal is not a contradiction.
        let sharedID = MediaIdentity.external(source: "tmdb", value: "550")
        let anchor = indexedMovie("plex", "f1", title: "Fight Club", year: 1999)
        let sparse = IndexedSource(accountID: "jf", itemID: "f2", providerKind: .jellyfin, kind: .movie)
        let snapshot = IdentityIndexSnapshot(byIdentity: [sharedID: [anchor, sparse]])
        let refs = snapshot.sourceRefs(for: probe("plex", "f1", title: "Fight Club", year: 1999, tmdb: "550"))
        XCTAssertEqual(Set(refs.map(\.id)), ["jf:f2", "plex:f1"], "A title-less legacy source must not be split")
    }

    func testTitlelessAnchorLeavesUnionUnguarded() {
        // If the PROBE item has no usable title, we have nothing to contradict
        // against, so the union is returned whole (prior behaviour) rather than
        // guessing.
        let sharedID = MediaIdentity.external(source: "tmdb", value: "934433")
        let s7 = indexedMovie("plex", "s7", title: "Scream 7", year: 2026)
        let s6 = indexedMovie("jf", "s6", title: "Scream 6", year: 2023, provider: .jellyfin)
        let snapshot = IdentityIndexSnapshot(byIdentity: [sharedID: [s7, s6]])
        var titleless = MediaItem(id: "s7", title: "", kind: .movie, productionYear: nil, providerIDs: ["Tmdb": "934433"])
        titleless.sourceAccountID = "plex"
        let refs = snapshot.sourceRefs(for: titleless)
        XCTAssertEqual(Set(refs.map(\.id)), ["jf:s6", "plex:s7"], "No anchor title ⇒ unguarded union")
    }

    // MARK: - Reconciler's raw-identity fan-out path

    func testSourcesForIdentitiesWithAnchorSplitsBadID() {
        // The watch reconciler expands a movie mutation by RAW identities + kind +
        // the persisted anchor (it has no MediaItem at drain time). This is the
        // exact call `WatchMutationApplier.expandIdentityTargets` makes.
        let sharedID = MediaIdentity.external(source: "tmdb", value: "934433")
        let s7 = indexedMovie("plex", "s7", title: "Scream 7", year: 2026)
        let s6 = indexedMovie("jf", "s6", title: "Scream 6", year: 2023, provider: .jellyfin)
        let snapshot = IdentityIndexSnapshot(byIdentity: [sharedID: [s7, s6]])

        let guarded = snapshot.sources(
            forIdentities: [sharedID],
            kind: .movie,
            anchorTitle: MediaItemIdentity.normalizedTitle("Scream 7"),
            anchorYear: 2026
        )
        XCTAssertEqual(Set(guarded.map(\.id)), ["plex:s7"], "Watch fan-out must not target Scream 6")

        // A nil anchor (legacy mutation) keeps the prior unguarded union so a queued
        // write is never silently narrowed.
        let unguarded = snapshot.sources(forIdentities: [sharedID], kind: .movie, anchorTitle: nil, anchorYear: nil)
        XCTAssertEqual(Set(unguarded.map(\.id)), ["jf:s6", "plex:s7"])
    }

    // MARK: - ingest populates the guard fields

    func testIngestStoresNormalizedTitleAndYear() async {
        let index = IdentityIndex()
        var s7 = MediaItem(id: "s7", title: "Scream 7", kind: .movie, productionYear: 2026, providerIDs: ["Tmdb": "934433"])
        s7.sourceAccountID = "plex"
        var s6 = MediaItem(id: "s6", title: "Scream 6", kind: .movie, productionYear: 2023, providerIDs: ["Tmdb": "934433"])
        s6.sourceAccountID = "jf"
        await index.ingest([s7], accountID: "plex")
        await index.ingest([s6], accountID: "jf")
        let snapshot = await index.snapshot()

        // The bad shared id would fold both together without the stored title/year;
        // with them, each resolves only its own server.
        var probe7 = MediaItem(id: "s7", title: "Scream 7", kind: .movie, productionYear: 2026, providerIDs: ["Tmdb": "934433"])
        probe7.sourceAccountID = "plex"
        XCTAssertEqual(Set(snapshot.sourceRefs(for: probe7).map(\.id)), ["plex:s7"])
    }

    // MARK: - Series split-guard (One Piece anime vs live-action)

    private func indexedSeries(
        _ account: String,
        _ itemID: String,
        title: String,
        year: Int?,
        provider: ProviderKind = .plex
    ) -> IndexedSource {
        IndexedSource(
            accountID: account,
            itemID: itemID,
            providerKind: provider,
            kind: .series,
            normalizedTitle: MediaItemIdentity.normalizedTitle(title),
            year: year
        )
    }

    private func seriesProbe(_ account: String, _ itemID: String, title: String, year: Int?, tvdb: String) -> MediaItem {
        var item = MediaItem(id: itemID, title: title, kind: .series, productionYear: year, providerIDs: ["Tvdb": tvdb])
        item.sourceAccountID = account
        return item
    }

    func testSeriesSharingBadExternalIDWithLargeYearGapAreSplitAtIndex() {
        // One server tags the 2023 live-action "One Piece" with the 1999 anime's
        // TVDb id. The index-layer guard must resolve each to only its own server so
        // the detail version picker / best-source play / watch fan-out never cross
        // the anime with the live-action.
        let sharedID = MediaIdentity.external(source: "tvdb", value: "81797")
        let anime = indexedSeries("plex", "op-anime", title: "One Piece", year: 1999, provider: .plex)
        let live = indexedSeries("jf", "op-live", title: "One Piece", year: 2023, provider: .jellyfin)
        let snapshot = IdentityIndexSnapshot(byIdentity: [sharedID: [anime, live]])

        let animeRefs = snapshot.sourceRefs(for: seriesProbe("plex", "op-anime", title: "One Piece", year: 1999, tvdb: "81797"))
        XCTAssertEqual(Set(animeRefs.map(\.id)), ["plex:op-anime"], "Live-action must not appear as a source of the anime")

        let liveRefs = snapshot.sourceRefs(for: seriesProbe("jf", "op-live", title: "One Piece", year: 2023, tvdb: "81797"))
        XCTAssertEqual(Set(liveRefs.map(\.id)), ["jf:op-live"], "Anime must not appear as a source of the live-action")
    }

    func testSameYearSeriesTwinStaysMergedAtIndex() {
        // A genuinely-shared series stored under a localized/"(Subtitled)" title on
        // one server, SAME debut year: the guard keys off year, so gap 0 keeps the
        // two servers merged into one picker.
        let sharedID = MediaIdentity.external(source: "tvdb", value: "81797")
        let a = indexedSeries("plex", "op-a", title: "One Piece", year: 1999)
        let b = indexedSeries("jf", "op-b", title: "ONE PIECE (Subtitled)", year: 1999, provider: .jellyfin)
        let snapshot = IdentityIndexSnapshot(byIdentity: [sharedID: [a, b]])
        let refs = snapshot.sourceRefs(for: seriesProbe("plex", "op-a", title: "One Piece", year: 1999, tvdb: "81797"))
        XCTAssertEqual(Set(refs.map(\.id)), ["jf:op-b", "plex:op-a"], "A same-year series twin must stay merged")
    }

    func testYearlessSeriesAnchorLeavesUnionUnguardedAtIndex() {
        // The series guard needs a year on the anchor to measure the large gap; with
        // none we can't confidently contradict, so return the union whole (prior
        // behaviour) rather than guess.
        let sharedID = MediaIdentity.external(source: "tvdb", value: "81797")
        let anime = indexedSeries("plex", "op-anime", title: "One Piece", year: 1999)
        let live = indexedSeries("jf", "op-live", title: "One Piece", year: 2023, provider: .jellyfin)
        let snapshot = IdentityIndexSnapshot(byIdentity: [sharedID: [anime, live]])
        let refs = snapshot.sourceRefs(for: seriesProbe("plex", "op-anime", title: "One Piece", year: nil, tvdb: "81797"))
        XCTAssertEqual(Set(refs.map(\.id)), ["jf:op-live", "plex:op-anime"], "No anchor year ⇒ unguarded union")
    }

    func testSeriesWatchFanoutSplitsBadIDViaAnchor() {
        // The watch reconciler expands a series mutation by RAW identities + kind +
        // the persisted anchor year (no MediaItem at drain time). A large-gap
        // impostor riding the shared id must not become a fan-out target.
        let sharedID = MediaIdentity.external(source: "tvdb", value: "81797")
        let anime = indexedSeries("plex", "op-anime", title: "One Piece", year: 1999)
        let live = indexedSeries("jf", "op-live", title: "One Piece", year: 2023, provider: .jellyfin)
        let snapshot = IdentityIndexSnapshot(byIdentity: [sharedID: [anime, live]])

        let guarded = snapshot.sources(
            forIdentities: [sharedID],
            kind: .series,
            anchorTitle: MediaItemIdentity.normalizedTitle("One Piece"),
            anchorYear: 1999
        )
        XCTAssertEqual(Set(guarded.map(\.id)), ["plex:op-anime"], "Watch fan-out must not target the live-action")
    }
}
