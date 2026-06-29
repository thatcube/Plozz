#if canImport(UIKit)
import XCTest
import Foundation
@testable import LocalRemux

/// Pure-logic tests for `RemuxSegmenter.boxScan` — the detector behind the two
/// make-or-break guarantees the engine logs on device:
///   • Dolby Vision renders only if the fMP4 carries the `dvh1` sample entry AND
///     a `dvcC`/`dvvC` config box (Profile 5 has no HDR10 fallback → black screen
///     without it).
///   • Atmos/JOC survives only if E-AC-3 kept its `dec3` config through `-c copy`.
/// Driven with synthetic byte buffers so the detection logic is verified without
/// a live FFmpeg mux.
final class RemuxBoxScanTests: XCTestCase {

    private func buffer(_ fourCCs: [String]) -> Data {
        // Emulate an fMP4: 4-byte size + four-cc per box, contiguous.
        var data = Data()
        for cc in fourCCs {
            data.append(contentsOf: [0, 0, 0, 8])
            data.append(cc.data(using: .ascii)!)
        }
        return data
    }

    func testDetectsDoViAndAtmosBoxes() {
        let data = buffer(["ftyp", "moov", "trak", "dvh1", "dvcC", "ec-3", "dec3"])
        let scan = RemuxSegmenter.boxScan(data)
        XCTAssertTrue(scan.hasDVH1, "must detect dvh1 sample entry")
        XCTAssertTrue(scan.hasDoViConfig, "must detect dvcC/dvvC DoVi config")
        XCTAssertTrue(scan.hasDec3, "must detect E-AC-3 dec3 (Atmos)")
        XCTAssertTrue(scan.found.contains("ftyp"))
        XCTAssertTrue(scan.found.contains("moov"))
    }

    func testDvvCAlsoCountsAsDoViConfig() {
        let scan = RemuxSegmenter.boxScan(buffer(["dvh1", "dvvC"]))
        XCTAssertTrue(scan.hasDoViConfig)
    }

    func testHev1WithoutDoViConfigIsFlagged() {
        // The black-screen risk case: plain hev1 sample entry, no DoVi config.
        let scan = RemuxSegmenter.boxScan(buffer(["ftyp", "moov", "hev1", "hvcC", "mp4a"]))
        XCTAssertFalse(scan.hasDVH1)
        XCTAssertFalse(scan.hasDoViConfig)
        XCTAssertFalse(scan.hasDec3)
        XCTAssertTrue(scan.found.contains("hev1"))
    }

    func testAC3IsNotDec3() {
        let scan = RemuxSegmenter.boxScan(buffer(["dvh1", "dvcC", "ac-3", "dac3"]))
        XCTAssertTrue(scan.hasDVH1)
        XCTAssertTrue(scan.hasDoViConfig)
        XCTAssertFalse(scan.hasDec3) // AC-3 (dac3), not E-AC-3 (dec3)
    }

    func testEmptyBufferDetectsNothing() {
        let scan = RemuxSegmenter.boxScan(Data())
        XCTAssertFalse(scan.hasDVH1)
        XCTAssertFalse(scan.hasDoViConfig)
        XCTAssertFalse(scan.hasDec3)
        XCTAssertTrue(scan.found.isEmpty)
    }

    func testFoundMarkersAreInCanonicalOrder() {
        // `found` is filtered from the canonical marker list, so ftyp precedes
        // moov precedes the sample entries regardless of byte order.
        let scan = RemuxSegmenter.boxScan(buffer(["dec3", "ec-3", "dvh1", "moov", "ftyp"]))
        let ftyp = scan.found.firstIndex(of: "ftyp")
        let moov = scan.found.firstIndex(of: "moov")
        let dvh1 = scan.found.firstIndex(of: "dvh1")
        XCTAssertNotNil(ftyp); XCTAssertNotNil(moov); XCTAssertNotNil(dvh1)
        XCTAssertLessThan(ftyp!, moov!)
        XCTAssertLessThan(moov!, dvh1!)
    }
}
#endif
