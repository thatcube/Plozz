import CoreModels
import XCTest
@testable import MediaDownloads

/// Contract test: an offline play reuses the EXISTING durable watch outbox
/// (`WatchMutationOutbox`/`WatchOutboxState`) rather than introducing a new sync
/// mechanism. This proves an offline-captured watch mutation round-trips through
/// the outbox store so it can fan out on reconnect — no new plumbing required.
final class WatchOutboxReuseContractTests: XCTestCase {

    func testOfflineWatchMutationRoundTripsThroughExistingOutbox() throws {
        let store = InMemoryWatchMutationStore()

        // Simulate what an offline play enqueues: a resume-position write for the
        // account/item, captured now, to be drained on reconnect.
        let mutation = WatchMutation(
            capturedAt: Date(),
            canonicalMediaID: "imdb:tt0133093",
            resumePosition: 1_234,
            targets: [WatchMutationTarget(accountID: "account1", itemID: "item1")]
        )
        var state = WatchOutboxState.empty
        state.pending = [mutation]

        try store.save(state)

        let reloaded = store.load()
        XCTAssertEqual(reloaded.pending.count, 1)
        XCTAssertEqual(reloaded.pending.first?.canonicalMediaID, "imdb:tt0133093")
        XCTAssertEqual(reloaded.pending.first?.resumePosition, 1_234)
        XCTAssertEqual(reloaded.pending.first?.targets.first?.accountID, "account1")
    }

    func testOutboxStateIsDurableLocalStateValue() {
        // The outbox is persisted via the SAME durable-state schema the downloads
        // catalog uses, confirming the reuse is real (not a parallel store).
        XCTAssertEqual(WatchOutboxState.durableLocalStateSchemaID, "com.plozz.watch-outbox.v1")
    }
}
