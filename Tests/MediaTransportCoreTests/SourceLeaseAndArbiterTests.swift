import Foundation
import XCTest
@testable import MediaTransportCore

private final class ReadGate: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var opened = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var openWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        let starts = lock.withLock {
            started = true
            let waiters = startWaiters
            startWaiters.removeAll()
            return waiters
        }
        starts.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            let open = lock.withLock {
                guard !opened else { return true }
                openWaiters.append(continuation)
                return false
            }
            if open { continuation.resume() }
        }
    }

    func waitUntilStarted() async {
        await withCheckedContinuation { continuation in
            let started = lock.withLock {
                guard !self.started else { return true }
                startWaiters.append(continuation)
                return false
            }
            if started { continuation.resume() }
        }
    }

    func open() {
        let waiters = lock.withLock {
            opened = true
            let waiters = openWaiters
            openWaiters.removeAll()
            return waiters
        }
        waiters.forEach { $0.resume() }
    }
}

private final class BlockingByteSource: MediaTransportByteSource, @unchecked Sendable {
    let gate = ReadGate()
    private let lock = NSLock()
    private var shutdownCountStorage = 0
    let byteSize: Int64 = 1
    var shutdownCount: Int { lock.withLock { shutdownCountStorage } }

    func read(at offset: Int64, length: Int) async throws -> Data {
        await gate.wait()
        return Data([42])
    }

    func shutdown() async {
        lock.withLock { shutdownCountStorage += 1 }
    }
}

private final class BlockingCancelScannerResource: MediaIOScannerResource, @unchecked Sendable {
    let cancelGate = ReadGate()
    private let lock = NSLock()
    private var cancelCountStorage = 0

    var cancelCount: Int { lock.withLock { cancelCountStorage } }
    var isDrained: Bool { true }

    func cancel() async {
        lock.withLock { cancelCountStorage += 1 }
        await cancelGate.wait()
    }

    func forceClose() async throws {}
}

private final class RetryingDrainScannerResource: MediaIOScannerResource, @unchecked Sendable {
    enum FakeError: Error { case closeFailed }

    private let lock = NSLock()
    private var drainCheckCountStorage = 0
    private var forceCloseCountStorage = 0

    var isDrained: Bool {
        lock.withLock {
            drainCheckCountStorage += 1
            return false
        }
    }
    var drainCheckCount: Int { lock.withLock { drainCheckCountStorage } }
    var forceCloseCount: Int { lock.withLock { forceCloseCountStorage } }

    func cancel() async {}

    func forceClose() async throws {
        lock.withLock { forceCloseCountStorage += 1 }
        throw FakeError.closeFailed
    }
}

private final class BlockingForceCloseScannerResource: MediaIOScannerResource, @unchecked Sendable {
    enum FakeError: Error { case closeFailed }

    let forceCloseGate = ReadGate()
    var isDrained: Bool { false }

    func cancel() async {}

    func forceClose() async throws {
        await forceCloseGate.wait()
        throw FakeError.closeFailed
    }
}

final class SourceLeaseAndArbiterTests: XCTestCase {
    func testLeaseWithoutCursorShutsDownWhenClosed() async {
        let source = FakeByteSource(data: Data())
        let lease = MediaTransportSourceLease(source: source)

        lease.close()
        await lease.waitForFinalShutdown()

        XCTAssertEqual(source.shutdownCount, 1)
        XCTAssertNil(lease.makeCursor())
    }

    func testClonedCursorsAreIndependentAndFinalCloseShutsDownOnce() async throws {
        let source = FakeByteSource(data: Data([0, 1, 2, 3]))
        let lease = MediaTransportSourceLease(source: source)
        let first = try XCTUnwrap(lease.makeCursor())
        let second = try XCTUnwrap(first.clone())

        first.close()
        XCTAssertEqual(source.shutdownCount, 0)
        let bytes = try await second.read(at: 1, length: 2)
        XCTAssertEqual(bytes, Data([1, 2]))
        second.close()
        await lease.waitForFinalShutdown()
        XCTAssertEqual(source.shutdownCount, 1)
        XCTAssertNil(first.clone())
    }

    func testCursorCancellationDoesNotSkipInflightDrain() async throws {
        let source = BlockingByteSource()
        let lease = MediaTransportSourceLease(source: source)
        let cursor = try XCTUnwrap(lease.makeCursor())
        let read = Task { try await cursor.read(at: 0, length: 1) }
        await source.gate.waitUntilStarted()

        cursor.cancel()
        cursor.close()
        XCTAssertEqual(source.shutdownCount, 0)
        source.gate.open()
        _ = try await read.value
        await lease.waitForFinalShutdown()
        XCTAssertEqual(source.shutdownCount, 1)
    }

    func testPlaybackCancelsAndDrainsScannerAndRejectsLateCompletion() async throws {
        let arbiter = MediaIOArbiter(
            accountID: "account",
            deadline: FakeDrainDeadline(drains: true)
        )
        let scannerResource = FakeScannerResource()
        let scanner = try await arbiter.acquireScanner(resource: scannerResource)
        let playback = try await arbiter.acquirePlayback()

        XCTAssertEqual(scannerResource.cancelCount, 1)
        XCTAssertEqual(scannerResource.forceCloseCount, 0)
        scanner.finish()
        do {
            _ = try await arbiter.acquireScanner(resource: FakeScannerResource())
            XCTFail("scanner admitted during playback")
        } catch let error as MediaTransportError {
            XCTAssertEqual(error, .resourceBusy)
        }
        playback.release()
        var nextScanner: MediaIOScannerLease?
        for _ in 0..<1_000 {
            if let admitted = try? await arbiter.acquireScanner(resource: FakeScannerResource()) {
                nextScanner = admitted
                break
            }
            await Task.yield()
        }
        XCTAssertNotNil(nextScanner)
    }

