#if canImport(AetherEngine)
import Foundation
import XCTest
import AetherEngine
@testable import EnginePlozzigen

private final class FakeTransportByteSource: TransportByteSource, @unchecked Sendable {
    enum FakeError: Error {
        case failed
    }

    private struct State {
        var closeCount = 0
        var shouldFailReads = false
    }

    let data: Data
    private let state = NSLock()
    private var storage = State()

    init(_ data: Data) {
        self.data = data
    }

    var byteSize: Int64 {
        Int64(data.count)
    }

    var closeCount: Int {
        state.withLock { storage.closeCount }
    }

    func failReads() {
        state.withLock { storage.shouldFailReads = true }
    }

    func read(at offset: Int64, length: Int) async throws -> Data {
        if state.withLock({ storage.shouldFailReads }) {
            throw FakeError.failed
        }
        guard offset >= 0, offset < data.count, length > 0 else { return Data() }
        let end = min(Int(offset) + length, data.count)
        return data.subdata(in: Int(offset)..<end)
    }

    func shutdown() async {
        state.withLock { storage.closeCount += 1 }
    }
}

private final class AsyncReadGate: @unchecked Sendable {
    private struct State {
        var isStarted = false
        var isOpen = false
        var startWaiters: [CheckedContinuation<Void, Never>] = []
        var openWaiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = NSLock()
    private var storage = State()

    func reachAndWait() async {
        let startWaiters = state.withLock { () -> [CheckedContinuation<Void, Never>] in
            storage.isStarted = true
            let waiters = storage.startWaiters
            storage.startWaiters.removeAll()
            return waiters
        }
        startWaiters.forEach { $0.resume() }

        await withCheckedContinuation { continuation in
            let resumeImmediately = state.withLock { () -> Bool in
                if storage.isOpen {
                    return true
                }
                storage.openWaiters.append(continuation)
                return false
            }
            if resumeImmediately {
                continuation.resume()
            }
        }
    }

    func waitUntilStarted() async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = state.withLock { () -> Bool in
                if storage.isStarted {
                    return true
                }
                storage.startWaiters.append(continuation)
                return false
            }
            if resumeImmediately {
                continuation.resume()
            }
        }
    }

    func open() {
        let waiters = state.withLock { () -> [CheckedContinuation<Void, Never>] in
            storage.isOpen = true
            let waiters = storage.openWaiters
            storage.openWaiters.removeAll()
            return waiters
        }
        waiters.forEach { $0.resume() }
    }
}

private final class BlockingTransportByteSource: TransportByteSource, @unchecked Sendable {
    private let readGate = AsyncReadGate()
    private let state = NSLock()
    private var closeCountStorage = 0

    let byteSize: Int64 = 1

    var closeCount: Int {
        state.withLock { closeCountStorage }
    }

    func read(at offset: Int64, length: Int) async throws -> Data {
        await readGate.reachAndWait()
        return Data([42])
    }

    func shutdown() async {
        state.withLock { closeCountStorage += 1 }
    }

    func waitUntilReadStarts() async {
        await readGate.waitUntilStarted()
    }

    func finishRead() {
        readGate.open()
    }
}

private func read(_ reader: IOReader, count: Int) -> (result: Int32, data: Data) {
    var bytes = [UInt8](repeating: 0, count: count)
    let result = bytes.withUnsafeMutableBufferPointer {
        reader.read($0.baseAddress, size: Int32(count))
    }
    return (result, Data(bytes.prefix(Int(max(result, 0)))))
}

final class TransportIOReaderTests: XCTestCase {
    private let payload = Data((0..<256).map { UInt8($0) })

    func testSequentialReadAdvancesCursor() {
        let reader = TransportIOReader(source: FakeTransportByteSource(payload))

        XCTAssertEqual(read(reader, count: 4).data, Data([0, 1, 2, 3]))
        XCTAssertEqual(read(reader, count: 4).data, Data([4, 5, 6, 7]))
    }

    func testSeekModesAndSizeQuery() {
        let reader = TransportIOReader(source: FakeTransportByteSource(payload))

        XCTAssertEqual(reader.seek(offset: 10, whence: SEEK_SET), 10)
        XCTAssertEqual(reader.seek(offset: 5, whence: SEEK_CUR), 15)
        XCTAssertEqual(reader.seek(offset: -1, whence: SEEK_END), 255)
        XCTAssertEqual(reader.seek(offset: 0, whence: 65_536), 256)
        XCTAssertEqual(read(reader, count: 1).data, Data([255]))
    }

    func testEOFAndSpanningRead() {
        let reader = TransportIOReader(source: FakeTransportByteSource(payload))

        XCTAssertEqual(reader.seek(offset: 254, whence: SEEK_SET), 254)
        XCTAssertEqual(read(reader, count: 16).data, Data([254, 255]))
        XCTAssertEqual(read(reader, count: 1).result, 0)
    }

    func testInvalidSeekDoesNotMoveCursor() {
        let reader = TransportIOReader(source: FakeTransportByteSource(payload))

        XCTAssertEqual(reader.seek(offset: 10, whence: SEEK_SET), 10)
        XCTAssertLessThan(reader.seek(offset: -999, whence: SEEK_SET), 0)
        XCTAssertLessThan(reader.seek(offset: 0, whence: 999), 0)
        XCTAssertEqual(read(reader, count: 2).data, Data([10, 11]))
    }

    func testReadFailureReturnsNegative() {
        let source = FakeTransportByteSource(payload)
        source.failReads()
        let reader = TransportIOReader(source: source)

        XCTAssertLessThan(read(reader, count: 4).result, 0)
    }

    func testSourceClosesOnceAfterEveryReaderCloses() async throws {
        let source = FakeTransportByteSource(payload)
        let primary = TransportIOReader(source: source)
        let independent = try XCTUnwrap(primary.makeIndependentReader())

        primary.close()
        primary.close()
        XCTAssertEqual(source.closeCount, 0)

        independent.close()
        await primary.waitForFinalShutdown()
        XCTAssertEqual(source.closeCount, 1)
        XCTAssertNil(primary.makeIndependentReader())
    }

    func testCloseWaitsForIndependentInflightReadToDrain() async throws {
        let source = BlockingTransportByteSource()
        let primary = TransportIOReader(source: source)
        let independent = try XCTUnwrap(primary.makeIndependentReader())
        let readTask = Task.detached { read(independent, count: 1).result }
        await source.waitUntilReadStarts()

        primary.close()
        independent.close()
        XCTAssertEqual(source.closeCount, 0)
        let cancelledResult = await readTask.value
        XCTAssertEqual(cancelledResult, -1)

        source.finishRead()
        await primary.waitForFinalShutdown()
        XCTAssertEqual(source.closeCount, 1)
    }

    func testCancelUnblocksReadWhileUnderlyingOperationDrains() async {
        let source = BlockingTransportByteSource()
        let reader = TransportIOReader(source: source)
        let readTask = Task.detached { read(reader, count: 1).result }
        await source.waitUntilReadStarts()

        reader.cancel()
        let cancelledResult = await readTask.value
        XCTAssertEqual(cancelledResult, -1)

        source.finishRead()
        XCTAssertEqual(read(reader, count: 1).data, Data([42]))

        reader.close()
        await reader.waitForFinalShutdown()
        XCTAssertEqual(source.closeCount, 1)
    }
}
#endif
