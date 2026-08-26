import XCTest
@testable import CoreModels

/// Covers taking a title off Continue Watching from inside Plozz.
///
/// The row collects things by accident as readily as by intent — a trailer left
/// running, the wrong episode, a film abandoned ten minutes in. Until this action
/// the only way off was to open the server's own app, which is a strange thing
/// for a client to require of its user.
final class RemoveFromContinueWatchingCatalogTests: XCTestCase {

    private func item(
        kind: MediaItemKind = .movie,
        resume: TimeInterval? = nil,
        isPlayed: Bool = false
    ) -> MediaItem {
        MediaItem(
            id: "1",
            title: "Title",
            kind: kind,
            resumePosition: resume,
            isPlayed: isPlayed
        )
    }

    private func actions(for item: MediaItem) -> [MediaItemAction] {
        MediaItemActionCatalog.actions(for: item, supportsWatchState: true)
    }

    func testOfferedForATitleWithSomewhereToResumeFrom() {
        XCTAssertTrue(actions(for: item(resume: 600)).contains(.removeFromContinueWatching))
    }

    /// Nothing to remove: the action would be a no-op dressed as a choice.
    func testNotOfferedForATitleThatWasNeverStarted() {
        XCTAssertFalse(actions(for: item()).contains(.removeFromContinueWatching))
    }

    /// A rewatch is exactly the case someone wants to undo — and, since a resume
    /// point now outranks the watched mark elsewhere, it must be offered here too.
    func testOfferedForARewatchOfSomethingAlreadySeen() {
        XCTAssertTrue(
            actions(for: item(resume: 600, isPlayed: true)).contains(.removeFromContinueWatching)
        )
    }

    func testOfferedForAnEpisode() {
        XCTAssertTrue(actions(for: item(kind: .episode, resume: 300)).contains(.removeFromContinueWatching))
    }

    /// A container's progress is a count of watched episodes rather than a
    /// position, so there is nothing here to clear — the episode owns the action.
    func testNotOfferedForContainers() {
        for kind in [MediaItemKind.series, .season] {
            XCTAssertFalse(
                actions(for: item(kind: kind, resume: 600)).contains(.removeFromContinueWatching),
                "\(kind) has no resume point of its own"
            )
        }
    }

    /// A provider that cannot write watch state cannot clear a resume point.
    func testNotOfferedWhenTheProviderCannotWriteWatchState() {
        let offered = MediaItemActionCatalog.actions(
            for: item(resume: 600),
            supportsWatchState: false
        )
        XCTAssertFalse(offered.contains(.removeFromContinueWatching))
    }

    func testTheActionIsNeitherNavigationNorDestructive() {
        XCTAssertFalse(MediaItemAction.removeFromContinueWatching.isNavigation)
        XCTAssertFalse(
            MediaItemAction.removeFromContinueWatching.isDestructive,
            "Nothing is deleted — the file, and the watched history, are untouched"
        )
        XCTAssertFalse(MediaItemAction.removeFromContinueWatching.isDownload)
    }
}

/// Covers where the action sits in the menu.
///
/// Position is not decoration here. Every other action on this menu acts on the
/// title in front of the viewer; this one changes what Home shows. Landing on it
/// while reaching for "Mark as Watched" is precisely the kind of accident that
/// makes people want the action in the first place.
final class RemoveFromContinueWatchingMenuOrderTests: XCTestCase {

    func testItComesLastSoItIsNotHitOnTheWayToSomethingElse() {
        var item = MediaItem(id: "1", title: "Title", kind: .episode, resumePosition: 600)
        item.sourceAccountID = "plex"

        let actions = MediaItemActionCatalog.actions(
            for: item,
            supportsWatchState: true,
            supportsWatchlist: true,
            supportsMetadataRefresh: true,
            downloadState: .some(nil)
        )

        XCTAssertGreaterThan(actions.count, 1, "Precondition: other actions are present to sit above it")
        XCTAssertEqual(actions.last, .removeFromContinueWatching)
    }

    func testTheMenuIsToldToSetItApart() {
        XCTAssertTrue(MediaItemAction.removeFromContinueWatching.isSetApartInMenu)
    }

    /// Nothing else is separated, or the separation stops meaning anything.
    func testNoOtherActionIsSetApart() {
        let others = MediaItemAction.allCases.filter { $0 != .removeFromContinueWatching }
        XCTAssertTrue(others.allSatisfy { !$0.isSetApartInMenu })
    }
}
