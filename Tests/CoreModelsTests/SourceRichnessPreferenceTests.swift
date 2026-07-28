import XCTest
@testable import CoreModels

/// Coverage for choosing between two copies of the same title when one lives on a
/// managed server and the other on a plain file share.
///
/// A media server curates its library — cast, canonical titles, artwork. A share is
/// files on disk, and Plozz synthesises the rest, so the same show can arrive with
/// no cast and a folder-derived title. Silo opened from a share showed no cast at
/// all while the Plex copy carried 163 people.
final class SourceRichnessPreferenceTests: XCTestCase {

    private func source(
        _ accountID: String,
        kind: ProviderKind,
        locality: SourceLocality? = .local,
        versions: [MediaVersion] = []
    ) -> MediaSourceRef {
        MediaSourceRef(
            accountID: accountID,
            itemID: "item-\(accountID)",
            kind: .series,
            providerKind: kind,
            locality: locality,
            versions: versions
        )
    }

    private func item(
        _ id: String,
        accountID: String,
        providerKind: ProviderKind,
        cast: [MediaPerson] = []
    ) -> MediaItem {
        MediaItem(
            id: id,
            title: "Silo",
            kind: .series,
            people: cast,
            providerIDs: ["Tmdb": "125988"],
            sourceAccountID: accountID,
            sources: [source(accountID, kind: providerKind)]
        )
    }

    private let person = MediaPerson(id: "p1", name: "Rebecca Ferguson", role: "Juliette")

    // MARK: Which copy fronts a merged card

    func testAManagedServerFrontsTheCardOverAFileShare() {
        // Account order decided this before, so a share could front a title a server
        // also held — and the card then showed whatever was synthesised from
        // filenames rather than the server's curated record.
        let share = item("series:silo", accountID: "share", providerKind: .mediaShare)
        let plex = item("46124", accountID: "plex", providerKind: .plex, cast: [person])
        XCTAssertEqual(MediaItemMerger.richestMember(of: [share, plex]).id, "46124")
        XCTAssertEqual(MediaItemMerger.richestMember(of: [plex, share]).id, "46124")
    }

    func testJellyfinAndEmbyRankAlongsidePlex() {
        let share = item("series:silo", accountID: "share", providerKind: .mediaShare)
        for kind in [ProviderKind.jellyfin, .emby, .plex] {
            let server = item("server", accountID: "s", providerKind: kind)
            XCTAssertEqual(MediaItemMerger.richestMember(of: [share, server]).id, "server")
        }
    }

    func testAnEnrichedShareStillBeatsAServerCopyWithNothing() {
        // Backend tier dominates but isn't the only signal: a share that has been
        // enriched shouldn't lose to a server copy that somehow has no cast at all.
        let share = item("series:silo", accountID: "share", providerKind: .mediaShare, cast: [person])
        let bare = item("bare", accountID: "s", providerKind: .plex)
        XCTAssertEqual(MediaItemMerger.richestMember(of: [share, bare]).id, "bare",
                       "backend tier still dominates a single missing field")
    }

    func testTwoEqualCopiesKeepTheEarlierOne() {
        let first = item("a", accountID: "a", providerKind: .plex)
        let second = item("b", accountID: "b", providerKind: .plex)
        XCTAssertEqual(MediaItemMerger.richestMember(of: [first, second]).id, "a")
    }

    func testASingleMemberIsReturnedUnchanged() {
        let only = item("series:silo", accountID: "share", providerKind: .mediaShare)
        XCTAssertEqual(MediaItemMerger.richestMember(of: [only]).id, "series:silo")
    }

    // MARK: Playback selection

    func testLocalityStillOutranksBackendTier() {
        // The decisive guarantee: a local share is played from over a remote server.
        // A copy that plays instantly beats a richer one that buffers, so richness is
        // the LAST tie-break rather than an override.
        let localShare = source("share", kind: .mediaShare, locality: .local)
        let remotePlex = source("plex", kind: .plex, locality: .remote)
        let selection = CrossSourceSelector.bestSelection(
            from: [remotePlex, localShare],
            capabilities: MediaCapabilities()
        )
        XCTAssertEqual(selection?.source.accountID, "share")
    }

    func testAtEqualLocalityTheManagedServerIsSelected() {
        let localShare = source("share", kind: .mediaShare, locality: .local)
        let localPlex = source("plex", kind: .plex, locality: .local)
        let selection = CrossSourceSelector.bestSelection(
            from: [localShare, localPlex],
            capabilities: MediaCapabilities()
        )
        XCTAssertEqual(selection?.source.accountID, "plex")
    }
    // MARK: Ids survive whichever copy wins

    func testEveryMembersIDsSurviveWhenALaterCopyFronts() {
        // The union skipped index 0, which was safe only while the primary was
        // always the first member. Choosing by richness broke that: an anime shelf
        // with AniList ids on the share and TMDb ids on the server would silently
        // lose one side of its identity.
        var share = item("series:silo", accountID: "share", providerKind: .mediaShare)
        share.providerIDs = ["AniList": "12345"]
        var plex = item("46124", accountID: "plex", providerKind: .plex, cast: [person])
        plex.providerIDs = ["Tmdb": "125988"]

        let merged = MediaItemMerger.mergeGroup([share, plex])
        XCTAssertEqual(merged.id, "46124", "the server copy fronts the card")
        XCTAssertEqual(merged.providerIDs["Tmdb"], "125988")
        XCTAssertEqual(merged.providerIDs["AniList"], "12345", "the share's own id must survive")
    }

    func testTheMergedSourceListStillLeadsWithThePrimary() {
        // "Primary first" is relied on elsewhere: `sources.first` is the playback
        // picker's fallback "current server", and the selector prefers a lower index
        // at equal rank. Choosing the primary by metadata rather than position broke
        // that — the card fronted the server while the picker highlighted the share.
        let share = item("series:silo", accountID: "share", providerKind: .mediaShare)
        let plex = item("46124", accountID: "plex", providerKind: .plex, cast: [person])

        let merged = MediaItemMerger.mergeGroup([share, plex])
        XCTAssertEqual(merged.id, "46124")
        XCTAssertEqual(merged.sources.first?.accountID, "plex",
                       "the picker's default must agree with the card")
        XCTAssertEqual(Set(merged.sources.map(\.accountID)), ["plex", "share"],
                       "every server still appears")
    }

    func testMergingIsIdempotent() {
        // Re-merging an already-merged card must not reshuffle it.
        let share = item("series:silo", accountID: "share", providerKind: .mediaShare)
        let plex = item("46124", accountID: "plex", providerKind: .plex, cast: [person])
        let once = MediaItemMerger.mergeGroup([share, plex])
        let twice = MediaItemMerger.mergeGroup([once])
        XCTAssertEqual(twice.id, once.id)
        XCTAssertEqual(twice.sources.map(\.accountID), once.sources.map(\.accountID))
    }

}
