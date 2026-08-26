import XCTest
@testable import CoreModels

/// Direct coverage for `retargetedToOwnedLibraryCopy`, the seam that decides
/// whether a discovery row the viewer turns out to OWN gets rewritten onto their
/// real library copy. It had no tests at all, which is how issue #33 survived:
/// the gate rejected an id the identity index was already happily keying by.
final class LibraryRetargetTests: XCTestCase {
    private let plexGuid = "plex://movie/5d776b9ad0b3f4001f3a2b1d"

    /// The shape a Plex **Watchlist** row arrives in for a title Discover could not
    /// match to IMDb/TMDb/TVDb — anime, foreign, or a locally-matched film. The
    /// Discover fetch omits the external `Guid` array, so the global guid is the
    /// ONLY id present, and `PlexProvider.watchlist()` stamps it unvalidated.
    private func watchlistRow(
        kind: MediaItemKind = .movie,
        providerIDs: [String: String]? = nil
    ) -> MediaItem {
        MediaItem(
            id: "5d776b9ad0b3f4001f3a2b1d",
            title: "Perfect Blue",
            kind: kind,
            providerIDs: providerIDs ?? ["PlexGuid": plexGuid],
            availability: .unknown,
            locallyValidatedPlayableSource: false
        )
    }

    private func ownedCopy(kind: MediaItemKind? = .movie) -> MediaSourceRef {
        MediaSourceRef(accountID: "plex-account", itemID: "51234", libraryID: "1", kind: kind)
    }

    // MARK: - The regression itself

    /// Issue #33. `MediaItemIdentity.identities(for:)` deliberately keys the index
    /// by a bare PlexGuid, calling it strong and server-independent — but the
    /// retarget gate consulted only `strongExternalNamespaces`, which excludes it,
    /// and bailed before `indexedSources` was ever called. The viewer's own copy
    /// was sitting in the index the whole time.
    func testPlexGuidOnlyRowRetargetsOntoTheOwnedCopy() throws {
        let resolved = watchlistRow().retargetedToOwnedLibraryCopy(
            indexedSources: { _ in [self.ownedCopy()] }
        )
        let item = try XCTUnwrap(resolved, "a PlexGuid-only row must be able to bind to an owned copy")
        XCTAssertTrue(item.locallyValidatedPlayableSource)
        // Availability described the metadata provider's view, not the copy the
        // index just vouched for — keeping it would leave the item claiming both.
        XCTAssertNil(item.availability)
        XCTAssertEqual(item.sources.first?.itemID, "51234")
    }

    /// And the payoff: once bound, the detail page stops rendering the request
    /// layout, because this is the exact predicate `ItemDetailView` gates Play on.
    func testRetargetedRowReportsAPlayableLibraryTarget() {
        XCTAssertFalse(
            watchlistRow().hasPlayableLibraryTarget(),
            "precondition: unbound, it has nothing to play"
        )
        let resolved = watchlistRow().retargetedToOwnedLibraryCopy(
            indexedSources: { _ in [self.ownedCopy()] }
        )
        XCTAssertEqual(resolved?.hasPlayableLibraryTarget(), true)
    }

    // MARK: - The guards that must NOT relax

    /// A title/year-only row still refuses. Being wrong here doesn't mislabel a
    /// card, it routes playback to a different work.
    func testRowWithNoStrongIDRefusesToRetarget() {
        let weak = watchlistRow(providerIDs: [:])
        XCTAssertNil(weak.retargetedToOwnedLibraryCopy(indexedSources: { _ in [self.ownedCopy()] }))
    }

    /// An empty/whitespace guid is not an id.
    func testBlankPlexGuidIsNotAStrongIdentity() {
        let blank = watchlistRow(providerIDs: ["PlexGuid": "   "])
        XCTAssertNil(blank.retargetedToOwnedLibraryCopy(indexedSources: { _ in [self.ownedCopy()] }))
    }

    /// Kind scoping still holds. The index is asked for the item's own kind, and a
    /// series-kinded source must never satisfy a movie row.
    func testKindMismatchedSourceIsRejected() {
        let resolved = watchlistRow().retargetedToOwnedLibraryCopy(
            indexedSources: { _ in [self.ownedCopy(kind: .series)] }
        )
        XCTAssertNil(resolved)
    }

    /// An untyped ref is still accepted — it carries no contradiction.
    func testUntypedSourceIsAccepted() {
        let resolved = watchlistRow().retargetedToOwnedLibraryCopy(
            indexedSources: { _ in [self.ownedCopy(kind: nil)] }
        )
        XCTAssertNotNil(resolved)
    }

    /// An ordinary library item is already pointed at its own server and must be
    /// left exactly as it is.
    func testOrdinaryLibraryItemIsNeverRetargeted() {
        let owned = MediaItem(
            id: "51234",
            title: "Perfect Blue",
            kind: .movie,
            providerIDs: ["PlexGuid": plexGuid]
        )
        XCTAssertNil(owned.retargetedToOwnedLibraryCopy(indexedSources: { _ in [self.ownedCopy()] }))
    }

    /// An index that knows nothing about the title cannot manufacture ownership.
    func testEmptyIndexLeavesTheRowAlone() {
        XCTAssertNil(watchlistRow().retargetedToOwnedLibraryCopy(indexedSources: { _ in [] }))
    }

    // MARK: - The predicate itself

    func testStrongRetargetIdentityAcceptsPlexGuidAndRealExternalIDs() {
        XCTAssertTrue(MediaItemIdentity.hasStrongRetargetIdentity(watchlistRow()))
        XCTAssertTrue(
            MediaItemIdentity.hasStrongRetargetIdentity(
                watchlistRow(providerIDs: ["Imdb": "tt0156887"])
            )
        )
        XCTAssertFalse(MediaItemIdentity.hasStrongRetargetIdentity(watchlistRow(providerIDs: [:])))
    }

    /// The predicate and the index must agree about what counts as strong: an item
    /// this returns true for is one `identities(for:)` emits a non-title key for.
    /// While they disagreed, the index could find the copy and the retarget refused
    /// to ask it.
    func testPredicateAgreesWithWhatTheIndexActuallyKeysBy() {
        let row = watchlistRow()
        let identities = MediaItemIdentity.identities(for: row)
        let hasExternalKey = identities.contains {
            if case .external = $0 { return true }
            return false
        }
        XCTAssertTrue(hasExternalKey, "the index keys this row by its guid…")
        XCTAssertTrue(
            MediaItemIdentity.hasStrongRetargetIdentity(row),
            "…so the retarget gate must trust the same id"
        )
    }
}
