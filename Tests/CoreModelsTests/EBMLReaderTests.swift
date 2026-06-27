import XCTest
@testable import CoreModels

final class EBMLReaderTests: XCTestCase {
    func testReadsFourOctetElementID() {
        var reader = EBMLReader(data: [0x1A, 0x45, 0xDF, 0xA3])
        XCTAssertEqual(reader.readID(), 0x1A45_DFA3)
        XCTAssertEqual(reader.cursor, 4)
    }

    func testReadsSingleOctetSize() {
        var reader = EBMLReader(data: [0x84])
        let size = reader.readSize()
        XCTAssertEqual(size?.size, 4)
        XCTAssertEqual(size?.length, 1)
    }

    func testReadsTwoOctetSize() {
        // 0x40 0x7F → length 2, value 0x7F = 127.
        var reader = EBMLReader(data: [0x40, 0x7F])
        XCTAssertEqual(reader.readSize()?.size, 127)
    }

    func testUnknownSizeIsReportedAsNil() {
        // 0x01 0xFF 0xFF 0xFF 0xFF 0xFF 0xFF 0xFF → all-ones 8-octet "unknown".
        var reader = EBMLReader(data: [0xFF])
        let size = reader.readSize()
        XCTAssertNil(size?.size)
        XCTAssertEqual(size?.length, 1)
    }

    func testReadsUnsignedIntegerPayload() {
        let reader = EBMLReader(data: [0x00, 0x0F, 0x42, 0x40])
        XCTAssertEqual(reader.uint(atLocal: 0, size: 4), 1_000_000)
    }

    func testReadsDoublePayload() {
        let bytes = EBMLEncode.float64(48_000)
        let reader = EBMLReader(data: bytes)
        XCTAssertEqual(reader.double(atLocal: 0, size: 8), 48_000)
    }

    func testReadsFloat32Payload() {
        let value: Float = 23.976
        var bits = value.bitPattern.bigEndian
        let bytes = withUnsafeBytes(of: &bits) { Array($0) }
        let reader = EBMLReader(data: bytes)
        XCTAssertEqual(reader.double(atLocal: 0, size: 4)!, Double(value), accuracy: 0.001)
    }

    func testReadsStringPayloadTrimmingNuls() {
        let reader = EBMLReader(data: Array("V_MPEGH/ISO/HEVC".utf8) + [0x00, 0x00])
        XCTAssertEqual(reader.string(atLocal: 0, size: 18), "V_MPEGH/ISO/HEVC")
    }

    func testReadElementParsesHeaderAndAdvancesToPayload() {
        let element = EBMLEncode.element(MatroskaID.timestampScale, EBMLEncode.uint(1_000_000, minBytes: 3))
        var reader = EBMLReader(data: element)
        let parsed = reader.readElement()
        XCTAssertEqual(parsed?.id, MatroskaID.timestampScale)
        XCTAssertEqual(parsed?.size, 3)
        XCTAssertEqual(reader.cursor, parsed?.localDataOffset)
    }

    func testTruncatedBufferReturnsNilInsteadOfTrapping() {
        var reader = EBMLReader(data: [0x1A, 0x45]) // partial 4-octet ID
        XCTAssertNil(reader.readID())
        XCTAssertEqual(reader.cursor, 0, "cursor must not advance on a truncated read")
    }

    func testAbsolutePositionUsesBaseOffset() {
        var reader = EBMLReader(data: [0x84, 0x00], baseOffset: 1_000)
        _ = reader.readSize()
        XCTAssertEqual(reader.absolutePosition, 1_001)
    }
}
