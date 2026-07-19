import CoreModels
import XCTest
@testable import MediaDownloads

final class DownloadedMediaRegistryTests: XCTestCase {

    func testBeginDownloadRoundTripsThroughStore() async throws {
        let store = InMemoryDownloadedMediaStore()
        let registry = DownloadedMediaRegistry(store: store)
        let record = try DownloadTestFactory.record(status: .downloading)

        _ = try await registry.beginDownload(record)

        // A fresh registry over the SAME store sees the persisted record.
        let reloaded = DownloadedMediaRegistry(store: store)
        let loaded = await reloaded.record(forKey: record.identityKey)
        XCTAssertEqual(loaded?.identityKey, record.identityKey)
        XCTAssertEqual(loaded?.status, .downloading)
    }

    func testBeginDownloadIsIdempotentAndPreservesProgress() async throws {
        let store = InMemoryDownloadedMediaStore()
        let registry = DownloadedMediaRegistry(store: store)
        let identity = DownloadTestFactory.imdbIdentity()

        // First marker, then real progress recorded.
        _ = try await registry.beginDownload(
            try DownloadTestFactory.record(identity: identity, status: .downloading)
        )
        try await registry.updateProgress(
            identityKey: MediaIdentityKey.string(for: identity),
            bytesDownloaded: 40,
            totalBytes: 100
        )

        // Re-issuing the begin marker (e.g. after a relaunch) must NOT rewind the
        // 40 bytes already on disk back to zero.
        let reissued = try await registry.beginDownload(
            try DownloadTestFactory.record(identity: identity, status: .queued)
        )
        XCTAssertEqual(reissued.bytesDownloaded, 40)
        XCTAssertEqual(reissued.totalBytes, 100)
    }

    func testBeginDownloadKeepsCompletedRecordUntouched() async throws {
        let registry = DownloadedMediaRegistry(store: InMemoryDownloadedMediaStore())
        let identity = DownloadTestFactory.imdbIdentity()
        _ = try await registry.beginDownload(
            try DownloadTestFactory.record(identity: identity, status: .downloading)
        )
        try await registry.markCompleted(
            identityKey: MediaIdentityKey.string(for: identity), totalBytes: 100
        )

        let again = try await registry.beginDownload(
            try DownloadTestFactory.record(identity: identity, status: .queued, bytesDownloaded: 0)
        )
        XCTAssertEqual(again.status, .completed)
        XCTAssertEqual(again.bytesDownloaded, 100)
    }

    func testRecordForItemMatchesAnyCrossServerIdentity() async throws {
        let registry = DownloadedMediaRegistry(store: InMemoryDownloadedMediaStore())
        let identity = DownloadTestFactory.imdbIdentity("tt1375666")
        _ = try await registry.beginDownload(
            try DownloadTestFactory.record(identity: identity, status: .completed)
        )
        // An item carrying the same imdb id (even from a different server) resolves.
        let item = DownloadTestFactory.movie(imdb: "tt1375666", title: "Inception")
        let found = await registry.record(for: item)
        XCTAssertEqual(found?.identity, identity)
    }

    func testRecordForItemMatchesUniqueAccountScopedFallbackByItemID() async throws {
        let registry = DownloadedMediaRegistry(store: InMemoryDownloadedMediaStore())
        let identity = MediaIdentity.external(
            source: "plozz-account:share-account",
            value: "episode-7"
        )
        _ = try await registry.beginDownload(
            try DownloadTestFactory.record(identity: identity, status: .completed)
        )
        let item = MediaItem(id: "episode-7", title: "Episode 7", kind: .episode)

        let found = await registry.record(for: item)

        XCTAssertEqual(found?.identity, identity)
    }

    func testRecordForItemRejectsAmbiguousAccountScopedFallback() async throws {
        let registry = DownloadedMediaRegistry(store: InMemoryDownloadedMediaStore())
        for account in ["one", "two"] {
            let identity = MediaIdentity.external(
                source: "plozz-account:\(account)",
                value: "episode-7"
            )
            _ = try await registry.beginDownload(
                try DownloadTestFactory.record(identity: identity, status: .completed)
            )
        }
        let item = MediaItem(id: "episode-7", title: "Episode 7", kind: .episode)

        let found = await registry.record(for: item)

        XCTAssertNil(found)
    }

    func testStatusTransitionsAndRemoval() async throws {
        let registry = DownloadedMediaRegistry(store: InMemoryDownloadedMediaStore())
        let identity = DownloadTestFactory.imdbIdentity()
        let key = MediaIdentityKey.string(for: identity)
        _ = try await registry.beginDownload(
            try DownloadTestFactory.record(identity: identity, status: .downloading)
        )

        try await registry.setStatus(identityKey: key, .paused, failureReason: "user")
        let paused = await registry.record(forKey: key)
        XCTAssertEqual(paused?.status, .paused)
        XCTAssertEqual(paused?.failureReason, "user")

        try await registry.remove(identityKey: key)
        let removed = await registry.record(forKey: key)
        let all = await registry.all()
        XCTAssertNil(removed)
        XCTAssertTrue(all.isEmpty)
    }

    func testEmitsProgressEvents() async throws {
        let registry = DownloadedMediaRegistry(store: InMemoryDownloadedMediaStore())
        let stream = await registry.events()
        let identity = DownloadTestFactory.imdbIdentity()

        _ = try await registry.beginDownload(
            try DownloadTestFactory.record(identity: identity, status: .downloading, groupID: "season-1")
        )

        var sawItem = false
        var sawGroup = false
        var sawGlobal = false
        var iterator = stream.makeAsyncIterator()
        // Three events are emitted for the single write: item + group + global.
        for _ in 0..<3 {
            switch await iterator.next() {
            case .item: sawItem = true
            case .group(let g): sawGroup = (g.groupID == "season-1")
            case .global: sawGlobal = true
            default: break
            }
        }
        XCTAssertTrue(sawItem)
        XCTAssertTrue(sawGroup)
        XCTAssertTrue(sawGlobal)
    }
}
