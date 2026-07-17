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

private final class CountingTransportByteSource: TransportByteSource, @unchecked Sendable {
    let data: Data
    private let state = NSLock()
    private var reads: [(offset: Int64, length: Int)] = []

    init(_ data: Data) { self.data = data }

    var byteSize: Int64 { Int64(data.count) }

    var readCount: Int { state.withLock { reads.count } }
    var readLog: [(offset: Int64, length: Int)] { state.withLock { reads } }

    func read(at offset: Int64, length: Int) async throws -> Data {
        state.withLock { reads.append((offset, length)) }
        guard offset >= 0, offset < data.count, length > 0 else { return Data() }
        let end = min(Int(offset) + length, data.count)
        return data.subdata(in: Int(offset)..<end)
    }

    func shutdown() async {}
}

private func read(_ reader: IOReader, count: Int) -> (result: Int32, data: Data) {
    var bytes = [UInt8](repeating: 0, count: count)
    let result = bytes.withUnsafeMutableBufferPointer {
        reader.read($0.baseAddress, size: Int32(count))
    }
    return (result, Data(bytes.prefix(Int(max(result, 0)))))
}

private final class CappedTransportByteSource: TransportByteSource, @unchecked Sendable {
    let data: Data
    let perReadCap: Int
    private let state = NSLock()
    private var reads: [(offset: Int64, length: Int)] = []

    init(_ data: Data, perReadCap: Int) {
        self.data = data
        self.perReadCap = perReadCap
    }

    var byteSize: Int64 { Int64(data.count) }
    var readCount: Int { state.withLock { reads.count } }

    func read(at offset: Int64, length: Int) async throws -> Data {
        // Simulate a backend that never serves more than `perReadCap` per read.
        let capped = min(length, perReadCap)
        state.withLock { reads.append((offset, capped)) }
        guard offset >= 0, offset < data.count, capped > 0 else { return Data() }
        let end = min(Int(offset) + capped, data.count)
        return data.subdata(in: Int(offset)..<end)
    }

    func shutdown() async {}
}

final class TransportIOReaderReadAheadTests: XCTestCase {
    /// Many small sequential reads within one window collapse to a single
    /// underlying transport round-trip (the cold-start latency win).
    func testSequentialSmallReadsCoalesceIntoOneFetch() {
        let payload = Data((0..<4096).map { UInt8($0 & 0xFF) })
        let source = CountingTransportByteSource(payload)
        let reader = TransportIOReader(source: source, readAheadWindow: 4096)

        var assembled = Data()
        for _ in 0..<16 { // 16 × 256B = 4096B, exactly one window
            assembled.append(read(reader, count: 256).data)
        }
        XCTAssertEqual(assembled, payload, "bytes are served intact from the window")
        XCTAssertEqual(source.readCount, 1, "one underlying fetch served all 16 demux reads")
        XCTAssertEqual(source.readLog.first?.length, 4096, "the fetch requested a full window, not 256B")
    }

    /// A backend that caps each read below the window still fills a full window by
    /// concatenating partial reads — the data is intact and ffmpeg sees one window.
    func testWindowFillConcatenatesCappedBackendReads() {
        let payload = Data((0..<4096).map { UInt8($0 & 0xFF) })
        let source = CappedTransportByteSource(payload, perReadCap: 1000)
        let reader = TransportIOReader(source: source, readAheadWindow: 4096)

        // One 256B demux read triggers a window fill of 4096B via 1000B pieces.
        XCTAssertEqual(read(reader, count: 256).data, Data(payload[0..<256]))
        XCTAssertEqual(source.readCount, 5, "4096B window filled by 1000+1000+1000+1000+96")

        // The rest of the window serves from cache (no more transport reads).
        var assembled = Data(payload[0..<256])
        for _ in 0..<15 { assembled.append(read(reader, count: 256).data) }
        XCTAssertEqual(assembled, payload, "concatenated window bytes are intact")
        XCTAssertEqual(source.readCount, 5, "remaining demux reads all served from cache")
    }

    /// Crossing the window boundary triggers exactly one more fetch, and the
    /// reassembled bytes are correct across the seam.
    func testCrossingWindowBoundaryFetchesNextWindow() {
        let payload = Data((0..<3000).map { UInt8($0 & 0xFF) })
        let source = CountingTransportByteSource(payload)
        let reader = TransportIOReader(source: source, readAheadWindow: 1024)

        var assembled = Data()
        while true {
            let (result, chunk) = read(reader, count: 256)
            if result <= 0 { break }
            assembled.append(chunk)
        }
        XCTAssertEqual(assembled, payload, "bytes are intact across window seams")
        // 3000 bytes / 1024 window = 3 windows (1024 + 1024 + 952).
        XCTAssertEqual(source.readCount, 3, "one fetch per window, no per-256B round-trips")
    }

