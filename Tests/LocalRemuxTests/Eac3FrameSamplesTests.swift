#if canImport(UIKit)
import XCTest
import CRemuxCore

/// Pure-logic tests for `plozz_remux_eac3_frame_samples` — the bitstream probe
/// behind the `com.plozz.playback.remuxEac3FrameDur` fix. The muxer must stamp
/// the TRUE E-AC-3 syncframe sample count (numblkscod → 256/512/768/1536) as the
/// audio `frame_size` instead of assuming 1536, or a DD+/Atmos stream whose
/// frames are not 6 blocks accumulates audio-vs-video desync. Driven with
/// synthetic syncframe headers so the parser is verified without a live demux.
final class Eac3FrameSamplesTests: XCTestCase {

    /// Builds a minimal E-AC-3 syncframe header: syncword 0x0B77 then the BSI
    /// fields strmtyp(2) substreamid(3) frmsiz(11) fscod(2) numblkscod(2),
    /// MSB-first, padded out to whole bytes.
    private func eac3Header(strmtyp: UInt, substreamid: UInt, frmsiz: UInt,
                            fscod: UInt, numblkscod: UInt) -> [UInt8] {
        var bits: [UInt8] = []
        func push(_ value: UInt, _ width: Int) {
            for i in stride(from: width - 1, through: 0, by: -1) {
                bits.append(UInt8((value >> UInt(i)) & 1))
            }
        }
        push(strmtyp, 2)
        push(substreamid, 3)
        push(frmsiz, 11)
        push(fscod, 2)
        push(numblkscod, 2)
        while bits.count % 8 != 0 { bits.append(0) }

        var bytes: [UInt8] = [0x0B, 0x77]
        var i = 0
        while i < bits.count {
            var b: UInt8 = 0
            for j in 0..<8 { b = (b << 1) | bits[i + j] }
            bytes.append(b)
            i += 8
        }
        // A real packet is longer than the header; pad so size checks pass.
        bytes.append(contentsOf: [UInt8](repeating: 0, count: 8))
        return bytes
    }

    private func samples(_ bytes: [UInt8], isEac3: Bool) -> Int {
        bytes.withUnsafeBufferPointer { buf in
            Int(plozz_remux_eac3_frame_samples(buf.baseAddress, Int32(buf.count), isEac3 ? 1 : 0))
        }
    }

    // MARK: numblkscod → sample count

    func testSixBlocksIs1536() {
        let h = eac3Header(strmtyp: 0, substreamid: 0, frmsiz: 0x2C7, fscod: 0, numblkscod: 3)
        XCTAssertEqual(samples(h, isEac3: true), 1536)
    }

    func testThreeBlocksIs768() {
        let h = eac3Header(strmtyp: 0, substreamid: 0, frmsiz: 0x100, fscod: 0, numblkscod: 2)
        XCTAssertEqual(samples(h, isEac3: true), 768)
    }

    func testTwoBlocksIs512() {
        let h = eac3Header(strmtyp: 0, substreamid: 0, frmsiz: 0x100, fscod: 0, numblkscod: 1)
        XCTAssertEqual(samples(h, isEac3: true), 512)
    }

    func testOneBlockIs256() {
        let h = eac3Header(strmtyp: 0, substreamid: 0, frmsiz: 0x100, fscod: 0, numblkscod: 0)
        XCTAssertEqual(samples(h, isEac3: true), 256)
    }

    /// fscod==3 is a reduced-sample-rate stream: numblkscod is replaced by a
    /// fscod2 field and the frame is implicitly 6 blocks (1536 samples).
    func testHalfRateImpliesSixBlocks() {
        let h = eac3Header(strmtyp: 0, substreamid: 0, frmsiz: 0x100, fscod: 3, numblkscod: 0)
        XCTAssertEqual(samples(h, isEac3: true), 1536)
    }

    /// The frmsiz field varies per frame; the parser must still land on
    /// numblkscod regardless of its value (bit-alignment regression guard).
    func testFrmsizValueDoesNotShiftNumblkscod() {
        for frmsiz: UInt in [0, 1, 0x3FF, 0x555, 0x7FF] {
            let h = eac3Header(strmtyp: 0, substreamid: 0, frmsiz: frmsiz, fscod: 0, numblkscod: 2)
            XCTAssertEqual(samples(h, isEac3: true), 768, "frmsiz=\(frmsiz)")
        }
    }

    // MARK: edge cases / fallbacks

    func testAc3IsAlways1536() {
        // For AC-3 the parser short-circuits to 1536 once it sees a syncword,
        // ignoring the E-AC-3 BSI layout entirely.
        let h: [UInt8] = [0x0B, 0x77, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        XCTAssertEqual(samples(h, isEac3: false), 1536)
    }

    func testDependentLeadingFrameReturnsZero() {
        // strmtyp==1 (dependent substream first) is unexpected → bail to the
        // caller's 1536 fallback rather than misreport samples.
        let h = eac3Header(strmtyp: 1, substreamid: 0, frmsiz: 0x100, fscod: 0, numblkscod: 3)
        XCTAssertEqual(samples(h, isEac3: true), 0)
    }

    func testNoSyncwordReturnsZero() {
        let junk: [UInt8] = [0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07]
        XCTAssertEqual(samples(junk, isEac3: true), 0)
    }

    func testTooShortReturnsZero() {
        let tiny: [UInt8] = [0x0B, 0x77]
        XCTAssertEqual(samples(tiny, isEac3: true), 0)
    }

    func testSyncwordNotAtStartIsFound() {
        // A couple of leading bytes before the syncword must not defeat the scan.
        var h: [UInt8] = [0xAA, 0xBB]
        h.append(contentsOf: eac3Header(strmtyp: 0, substreamid: 0, frmsiz: 0x100,
                                        fscod: 0, numblkscod: 2))
        XCTAssertEqual(samples(h, isEac3: true), 768)
    }
}
#endif
