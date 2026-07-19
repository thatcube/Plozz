import CoreModels
import XCTest
@testable import MediaDownloads

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

    func testResumeInterruptedRestartsPausedRecords() async throws {
        let registry = DownloadedMediaRegistry(store: InMemoryDownloadedMediaStore())
        // Seed a paused record directly.
        _ = try await registry.beginDownload(try DownloadTestFactory.record(status: .paused))
        let (queue, dir) = makeQueue(registry: registry, engine: FakeDownloadEngine.completing(at: 70))
        defer { try? FileManager.default.removeItem(at: dir) }

        await queue.resumeInterrupted()
        await queue.drainForTesting()

        let all = await registry.all()
        XCTAssertEqual(all.count, 1)
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
