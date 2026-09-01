import CoreModels
import XCTest
@testable import MediaDownloads

private actor FailOnceDownloadEngine: MediaDownloadEngine {
    private var attempt = 0

    func download(
        record: DownloadedMediaRecord,
        to destination: URL,
        onProgress: @escaping @Sendable (Int64, Int64) async -> Void
    ) async throws -> Int64 {
        attempt += 1
        if attempt == 1 {
            throw Failure()
        }
        await onProgress(42, 42)
        return 42
    }

    private struct Failure: Error {}
}

private actor BlockingThenCompletingEngine: MediaDownloadEngine {
    private var attempt = 0

    func download(
        record: DownloadedMediaRecord,
        to destination: URL,
        onProgress: @escaping @Sendable (Int64, Int64) async -> Void
    ) async throws -> Int64 {
        attempt += 1
        if attempt == 1 {
            try await Task.sleep(for: .seconds(30))
        }
        await onProgress(64, 64)
        return 64
    }
}

final class DownloadQueueTests: XCTestCase {

    private func makeQueue(
        registry: DownloadedMediaRegistry,
        engine: any MediaDownloadEngine,
        observer: any DownloadNetworkObserving = StaticDownloadNetworkObserver(),
        policy: DownloadNetworkPolicy = .default
    ) -> (DownloadQueue, URL) {
        let dir = DownloadTestFactory.tempDirectory()
        let queue = DownloadQueue(
            registry: registry,
            storage: FixedDownloadStorageLocator(root: dir),
            engine: engine,
            observer: observer,
            policy: policy,
            maxAttempts: 1,
            backoff: { _ in }
        )
        return (queue, dir)
    }

    func testEnqueueCompletesAndPersists() async throws {
        let registry = DownloadedMediaRegistry(store: InMemoryDownloadedMediaStore())
        let (queue, dir) = makeQueue(registry: registry, engine: FakeDownloadEngine.completing(at: 100))
        defer { try? FileManager.default.removeItem(at: dir) }

        let record = try await queue.enqueue(try DownloadTestFactory.request())
        await queue.drainForTesting()

        let final = await registry.record(forKey: record.identityKey)
        XCTAssertEqual(final?.status, .completed)
        XCTAssertEqual(final?.bytesDownloaded, 100)
        XCTAssertEqual(final?.totalBytes, 100)
    }

    func testEnqueueIsIdempotent() async throws {
        let registry = DownloadedMediaRegistry(store: InMemoryDownloadedMediaStore())
        let (queue, dir) = makeQueue(registry: registry, engine: FakeDownloadEngine.completing(at: 50))
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try await queue.enqueue(try DownloadTestFactory.request())
        _ = try await queue.enqueue(try DownloadTestFactory.request())
        await queue.drainForTesting()

        let count = await registry.all().count
        XCTAssertEqual(count, 1)
    }

