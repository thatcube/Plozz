import XCTest
@testable import CoreModels
@testable import FeatureHome

/// Covers showing a just-played title before the server admits it exists, and —
/// more importantly — giving up on it afterwards.
///
/// A play produces two independent pieces of work: telling the server where the
/// viewer stopped, and asking it what is in progress. Nothing orders them, and on
/// device the ask routinely wins, so the server answers about a moment before the
/// play. The card is placed from what the player was already holding, then kept
/// only while there is evidence the server has not caught up.
///
/// The expiry is the load-bearing half. Without it this becomes the mirror of the
/// bug it fixes: a title removed on another client that Plozz shows forever.
final class HomeViewModelCarryForwardTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func card(_ id: String, account: String = "plex", resume: TimeInterval? = 600) -> MediaItem {
        var item = MediaItem(id: id, title: "Title-\(id)", kind: .movie)
        item.sourceAccountID = account
        item.resumePosition = resume
        item.lastPlayedAt = now
        item.sources = [MediaSourceRef(accountID: account, itemID: id, resumePosition: resume, lastPlayedAt: now)]
        return item
    }

    private func pendingPlay(_ id: String, account: String = "plex") -> WatchMutation {
        WatchMutation(
            capturedAt: now,
            canonicalMediaID: "local:\(id)",
            resumePosition: 600,
            targets: [WatchMutationTarget(accountID: account, itemID: id)]
        )
    }

    private func applied(_ id: String, account: String = "plex", secondsAgo: TimeInterval) -> [String: AppliedResumeRecord] {
        [
            "\(account):\(id)": AppliedResumeRecord(
                capturedAt: now.addingTimeInterval(-secondsAgo),
                appliedAt: now.addingTimeInterval(-secondsAgo)
            )
        ]
    }

    // MARK: The prediction

    /// The write is still queued, so the server plainly has not seen it.
    func testACardIsKeptWhileItsWriteIsStillQueued() {
        let result = HomeViewModel.reconcileContinueWatching(
            [],
            pending: [pendingPlay("just-played")],
            carryForward: [card("just-played")],
            now: now
        )
        XCTAssertEqual(result.map(\.id), ["just-played"])
    }

    /// The write landed a moment ago; the feed may simply not show it yet. This is
    /// the exact race measured on device.
    func testACardIsKeptBrieflyAfterItsWriteLands() {
        let result = HomeViewModel.reconcileContinueWatching(
            [],
            pending: [],
            appliedRecency: applied("just-played", secondsAgo: 3),
            carryForward: [card("just-played")],
            now: now
        )
        XCTAssertEqual(result.map(\.id), ["just-played"])
    }

    // MARK: The server winning

    /// The decisive case. Long after our write, a feed that still omits the title
    /// is not lagging — it is disagreeing, and it is right.
    func testTheServerWinsOnceTheWindowHasPassed() {
        let result = HomeViewModel.reconcileContinueWatching(
            [],
            pending: [],
            appliedRecency: applied("watched-elsewhere", secondsAgo: 3_600),
            carryForward: [card("watched-elsewhere")],
            now: now,
            carryForwardWindow: 300
        )
        XCTAssertTrue(
            result.isEmpty,
            "A stale prediction must never outlive the server's answer, or this becomes the bug it fixes"
        )
    }

    /// A card we never wrote to is pure server territory — watched on another
    /// device, dismissed in the Plex app. It has no claim to be carried at all.
    func testACardWeNeverWroteToIsNeverCarried() {
        let result = HomeViewModel.reconcileContinueWatching(
            [],
            pending: [pendingPlay("something-else")],
            carryForward: [card("removed-in-plex")],
            now: now
        )
        XCTAssertTrue(result.isEmpty)
    }

    /// A finished title is *supposed* to leave the row, so its absence is the
    /// intended outcome rather than a server that has not caught up.
    func testAFinishedTitleIsNotCarried() {
        let finished = card("finished", resume: 0)
        let result = HomeViewModel.reconcileContinueWatching(
            [],
            pending: [],
            appliedRecency: applied("finished", secondsAgo: 3),
            carryForward: [finished],
            now: now
        )
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: No duplicates

    /// Once the server does report the title, the fetched card is the real one and
    /// the prediction must not sit beside it.
    func testTheServersOwnCardReplacesThePredictionRatherThanJoiningIt() {
        let result = HomeViewModel.reconcileContinueWatching(
            [card("just-played")],
            pending: [pendingPlay("just-played")],
            carryForward: [card("just-played")],
            now: now
        )
        XCTAssertEqual(result.map(\.id), ["just-played"], "Exactly one card, the server's")
    }

    /// A merged card represents the title on several servers; a play on any one of
    /// them is already covered by it.
    func testAMergedCardCoveringThePlayIsNotDuplicated() {
        var merged = MediaItem(id: "jf-1", title: "Merged", kind: .movie)
        merged.sourceAccountID = "jellyfin"
        merged.resumePosition = 600
        merged.sources = [
            MediaSourceRef(accountID: "jellyfin", itemID: "jf-1"),
            MediaSourceRef(accountID: "plex", itemID: "px-1")
        ]

        let result = HomeViewModel.reconcileContinueWatching(
            [merged],
            pending: [pendingPlay("px-1")],
            carryForward: [card("px-1")],
            now: now
        )
        XCTAssertEqual(result.map(\.id), ["jf-1"])
    }

    // MARK: Once the server has answered, it keeps answering

    /// The Zorro case, reduced. Play something, remove it in the Plex app a minute
    /// later, and the row must let it go — even though our write is still "recent"
    /// by the clock. Once the server has shown us the card, its later silence is an
    /// answer rather than lag.
    func testACardTheServerAlreadyShowedUsIsNotCarriedWhenItLaterDisappears() {
        let confirmed: Set<String> = ["plex\u{1}removed-after-playing"]
        let result = HomeViewModel.reconcileContinueWatching(
            [],
            pending: [],
            appliedRecency: applied("removed-after-playing", secondsAgo: 30),
            carryForward: [card("removed-after-playing")],
            serverConfirmed: confirmed,
            now: now
        )
        XCTAssertTrue(
            result.isEmpty,
            "A removal made after the server acknowledged the play must take effect at once, not after the carry window"
        )
    }

    /// The counterpart that must keep working: before any acknowledgement, the
    /// same absence still means the server has not caught up.
    func testACardTheServerHasNotYetShownUsIsStillCarried() {
        let result = HomeViewModel.reconcileContinueWatching(
            [],
            pending: [],
            appliedRecency: applied("just-played", secondsAgo: 3),
            carryForward: [card("just-played")],
            serverConfirmed: [],
            now: now
        )
        XCTAssertEqual(result.map(\.id), ["just-played"])
    }

    /// Confirmation is per title, so acknowledging one says nothing about another.
    func testConfirmingOneTitleDoesNotAffectAnother() {
        let result = HomeViewModel.reconcileContinueWatching(
            [],
            pending: [],
            appliedRecency: applied("just-played", secondsAgo: 3),
            carryForward: [card("just-played")],
            serverConfirmed: ["plex\u{1}something-else"],
            now: now
        )
        XCTAssertEqual(result.map(\.id), ["just-played"])
    }

    /// A merged card is confirmed if *any* of its servers has shown it, since one
    /// acknowledgement is enough to prove the write was seen.
    func testConfirmationOnAnySourceOfAMergedCardCounts() {
        var merged = MediaItem(id: "jf-1", title: "Merged", kind: .movie)
        merged.sourceAccountID = "jellyfin"
        merged.resumePosition = 600
        merged.sources = [
            MediaSourceRef(accountID: "jellyfin", itemID: "jf-1"),
            MediaSourceRef(accountID: "plex", itemID: "px-1")
        ]

        let result = HomeViewModel.reconcileContinueWatching(
            [],
            pending: [],
            appliedRecency: applied("px-1", secondsAgo: 30),
            carryForward: [merged],
            serverConfirmed: ["plex\u{1}px-1"],
            now: now
        )
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: Inertness

    func testNothingHappensWithoutPendingOrAppliedWrites() {
        let result = HomeViewModel.reconcileContinueWatching(
            [card("a")],
            pending: [],
            carryForward: [card("b")],
            now: now
        )
        XCTAssertEqual(result.map(\.id), ["a"], "With no evidence of a write, the feed stands alone")
    }
}