    func testTimeoutForceClosesScannerBeforePlayback() async throws {
        let arbiter = MediaIOArbiter(
            accountID: "account",
            deadline: FakeDrainDeadline(drains: false)
        )
        let scanner = FakeScannerResource()
        let scannerLease = try await arbiter.acquireScanner(resource: scanner)
        let playback = try await arbiter.acquirePlayback()

        XCTAssertEqual(scanner.cancelCount, 1)
        XCTAssertEqual(scanner.forceCloseCount, 1)
        scannerLease.finish()
        playback.release()
    }

    func testForceCloseFailureReturnsResourceBusy() async throws {
        let arbiter = MediaIOArbiter(
            accountID: "account",
            deadline: FakeDrainDeadline(drains: false)
        )
        let scanner = FakeScannerResource()
        scanner.forceCloseFails = true
        let scannerLease = try await arbiter.acquireScanner(resource: scanner)

        do {
            _ = try await arbiter.acquirePlayback()
            XCTFail("playback admitted after failed force close")
        } catch let error as MediaTransportError {
            XCTAssertEqual(error, .resourceBusy)
        }
        scanner.forceCloseFails = false
        let playback = try await arbiter.acquirePlayback()
        XCTAssertEqual(scanner.forceCloseCount, 2)
        playback.release()
        scannerLease.finish()
    }

    func testPlaybackIsExclusive() async throws {
        let arbiter = MediaIOArbiter(accountID: "account")
        let playback = try await arbiter.acquirePlayback()
        do {
            _ = try await arbiter.acquirePlayback()
            XCTFail("second playback admitted")
        } catch let error as MediaTransportError {
            XCTAssertEqual(error, .resourceBusy)
        }
        playback.release()
    }

    func testReplacingScannerCreatesDisposableGeneration() async throws {
        let arbiter = MediaIOArbiter(
            accountID: "account",
            deadline: FakeDrainDeadline(drains: true)
        )
        let firstResource = FakeScannerResource()
        let secondResource = FakeScannerResource()
        let first = try await arbiter.acquireScanner(resource: firstResource)
        let second = try await arbiter.acquireScanner(resource: secondResource)
        XCTAssertNotEqual(first.generation, second.generation)
        XCTAssertEqual(firstResource.cancelCount, 1)

        first.finish()
        let playback = try await arbiter.acquirePlayback()
        XCTAssertEqual(secondResource.cancelCount, 1)
        second.finish()
        playback.release()
    }

    func testScannerReplacementReservesAdmissionAcrossCancellation() async throws {
        let arbiter = MediaIOArbiter(
            accountID: "account",
            deadline: FakeDrainDeadline(drains: true)
        )
        let firstResource = BlockingCancelScannerResource()
        let first = try await arbiter.acquireScanner(resource: firstResource)
        let secondResource = FakeScannerResource()
        let replacement = Task {
            try await arbiter.acquireScanner(resource: secondResource)
        }
        await firstResource.cancelGate.waitUntilStarted()

        do {
            _ = try await arbiter.acquirePlayback()
            XCTFail("playback admitted while scanner replacement was pending")
        } catch let error as MediaTransportError {
            XCTAssertEqual(error, .resourceBusy)
        }
        do {
            _ = try await arbiter.acquireScanner(resource: FakeScannerResource())
            XCTFail("second replacement admitted while cancellation was pending")
        } catch let error as MediaTransportError {
            XCTAssertEqual(error, .resourceBusy)
        }

        firstResource.cancelGate.open()
        let second = try await replacement.value
        XCTAssertNotEqual(first.generation, second.generation)
        XCTAssertEqual(firstResource.cancelCount, 1)

        first.finish()
        let playback = try await arbiter.acquirePlayback()
        XCTAssertEqual(secondResource.cancelCount, 1)
        second.finish()
        playback.release()
    }

    func testRepeatedFailedForceCloseUsesBoundedDrainPolling() async throws {
        let arbiter = MediaIOArbiter(
            accountID: "account",
            drainTimeout: .milliseconds(1)
        )
        let resource = RetryingDrainScannerResource()
        let scanner = try await arbiter.acquireScanner(resource: resource)

        for _ in 0..<2 {
            do {
                _ = try await arbiter.acquirePlayback()
                XCTFail("playback admitted after failed force close")
            } catch let error as MediaTransportError {
                XCTAssertEqual(error, .resourceBusy)
            }
        }

        XCTAssertGreaterThanOrEqual(resource.drainCheckCount, 2)
        XCTAssertEqual(resource.forceCloseCount, 2)
        scanner.finish()
    }

    func testScannerFinishDuringFailedPlaybackHandoffIsNotRestored() async throws {
        let arbiter = MediaIOArbiter(
            accountID: "account",
            deadline: FakeDrainDeadline(drains: false)
        )
        let resource = BlockingForceCloseScannerResource()
        let scanner = try await arbiter.acquireScanner(resource: resource)
        let playbackRequest = Task {
            try await arbiter.acquirePlayback()
        }
        await resource.forceCloseGate.waitUntilStarted()

        await scanner.finishAndWait()
        resource.forceCloseGate.open()
        do {
            _ = try await playbackRequest.value
            XCTFail("playback admitted after force close failed")
        } catch let error as MediaTransportError {
            XCTAssertEqual(error, .resourceBusy)
        }

        let replacement = try await arbiter.acquireScanner(resource: FakeScannerResource())
        replacement.finish()
    }
}
