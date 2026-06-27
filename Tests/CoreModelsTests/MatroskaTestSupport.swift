import Foundation
@testable import CoreModels

/// Minimal EBML/Matroska byte encoder used to synthesize valid container
/// fixtures for the cue-parser tests. Mirrors the encoding rules the parser
/// decodes, so a round-trip (encode → `MatroskaCueParser` → assert) exercises the
/// real bitstream handling rather than mocks.
enum EBMLEncode {
    /// Minimal big-endian bytes of a marker-bearing element ID.
    static func id(_ value: UInt32) -> [UInt8] {
        if value <= 0xFF { return [UInt8(value)] }
        if value <= 0xFFFF { return [UInt8(value >> 8), UInt8(value & 0xFF)] }
        if value <= 0xFF_FFFF { return [UInt8(value >> 16), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)] }
        return [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    /// Data-size vint (marker bit set), minimal length unless `fixedLength` given.
    static func size(_ value: Int, fixedLength: Int? = nil) -> [UInt8] {
        var length = fixedLength ?? 1
        if fixedLength == nil {
            while length < 8 {
                let capacity = (UInt64(1) << (7 * length)) - 1
                if UInt64(value) < capacity { break }
                length += 1
            }
        }
        var bytes = [UInt8](repeating: 0, count: length)
        var v = UInt64(value)
        var i = length - 1
        while i >= 1 {
            bytes[i] = UInt8(v & 0xFF)
            v >>= 8
            i -= 1
        }
        bytes[0] = UInt8(v & 0xFF)
        bytes[0] |= UInt8(0x80 >> (length - 1))
        return bytes
    }

    static func uint(_ value: UInt64, minBytes: Int = 1) -> [UInt8] {
        var bytes: [UInt8] = []
        var v = value
        repeat {
            bytes.insert(UInt8(v & 0xFF), at: 0)
            v >>= 8
        } while v != 0
        while bytes.count < minBytes { bytes.insert(0, at: 0) }
        return bytes
    }

    static func float64(_ value: Double) -> [UInt8] {
        let bits = value.bitPattern
        var bytes: [UInt8] = []
        for shift in stride(from: 56, through: 0, by: -8) {
            bytes.append(UInt8((bits >> UInt64(shift)) & 0xFF))
        }
        return bytes
    }

    static func string(_ value: String) -> [UInt8] { Array(value.utf8) }

    /// `[ID][size][payload]`.
    static func element(_ elementID: UInt32, _ payload: [UInt8], sizeLength: Int? = nil) -> [UInt8] {
        id(elementID) + size(payload.count, fixedLength: sizeLength) + payload
    }
}

/// A synthesized Matroska file plus the ground-truth offsets/values the parser
/// should recover.
struct MKVFixture {
    var bytes: [UInt8]
    var segmentDataOffset: Int
    var cuesSegmentRelativePosition: Int
    var cuesFileOffset: Int
    var timestampScaleNs: UInt64
    var durationTicks: Double
    var cues: [MatroskaCuePoint]
    var videoCodecPrivate: [UInt8]
}

enum MKVFixtureBuilder {
    static let hevcCodecID = "V_MPEGH/ISO/HEVC"
    static let eac3CodecID = "A_EAC3"

