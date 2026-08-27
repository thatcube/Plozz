import XCTest
@testable import ProviderShare

/// Covers taking a network-share title off Continue Watching.
///
/// A share's watch state is Plozz's own — there is no server to tell and no other
/// client to disagree — so hiding a title need not cost the viewer their place.
/// That is the behaviour a managed server only gets when it happens to have a
/// dismissal action of its own.
final class ShareDismissContinueWatchingTests: XCTestCase {

    private let played = Date(timeIntervalSince1970: 1_000)
    private let later = Date(timeIntervalSince1970: 2_000)

    private func record(position: TimeInterval = 600, dismissedAt: Date? = nil) -> ShareWatchStore.Record {
        ShareWatchStore.Record(
            position: position,
            played: false,
            updatedAt: played,
            duration: 5_400,
            dismissedAt: dismissedAt
        )
    }

    func testAnUntouchedRecordIsNotDismissed() {
        XCTAssertFalse(record().isDismissedFromContinueWatching)
    }

    func testADismissalAfterTheLastPlayHidesTheTitle() {
        XCTAssertTrue(record(dismissedAt: later).isDismissedFromContinueWatching)
    }

    /// The position survives the dismissal — that is the whole point.
    func testTheViewersPlaceIsKept() {
        XCTAssertEqual(record(dismissedAt: later).position, 600)
    }

    /// Playing it again is the viewer changing their mind, and it un-hides the
    /// title on its own: the record simply becomes newer than the dismissal, so
    /// nothing has to remember to undo anything.
    func testAPlayAfterTheDismissalBringsItBack() {
        let dismissedThenPlayed = ShareWatchStore.Record(
            position: 900,
            played: false,
            updatedAt: later,
            duration: 5_400,
            dismissedAt: played
        )
        XCTAssertFalse(dismissedThenPlayed.isDismissedFromContinueWatching)
    }

    /// An out-of-order drain of an OLDER play must not resurrect it.
    func testAnOlderPlayDrainingLateDoesNotBringItBack() {
        let stale = ShareWatchStore.Record(
            position: 300,
            played: false,
            updatedAt: played,
            duration: 5_400,
            dismissedAt: later
        )
        XCTAssertTrue(stale.isDismissedFromContinueWatching)
    }

    /// Records written before dismissal existed decode as never dismissed.
    func testLegacyRecordsDecodeAsNotDismissed() throws {
        let legacy = #"{"position":600,"played":false,"updatedAt":1000,"duration":5400}"#
        let decoded = try JSONDecoder().decode(
            ShareWatchStore.Record.self,
            from: Data(legacy.utf8)
        )
        XCTAssertNil(decoded.dismissedAt)
        XCTAssertFalse(decoded.isDismissedFromContinueWatching)
        XCTAssertEqual(decoded.position, 600)
    }
}
