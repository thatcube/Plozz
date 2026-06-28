import Foundation

/// Bridges the AVIO-backed `HTTPRangeReader` to the sampler's positioned
/// `ByteRangeSource` surface so `MatroskaKeyframeSampler` can read the EBML
/// header + Cues element with a couple of ranged GETs.
///
/// The Cues fast-path constructs its OWN dedicated `HTTPRangeReader` for this
/// (never the one wired into the C session's AVIO callbacks), so the positioned
/// reads here can move the reader's cursor freely without disturbing the muxer's
/// demux position.
extension HTTPRangeReader: ByteRangeSource {
    /// Returns up to `count` bytes starting at `offset`. Fewer near EOF, empty on
    /// failure or past EOF — never throws (a failed fetch is empty), matching the
    /// `ByteRangeSource` contract.
    func readRange(at offset: Int64, count: Int) -> Data {
        guard count > 0, offset >= 0 else { return Data() }
        guard seek(offset: offset, whence: 0) == offset else { return Data() }
        var out = Data(count: count)
        let got: Int = out.withUnsafeMutableBytes { raw -> Int in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
            var total = 0
            while total < count {
                let n = read(into: base.advanced(by: total), count: count - total)
                if n <= 0 { break }   // 0 = EOF, -1 = error → return what we have
                total += n
            }
            return total
        }
        if got < count { out.removeSubrange(got..<count) }
        return out
    }
}