    /// Builds a fixture with the Cues block at the **end** of the Segment (the
    /// common real-world layout), so header-only parsing must follow SeekHead.
    static func make(
        timestampScaleNs: UInt64 = 1_000_000,
        durationTicks: Double = 7_200_000, // 7200s at 1ms scale
        cuePoints: [(timeTicks: UInt64, clusterPosition: Int)] = [
            (0, 5_000),
            (6_000, 4_000_000),
            (12_000, 8_000_000),
            (18_500, 12_500_000)
        ],
        videoCodecPrivate: [UInt8] = [0x01, 0x02, 0x03, 0x04, 0xAA, 0xBB]
    ) -> MKVFixture {
        // EBML header (content irrelevant; valid framing only).
        let ebmlHeader = EBMLEncode.element(
            MatroskaID.ebmlHeader,
            EBMLEncode.element(0x4282 /* DocType */, EBMLEncode.string("matroska"))
        )

        // Info.
        let info = EBMLEncode.element(MatroskaID.info, [
            EBMLEncode.element(MatroskaID.timestampScale, EBMLEncode.uint(timestampScaleNs, minBytes: 3)),
            EBMLEncode.element(MatroskaID.duration, EBMLEncode.float64(durationTicks))
        ].flatMap { $0 })

        // Tracks: HEVC video + E-AC-3 audio.
        let videoTrack = EBMLEncode.element(MatroskaID.trackEntry, [
            EBMLEncode.element(MatroskaID.trackNumber, EBMLEncode.uint(1)),
            EBMLEncode.element(MatroskaID.trackType, EBMLEncode.uint(1)),
            EBMLEncode.element(MatroskaID.codecID, EBMLEncode.string(hevcCodecID)),
            EBMLEncode.element(MatroskaID.codecPrivate, videoCodecPrivate),
            EBMLEncode.element(MatroskaID.video, [
                EBMLEncode.element(MatroskaID.pixelWidth, EBMLEncode.uint(3840)),
                EBMLEncode.element(MatroskaID.pixelHeight, EBMLEncode.uint(2160))
            ].flatMap { $0 })
        ].flatMap { $0 })

        let audioTrack = EBMLEncode.element(MatroskaID.trackEntry, [
            EBMLEncode.element(MatroskaID.trackNumber, EBMLEncode.uint(2)),
            EBMLEncode.element(MatroskaID.trackType, EBMLEncode.uint(2)),
            EBMLEncode.element(MatroskaID.codecID, EBMLEncode.string(eac3CodecID)),
            EBMLEncode.element(MatroskaID.audio, [
                EBMLEncode.element(MatroskaID.channels, EBMLEncode.uint(6)),
                EBMLEncode.element(MatroskaID.samplingFrequency, EBMLEncode.float64(48_000))
            ].flatMap { $0 })
        ].flatMap { $0 })

        let tracks = EBMLEncode.element(MatroskaID.tracks, videoTrack + audioTrack)

        // Padding to stand in for Clusters between Tracks and the trailing Cues.
        let void = EBMLEncode.element(MatroskaID.void, [UInt8](repeating: 0, count: 32))

        // SeekHead with a fixed-width (8-byte) SeekPosition so its length is
        // independent of the cues offset value (avoids layout circularity).
        func seekHead(cuesPosition: Int) -> [UInt8] {
            let seek = EBMLEncode.element(MatroskaID.seek, [
                EBMLEncode.element(MatroskaID.seekID, EBMLEncode.id(MatroskaID.cues)),
                EBMLEncode.element(MatroskaID.seekPosition, EBMLEncode.uint(UInt64(cuesPosition), minBytes: 8))
            ].flatMap { $0 })
            return EBMLEncode.element(MatroskaID.seekHead, seek)
        }

        let seekHeadLen = seekHead(cuesPosition: 0).count
        let cuesSegmentRelativePosition = seekHeadLen + info.count + tracks.count + void.count
        let finalSeekHead = seekHead(cuesPosition: cuesSegmentRelativePosition)

        // Cues.
        let cuePointBlocks: [[UInt8]] = cuePoints.map { point in
            let trackPositions = EBMLEncode.element(MatroskaID.cueTrackPositions, [
                EBMLEncode.element(MatroskaID.cueTrack, EBMLEncode.uint(1)),
                EBMLEncode.element(MatroskaID.cueClusterPosition, EBMLEncode.uint(UInt64(point.clusterPosition), minBytes: 4))
            ].flatMap { $0 })
            return EBMLEncode.element(MatroskaID.cuePoint, [
                EBMLEncode.element(MatroskaID.cueTime, EBMLEncode.uint(point.timeTicks)),
                trackPositions
            ].flatMap { $0 })
        }
        let cues = EBMLEncode.element(MatroskaID.cues, cuePointBlocks.flatMap { $0 })

        let segmentPayload = finalSeekHead + info + tracks + void + cues
        let segmentElement = EBMLEncode.element(MatroskaID.segment, segmentPayload)
        let file = ebmlHeader + segmentElement

        let segmentDataOffset = file.count - segmentPayload.count
        let cuesFileOffset = file.count - cues.count

        return MKVFixture(
            bytes: file,
            segmentDataOffset: segmentDataOffset,
            cuesSegmentRelativePosition: cuesSegmentRelativePosition,
            cuesFileOffset: cuesFileOffset,
            timestampScaleNs: timestampScaleNs,
            durationTicks: durationTicks,
            cues: cuePoints.map { MatroskaCuePoint(timeTicks: $0.timeTicks, clusterPosition: $0.clusterPosition) },
            videoCodecPrivate: videoCodecPrivate
        )
    }
}
