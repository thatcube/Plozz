import XCTest
@testable import CoreModels

final class BIFIndexTests: XCTestCase {
    // MARK: Synthetic BIF builder

    /// Builds a minimal but spec-correct BIF blob from a list of frame payloads
    /// at a fixed `separationMs` interval, so the parser can be exercised without
    /// a live Plex server.
    private func makeBIF(separationMs: UInt32, frames: [[UInt8]]) -> Data {
        var data = [UInt8]()
        func appendU32(_ value: UInt32, into bytes: inout [UInt8]) {
            bytes.append(UInt8(value & 0xFF))
            bytes.append(UInt8((value >> 8) & 0xFF))
            bytes.append(UInt8((value >> 16) & 0xFF))
            bytes.append(UInt8((value >> 24) & 0xFF))
        }

        // Header (64 bytes): magic + version + count + separation + reserved.
        data.append(contentsOf: BIFIndex.magic)
        appendU32(0, into: &data)                       // version
        appendU32(UInt32(frames.count), into: &data)    // number of frames
        appendU32(separationMs, into: &data)            // framewise separation
        data.append(contentsOf: [UInt8](repeating: 0, count: 64 - data.count))

        // Index: N + 1 entries of [timestamp][absolute offset]. First frame sits
        // right after the index; each subsequent offset advances by frame length.
        let indexEntries = frames.count + 1
        var offset = 64 + indexEntries * 8
        var index = [UInt8]()
        for (i, frame) in frames.enumerated() {
            appendU32(UInt32(i), into: &index)
            appendU32(UInt32(offset), into: &index)
            offset += frame.count
        }
        // End-of-data sentinel: timestamp 0xFFFFFFFF, offset = EOF.
        appendU32(0xFFFF_FFFF, into: &index)
        appendU32(UInt32(offset), into: &index)

        data.append(contentsOf: index)
        for frame in frames { data.append(contentsOf: frame) }
        return Data(data)
    }

    // MARK: Tests

    func testParsesHeaderAndFrameRanges() throws {
        let f0: [UInt8] = [0xAA, 0xAA, 0xAA]
        let f1: [UInt8] = [0xBB, 0xBB]
        let f2: [UInt8] = [0xCC, 0xCC, 0xCC, 0xCC]
        let data = makeBIF(separationMs: 5000, frames: [f0, f1, f2])

        let index = try XCTUnwrap(BIFIndex(data: data))
        XCTAssertEqual(index.framewiseSeparationMs, 5000)
        XCTAssertEqual(index.frames.count, 3)

        // Frame 0 starts right after the 4-entry (N+1) index.
        let firstOffset = 64 + 4 * 8
        XCTAssertEqual(index.frames[0].offset, firstOffset)
        XCTAssertEqual(index.frames[0].length, 3)
        XCTAssertEqual(index.frames[1].length, 2)
        XCTAssertEqual(index.frames[2].length, 4)
        XCTAssertEqual(index.frames.map(\.timestampMs), [0, 5000, 10000])

        // The sliced bytes must match the payloads we packed in.
        XCTAssertEqual([UInt8](data.subdata(in: index.frames[0].range)), f0)
        XCTAssertEqual([UInt8](data.subdata(in: index.frames[1].range)), f1)
        XCTAssertEqual([UInt8](data.subdata(in: index.frames[2].range)), f2)
    }

    func testFrameLookupQuantizesBySeparation() throws {
        let frames = (0..<5).map { [UInt8(0x10 + $0)] }
        let index = try XCTUnwrap(BIFIndex(data: makeBIF(separationMs: 10000, frames: frames)))

        XCTAssertEqual(index.frameIndex(forSeconds: 0), 0)
        XCTAssertEqual(index.frameIndex(forSeconds: 9.9), 0)
        XCTAssertEqual(index.frameIndex(forSeconds: 10), 1)
        XCTAssertEqual(index.frameIndex(forSeconds: 25), 2)
        // Past the end clamps to the last frame.
        XCTAssertEqual(index.frameIndex(forSeconds: 9_999), 4)
        // Negative positions clamp to the first frame.
        XCTAssertEqual(index.frameIndex(forSeconds: -5), 0)
    }

    func testZeroSeparationDefaultsToOneSecond() throws {
        let index = try XCTUnwrap(BIFIndex(data: makeBIF(separationMs: 0, frames: [[0x01], [0x02]])))
        XCTAssertEqual(index.framewiseSeparationMs, 1000)
        XCTAssertEqual(index.frameIndex(forSeconds: 1.5), 1)
    }

    func testRejectsBadMagic() {
        var bytes = [UInt8](repeating: 0, count: 128)
        bytes[0] = 0x00 // corrupt the magic
        XCTAssertNil(BIFIndex(data: Data(bytes)))
    }

    func testRejectsTruncatedAndEmpty() {
        XCTAssertNil(BIFIndex(data: Data()))
        XCTAssertNil(BIFIndex(data: Data(BIFIndex.magic))) // header only, no index
    }
}