    /// A seek inside the cached window serves from memory (no new fetch); a seek
    /// outside it triggers a fresh fetch.
    func testSeekWithinWindowServesFromCacheSeekOutsideRefetches() {
        let payload = Data((0..<8192).map { UInt8($0 & 0xFF) })
        let source = CountingTransportByteSource(payload)
        let reader = TransportIOReader(source: source, readAheadWindow: 4096)

        XCTAssertEqual(read(reader, count: 16).data, Data(payload[0..<16]))
        XCTAssertEqual(source.readCount, 1)

        // Seek within the [0,4096) window — still served from cache.
        XCTAssertEqual(reader.seek(offset: 1000, whence: SEEK_SET), 1000)
        XCTAssertEqual(read(reader, count: 16).data, Data(payload[1000..<1016]))
        XCTAssertEqual(source.readCount, 1, "in-window seek does not hit the transport")

        // Seek beyond the window — one fresh fetch.
        XCTAssertEqual(reader.seek(offset: 6000, whence: SEEK_SET), 6000)
        XCTAssertEqual(read(reader, count: 16).data, Data(payload[6000..<6016]))
        XCTAssertEqual(source.readCount, 2, "out-of-window seek refetches")
    }

    /// A read whose span exceeds what remains in the already-cached window returns
    /// only the buffered prefix (a valid short read); the next read fetches the
    /// following window. (On a miss the window is fetched starting at the read
    /// offset, so only reads served from an existing window can be short.)
    func testReadPastCachedWindowTailReturnsPrefixThenRefetches() {
        let payload = Data((0..<2048).map { UInt8($0 & 0xFF) })
        let source = CountingTransportByteSource(payload)
        let reader = TransportIOReader(source: source, readAheadWindow: 1024)

        // Establish a window at [0,1024) with a small read.
        XCTAssertEqual(read(reader, count: 16).data, Data(payload[0..<16]))
        XCTAssertEqual(source.readCount, 1)

        // Seek to 900 (still inside the cached window) and ask for 800: only 124
        // bytes remain in the window, so expect a 124-byte short read from cache.
        XCTAssertEqual(reader.seek(offset: 900, whence: SEEK_SET), 900)
        let first = read(reader, count: 800)
        XCTAssertEqual(first.data, Data(payload[900..<1024]))
        XCTAssertEqual(source.readCount, 1, "the short read was served from cache, no fetch")

        // Next read at 1024 refetches the following window.
        let second = read(reader, count: 800)
        XCTAssertEqual(second.data, Data(payload[1024..<1824]))
        XCTAssertEqual(source.readCount, 2)
    }

    /// On a miss the fetched window starts at the read offset, so a large read is
    /// fully served in one shot (no artificial short read at a fixed grid).
    func testMissFetchesWindowStartingAtReadOffset() {
        let payload = Data((0..<4096).map { UInt8($0 & 0xFF) })
        let source = CountingTransportByteSource(payload)
        let reader = TransportIOReader(source: source, readAheadWindow: 1024)

        XCTAssertEqual(reader.seek(offset: 500, whence: SEEK_SET), 500)
        let chunk = read(reader, count: 800) // 800 ≤ window, fully served
        XCTAssertEqual(chunk.data, Data(payload[500..<1300]))
        XCTAssertEqual(source.readCount, 1)
        XCTAssertEqual(source.readLog.first?.offset, 500, "window is anchored at the read offset")
    }
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

    func testOverflowingRelativeSeekDoesNotMoveCursor() {
        let reader = TransportIOReader(source: FakeTransportByteSource(payload))

        XCTAssertEqual(reader.seek(offset: 10, whence: SEEK_SET), 10)
        XCTAssertEqual(reader.seek(offset: Int64.max, whence: SEEK_CUR), -1)
        XCTAssertEqual(read(reader, count: 2).data, Data([10, 11]))
        XCTAssertEqual(reader.seek(offset: Int64.max, whence: SEEK_END), -1)
        XCTAssertEqual(read(reader, count: 2).data, Data([12, 13]))
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
