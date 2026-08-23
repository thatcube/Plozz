@testable import AppRuntime
import CoreModels
import XCTest

/// The watchlist button has to be right the instant it is pressed, and stay
/// right when it is pressed repeatedly.
///
/// The durable write is an actor hop plus a disk write, so the truth the button
/// would otherwise read lags the press by seconds. These cover the two halves of
/// that: the press is visible immediately, and a burst of presses still ends up
/// writing what the viewer last asked for rather than whichever write happened
/// to finish last.
@MainActor
final class WatchlistIntentTests: XCTestCase {
    /// A stand-in for the durable watchlist: a set the fake write mutates, and
    /// the membership closure reads. Writes are gated so a test can hold one
    /// open and inspect the button mid-flight.
    private final class DurableDouble {
        var saved: Set<String> = []
        /// Every (desired, itemID) the coordinator actually asked to write.
        var writes: [(desired: Bool, id: String)] = []
        var concurrentWrites = 0
        var maxConcurrentWrites = 0
        var succeed = true
        /// Set to hold writes open; resumed by the test.
        var gate: CheckedContinuation<Void, Never>?
        var shouldGate = false

        func apply(_ desired: Bool, _ item: MediaItem) async -> Bool {
            concurrentWrites += 1
            maxConcurrentWrites = max(maxConcurrentWrites, concurrentWrites)
            defer { concurrentWrites -= 1 }

            if shouldGate {
                await withCheckedContinuation { self.gate = $0 }
            }
            writes.append((desired, item.id))
            guard succeed else { return false }
            if desired { saved.insert(item.id) } else { saved.remove(item.id) }
            return true
        }

        func release() {
            let waiting = gate
            gate = nil
            waiting?.resume()
        }
    }

    private func makeCoordinator(
        _ durable: DurableDouble
    ) -> MediaItemActionCoordinator {
        MediaItemActionCoordinator(
            providerResolver: { _ in nil },
            primaryAccountID: { nil },
            crossServerWatchSyncEnabled: { false },
            enqueueWatchMutation: { _ in },
            universalWatchlistEnabled: { true },
            watchlistMembership: { durable.saved.contains($0.id) },
            performUniversalWatchlist: { adding, item in
                await durable.apply(adding, item)
            },
            presentUniversalWatchlistFeedback: { _, _ in },
            beginUniversalWatchlistFanOut: { _, _ in }
        )
    }

    private var item: MediaItem {
        MediaItem(id: "show-1", title: "Family Guy", kind: .series)
    }

    /// The press is on screen before the write lands — the 2-3 second lag.
    func testPressIsVisibleBeforeTheWriteCompletes() async {
        let durable = DurableDouble()
        durable.shouldGate = true
        let coordinator = makeCoordinator(durable)
        let subject = item

        XCTAssertFalse(coordinator.isWatchlisted(subject))

        coordinator.perform(.addToWatchlist, on: subject, context: .none)

        // The write has not run, so the durable set is still empty — and the
        // button still has to say Added.
        XCTAssertFalse(durable.saved.contains(subject.id))
        XCTAssertTrue(
            coordinator.isWatchlisted(subject),
            "The button must reflect an accepted press before the durable write completes."
        )

        await settle { durable.gate != nil }
        durable.release()
        await settle { durable.writes.count == 1 }

        XCTAssertTrue(coordinator.isWatchlisted(subject))
        XCTAssertTrue(durable.saved.contains(subject.id))
    }

    /// Spamming the button leaves the durable state on the LAST press, and never
    /// runs two writes for one title at once.
    func testBurstOfPressesConvergesOnTheLastPress() async {
        let durable = DurableDouble()
        durable.shouldGate = true
        let coordinator = makeCoordinator(durable)
        let subject = item

        // First press opens a write and holds it.
        coordinator.perform(.addToWatchlist, on: subject, context: .none)
        await settle { durable.gate != nil }

        // Three more presses while that one is in flight. The last one wins.
        coordinator.perform(.removeFromWatchlist, on: subject, context: .none)
        coordinator.perform(.addToWatchlist, on: subject, context: .none)
        coordinator.perform(.removeFromWatchlist, on: subject, context: .none)

        XCTAssertFalse(
            coordinator.isWatchlisted(subject),
            "The button must show the most recent press, not the in-flight one."
        )

        // Let the queued writes drain.
        durable.release()
        await settle { durable.gate != nil }
        durable.release()
        await settle { durable.writes.count >= 2 }

        XCTAssertEqual(
            durable.maxConcurrentWrites,
            1,
            "Two writes for one title must never overlap; that is how presses land out of order."
        )
        XCTAssertFalse(
            durable.saved.contains(subject.id),
            "The durable state must match the last press."
        )
        XCTAssertFalse(coordinator.isWatchlisted(subject))
    }

    /// A write that fails must hand the button back to the truth rather than
    /// leave a confirmation standing for something that did not happen.
    ///
    /// Starts from a title that IS saved and fails the removal, so "reverted"
    /// and "never applied" are different answers — otherwise an implementation
    /// with no intent at all would pass this by doing nothing.
    func testFailedWriteRevertsTheButton() async {
        let durable = DurableDouble()
        let subject = item
        durable.saved.insert(subject.id)
        durable.succeed = false
        let coordinator = makeCoordinator(durable)

        XCTAssertTrue(coordinator.isWatchlisted(subject))

        coordinator.perform(.removeFromWatchlist, on: subject, context: .none)

        // Wait for the writer to have run and given up, rather than for the
        // write to be merely recorded — the intent is cleared on the way out.
        await settle {
            durable.writes.count == 1 && coordinator.isWatchlisted(subject)
        }

        XCTAssertTrue(
            coordinator.isWatchlisted(subject),
            "A failed removal must hand the button back to the truth — the title is still saved."
        )
        XCTAssertTrue(durable.saved.contains(subject.id))
    }

    /// Yields until `condition` holds, so tests wait on the coordinator's own
    /// Task rather than on a fixed sleep.
    private func settle(
        timeout: TimeInterval = 2,
        _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            await Task.yield()
        }
    }
}
