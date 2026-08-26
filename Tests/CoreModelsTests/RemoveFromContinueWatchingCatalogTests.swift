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