    func testFailedQualityReplacementKeepsCompletedCopyPlayable() async throws {
        struct ReplacementFailure: Error {}

        let registry = DownloadedMediaRegistry(
            store: InMemoryDownloadedMediaStore()
        )
        let (queue, dir) = makeQueue(
            registry: registry,
            engine: FakeDownloadEngine.failing(with: ReplacementFailure())
        )
        defer { try? FileManager.default.removeItem(at: dir) }
        let storage = FixedDownloadStorageLocator(root: dir)
        let completed = try DownloadTestFactory.record(status: .completed)
        _ = try await registry.beginDownload(completed)
        try await registry.markCompleted(
            identityKey: completed.identityKey,
            totalBytes: 100
        )
        let originalURL = try storage.pinnedFileURL(for: completed)
        try FileManager.default.createDirectory(
            at: originalURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("offline-copy".utf8).write(to: originalURL)

        _ = try await queue.enqueue(
            try DownloadTestFactory.request(quality: .hd720)
        )
        await queue.drainForTesting()

        let replacement = await registry.record(forKey: completed.identityKey)
        XCTAssertEqual(replacement?.status, .failed)
        let resolver = RegistryOfflinePlaybackResolver(
            registry: registry,
            storage: storage
        )
        let playbackURL = await resolver.localPlaybackURL(
            for: DownloadTestFactory.movie(),
            versionID: nil
        )
        XCTAssertEqual(
            playbackURL,
            try storage.replacementBackupFolderURL(
                forKey: completed.identityKey
            ).appendingPathComponent(completed.localFileName)
        )
    }

    func testNetworkGatePausesWhenPolicyDisallows() async throws {
        let registry = DownloadedMediaRegistry(store: InMemoryDownloadedMediaStore())
        // Wi‑Fi‑only policy + an expensive (cellular) path -> must not download.
        let (queue, dir) = makeQueue(
            registry: registry,
            engine: FakeDownloadEngine.completing(at: 100),
            observer: StaticDownloadNetworkObserver(
                DownloadNetworkConditions(isSatisfied: true, isExpensive: true, isConstrained: false)
            )
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        let record = try await queue.enqueue(try DownloadTestFactory.request())
        await queue.drainForTesting()

        let final = await registry.record(forKey: record.identityKey)
        XCTAssertEqual(final?.status, .paused)
        XCTAssertNotEqual(final?.status, .completed)
    }

    func testCancellationMarksPaused() async throws {
        let registry = DownloadedMediaRegistry(store: InMemoryDownloadedMediaStore())
        let (queue, dir) = makeQueue(
            registry: registry, engine: FakeDownloadEngine.failing(with: CancellationError())
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        let record = try await queue.enqueue(try DownloadTestFactory.request())
        await queue.drainForTesting()

        let final = await registry.record(forKey: record.identityKey)
        XCTAssertEqual(final?.status, .paused)
    }

    func testImmediateResumeWaitsForCancelledAttemptToFinish() async throws {
        let registry = DownloadedMediaRegistry(
            store: InMemoryDownloadedMediaStore()
        )
        let (queue, dir) = makeQueue(
            registry: registry,
            engine: BlockingThenCompletingEngine()
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        let record = try await queue.enqueue(try DownloadTestFactory.request())
        try await Task.sleep(for: .milliseconds(50))
        await queue.pause(identityKey: record.identityKey)
        await queue.resume(identityKey: record.identityKey)
        await queue.drainForTesting()

        let final = await registry.record(forKey: record.identityKey)
        XCTAssertEqual(final?.status, .completed)
        XCTAssertEqual(final?.bytesDownloaded, 64)
    }

    func testFatalErrorMarksFailed() async throws {
        struct Boom: Error {}
        let registry = DownloadedMediaRegistry(store: InMemoryDownloadedMediaStore())
        let (queue, dir) = makeQueue(
            registry: registry, engine: FakeDownloadEngine.failing(with: Boom())
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        let record = try await queue.enqueue(try DownloadTestFactory.request())
        await queue.drainForTesting()

        let final = await registry.record(forKey: record.identityKey)
        XCTAssertEqual(final?.status, .failed)
    }

    func testResumeRetriesFailedDownload() async throws {
        let registry = DownloadedMediaRegistry(store: InMemoryDownloadedMediaStore())
        let (queue, dir) = makeQueue(
            registry: registry,
            engine: FailOnceDownloadEngine()
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        let record = try await queue.enqueue(try DownloadTestFactory.request())
        await queue.drainForTesting()
        let failed = await registry.record(forKey: record.identityKey)
        XCTAssertEqual(failed?.status, .failed)

        await queue.resume(identityKey: record.identityKey)
        await queue.drainForTesting()

        let completed = await registry.record(forKey: record.identityKey)
        XCTAssertEqual(completed?.status, .completed)
        XCTAssertEqual(completed?.bytesDownloaded, 42)
    }

    func testManagedRequestPersistsSecretFreeReopenSource() async throws {
        let registry = DownloadedMediaRegistry(store: InMemoryDownloadedMediaStore())
        let (queue, dir) = makeQueue(
            registry: registry,
            engine: FakeDownloadEngine.completing(at: 100)
        )
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = ManagedHTTPDownloadSource(
            provider: .jellyfin,
            accountID: "account-1",
            itemID: "movie-1",
            mediaSourceID: "source-1"
        )
        let request = DownloadRequest.managedHTTP(
            identity: DownloadTestFactory.imdbIdentity(),
            source: source,
            snapshot: PinnedMediaSnapshot(
                title: "Movie",
                kind: .movie
            ),
            fileExtension: "mkv"
        )

        let record = try await queue.enqueue(request)
        await queue.drainForTesting()

        let stored = await registry.record(forKey: record.identityKey)
        XCTAssertEqual(stored?.sourceKind, .managedHTTP)
        XCTAssertEqual(stored?.managedHTTPSource, source)
        XCTAssertNil(stored?.directShareSource)
    }

    func testEnqueueGroupSharesGroupID() async throws {
        let registry = DownloadedMediaRegistry(store: InMemoryDownloadedMediaStore())
        let (queue, dir) = makeQueue(registry: registry, engine: FakeDownloadEngine.completing(at: 10))
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try await queue.enqueueGroup([
            try DownloadTestFactory.request(identity: .external(source: "imdb", value: "s1e1"), groupID: "season-1"),
            try DownloadTestFactory.request(identity: .external(source: "imdb", value: "s1e2"), groupID: "season-1"),
        ])
        await queue.drainForTesting()

        let members = await registry.records(inGroup: "season-1")
        XCTAssertEqual(members.count, 2)
        XCTAssertTrue(members.allSatisfy { $0.status == .completed })
    }

    func testResumeInterruptedLeavesManualPauseAlone() async throws {
        let registry = DownloadedMediaRegistry(store: InMemoryDownloadedMediaStore())
        let seeded = try DownloadTestFactory.record(status: .paused)
        _ = try await registry.beginDownload(seeded)
        try await registry.setStatus(
            identityKey: seeded.identityKey,
            .paused,
            failureReason: "Paused",
            pauseReason: .manual
        )
        let (queue, dir) = makeQueue(registry: registry, engine: FakeDownloadEngine.completing(at: 70))
        defer { try? FileManager.default.removeItem(at: dir) }

        await queue.resumeInterrupted()
        await queue.drainForTesting()

        let all = await registry.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.status, .paused)
        XCTAssertEqual(all.first?.pauseReason, .manual)
    }

    func testResumeInterruptedRestartsDownloadingRecords() async throws {
        let registry = DownloadedMediaRegistry(store: InMemoryDownloadedMediaStore())
        _ = try await registry.beginDownload(
            try DownloadTestFactory.record(status: .downloading)
        )
        let (queue, dir) = makeQueue(
            registry: registry,
            engine: FakeDownloadEngine.completing(at: 70)
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        await queue.resumeInterrupted()
        await queue.drainForTesting()

        let all = await registry.all()
        XCTAssertEqual(all.first?.status, .completed)
    }

    func testStorageBudgetBlocksNewDownloads() async throws {
        let registry = DownloadedMediaRegistry(store: InMemoryDownloadedMediaStore())
        let (queue, dir) = makeQueue(registry: registry, engine: FakeDownloadEngine.completing(at: 100))
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try await queue.enqueue(try DownloadTestFactory.request(identity: .external(source: "imdb", value: "a")))
        await queue.drainForTesting()

        await queue.updatePolicy(DownloadNetworkPolicy(storageBudgetBytes: 50))
        let second = try await queue.enqueue(try DownloadTestFactory.request(identity: .external(source: "imdb", value: "b")))
        await queue.drainForTesting()

        let final = await registry.record(forKey: second.identityKey)
        XCTAssertEqual(final?.status, .failed)
    }
}
