import Foundation

/// Matroska element IDs (full, marker-bearing form) needed for cue-driven seeking.
enum MatroskaID {
    static let ebmlHeader: UInt32 = 0x1A45_DFA3
    static let segment: UInt32 = 0x1853_8067

    static let seekHead: UInt32 = 0x114D_9B74
    static let seek: UInt32 = 0x4DBB
    static let seekID: UInt32 = 0x53AB
    static let seekPosition: UInt32 = 0x53AC

    static let info: UInt32 = 0x1549_A966
    static let timestampScale: UInt32 = 0x2AD7_B1
    static let duration: UInt32 = 0x4489

    static let tracks: UInt32 = 0x1654_AE6B
    static let trackEntry: UInt32 = 0xAE
    static let trackNumber: UInt32 = 0xD7
    static let trackType: UInt32 = 0x83
    static let codecID: UInt32 = 0x86
    static let codecPrivate: UInt32 = 0x63A2
    static let video: UInt32 = 0xE0
    static let pixelWidth: UInt32 = 0xB0
    static let pixelHeight: UInt32 = 0xBA
    static let audio: UInt32 = 0xE1
    static let channels: UInt32 = 0x9F
    static let samplingFrequency: UInt32 = 0xB5

    static let cues: UInt32 = 0x1C53_BB6B
    static let cuePoint: UInt32 = 0xBB
    static let cueTime: UInt32 = 0xB3
    static let cueTrackPositions: UInt32 = 0xB7
    static let cueTrack: UInt32 = 0xF7
    static let cueClusterPosition: UInt32 = 0xF1
    static let cueRelativePosition: UInt32 = 0xF0

    static let cluster: UInt32 = 0x1F43_B675
    static let void: UInt32 = 0xEC
    static let crc32: UInt32 = 0xBF
}

/// A decoded Matroska track entry (only the fields the remuxer needs).
public struct MatroskaTrack: Equatable, Sendable {
    public var number: UInt64
    public var type: UInt64
    public var codecID: String
    public var codecPrivate: [UInt8]?
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    public var channels: Int?
    public var samplingFrequency: Double?

    public init(
        number: UInt64,
        type: UInt64,
        codecID: String,
        codecPrivate: [UInt8]? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        channels: Int? = nil,
        samplingFrequency: Double? = nil
    ) {
        self.number = number
        self.type = type
        self.codecID = codecID
        self.codecPrivate = codecPrivate
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.channels = channels
        self.samplingFrequency = samplingFrequency
    }

    public var isVideo: Bool { type == 1 }
    public var isAudio: Bool { type == 2 }
}

/// One Matroska cue: a keyframe's presentation time and the byte offset of the
/// Cluster that contains it (expressed relative to the Segment's data start).
public struct MatroskaCuePoint: Equatable, Sendable {
    /// Presentation time in TimestampScale units.
    public var timeTicks: UInt64
    /// Byte offset of the cue's Cluster, relative to the Segment data start.
    public var clusterPosition: Int

    public init(timeTicks: UInt64, clusterPosition: Int) {
        self.timeTicks = timeTicks
        self.clusterPosition = clusterPosition
    }

    public func timeSeconds(timestampScaleNs: UInt64) -> Double {
        Double(timeTicks) * Double(timestampScaleNs) / 1_000_000_000
    }
}

/// Everything the cue-driven local-remux pipeline extracts from a Matroska
/// header (and, when present, its Cues block) without decoding any media.
public struct MatroskaSummary: Equatable, Sendable {
    /// Absolute file offset of the Segment element's data start. All
    /// SeekHead/Cue positions are relative to this.
    public var segmentDataOffset: Int
    /// `TimestampScale` in nanoseconds (Matroska default 1,000,000 = 1 ms).
    public var timestampScaleNs: UInt64
    /// Segment `Duration` in TimestampScale units, if present.
    public var durationTicks: Double?
    public var tracks: [MatroskaTrack]
    /// SeekHead map: top-level element ID → Segment-relative byte position.
    public var seekEntries: [UInt32: Int]
    /// Cue points, sorted by time (may be empty if Cues lives elsewhere).
    public var cues: [MatroskaCuePoint]
    /// Segment-relative position of the Cues element, if known (from SeekHead
    /// or from an inline Cues element).
    public var cuesSegmentRelativePosition: Int?

    public init(
        segmentDataOffset: Int,
        timestampScaleNs: UInt64 = 1_000_000,
        durationTicks: Double? = nil,
        tracks: [MatroskaTrack] = [],
        seekEntries: [UInt32: Int] = [:],
        cues: [MatroskaCuePoint] = [],
        cuesSegmentRelativePosition: Int? = nil
    ) {
        self.segmentDataOffset = segmentDataOffset
        self.timestampScaleNs = timestampScaleNs
        self.durationTicks = durationTicks
        self.tracks = tracks
        self.seekEntries = seekEntries
        self.cues = cues
        self.cuesSegmentRelativePosition = cuesSegmentRelativePosition
    }

    public var durationSeconds: Double? {
        guard let durationTicks else { return nil }
        return durationTicks * Double(timestampScaleNs) / 1_000_000_000
    }

    public var videoTrack: MatroskaTrack? { tracks.first(where: { $0.isVideo }) }
    public var audioTrack: MatroskaTrack? { tracks.first(where: { $0.isAudio }) }

    /// True once the Cues block has been parsed into `cues`.
    public var hasCues: Bool { !cues.isEmpty }

    /// Absolute file offset of a Segment-relative position.
    public func absoluteOffset(forSegmentRelative pos: Int) -> Int {
        segmentDataOffset + pos
    }

    /// Absolute file offset where the Cues element begins, if its position is
    /// known but it has not yet been read into this summary.
    public var cuesAbsoluteOffset: Int? {
        cuesSegmentRelativePosition.map { absoluteOffset(forSegmentRelative: $0) }
    }
}

/// Parses the Matroska header (and Cues, inline or out-of-line) into a
/// `MatroskaSummary`. Pure logic — the caller owns the ranged byte reads.
public enum MatroskaCueParser {
    /// Parses whatever top-level Segment children are present in `data`.
    ///
    /// `data` is expected to begin at the start of the file (or at least include
    /// the EBML header + Segment header). It tolerates a truncated tail: elements
    /// that extend past the buffer (typically the first Cluster, or a Cues block
    /// stored at the end of the file) simply stop the walk, and what was found so
    /// far is returned. When the Cues block lives past the buffer, its position is
    /// still reported via `cuesSegmentRelativePosition` (read from SeekHead) so
    /// the caller can fetch and parse it with ``parseCues(data:baseOffset:summary:)``.
    public static func parseHeader(_ data: [UInt8], baseOffset: Int = 0) -> MatroskaSummary? {
        var reader = EBMLReader(data: data, baseOffset: baseOffset)

        // Find the Segment element, skipping the EBML header (and any leading
        // Void/CRC). We do not require the EBML header to be present.
        var segment: EBMLReader.Element?
        while reader.remaining > 0 {
            guard let element = reader.readElement() else { break }
            if element.id == MatroskaID.segment {
                segment = element
                break
            }
            reader.skip(element)
        }
        guard let segment else { return nil }

        let segmentDataAbsolute = baseOffset + segment.localDataOffset
        var summary = MatroskaSummary(segmentDataOffset: segmentDataAbsolute)

        // Walk the Segment's top-level children that fall within the buffer.
        let segmentEndLocal = segment.size.map { min(segment.localDataOffset + $0, data.count) } ?? data.count
        reader.seek(toLocal: segment.localDataOffset)
        while reader.cursor < segmentEndLocal {
            let childStart = reader.cursor
            guard let child = reader.readElement() else { break }
            let payloadEndLocal = child.size.map { child.localDataOffset + $0 }

            switch child.id {
            case MatroskaID.seekHead:
                if let end = payloadEndLocal, end <= data.count {
                    parseSeekHead(&reader, child: child, into: &summary)
                }
            case MatroskaID.info:
                if let end = payloadEndLocal, end <= data.count {
                    parseInfo(&reader, child: child, into: &summary)
                }
            case MatroskaID.tracks:
                if let end = payloadEndLocal, end <= data.count {
                    parseTracks(&reader, child: child, into: &summary)
                }
            case MatroskaID.cues:
                summary.cuesSegmentRelativePosition = childStart + baseOffset - segmentDataAbsolute
                if let end = payloadEndLocal, end <= data.count {
                    parseCuesElement(&reader, child: child, into: &summary)
                }
            default:
                break
            }

            // Advance to the next sibling; bail if the child runs past the buffer.
            guard let end = payloadEndLocal, end <= data.count else { break }
            reader.seek(toLocal: end)
        }

        summary.cues.sort { $0.timeTicks < $1.timeTicks }
        return summary
    }

    public static func parseHeader(_ data: Data, baseOffset: Int = 0) -> MatroskaSummary? {
        parseHeader([UInt8](data), baseOffset: baseOffset)
    }

    /// Parses a Cues block from a buffer that begins at (or contains) the Cues
    /// element, merging the cue points into an existing summary.
    ///
    /// Use this when the header walk reported `cuesSegmentRelativePosition` but
    /// did not contain the Cues bytes (Cues stored at the end of the file). The
    /// returned summary carries the merged, time-sorted cue list.
    public static func parseCues(
        _ data: [UInt8],
        baseOffset: Int,
        summary: MatroskaSummary
    ) -> MatroskaSummary {
        var reader = EBMLReader(data: data, baseOffset: baseOffset)
        var result = summary
        while reader.remaining > 0 {
            guard let element = reader.readElement() else { break }
            if element.id == MatroskaID.cues {
                parseCuesElement(&reader, child: element, into: &result)
                break
            }
            // Skip non-Cues siblings (CRC/Void or a misaligned read).
            reader.skip(element)
        }
        result.cues.sort { $0.timeTicks < $1.timeTicks }
        return result
    }

    public static func parseCues(
        _ data: Data,
        baseOffset: Int,
        summary: MatroskaSummary
    ) -> MatroskaSummary {
        parseCues([UInt8](data), baseOffset: baseOffset, summary: summary)
    }

    // MARK: - Section parsers

    private static func parseSeekHead(
        _ reader: inout EBMLReader,
        child: EBMLReader.Element,
        into summary: inout MatroskaSummary
    ) {
        guard let size = child.size else { return }
        let end = child.localDataOffset + size
        reader.seek(toLocal: child.localDataOffset)
        while reader.cursor < end {
            guard let seek = reader.readElement(), seek.id == MatroskaID.seek, let seekSize = seek.size else {
                if let e = reader.readElementSkip(at: reader.cursor) { reader.seek(toLocal: e) } else { break }
                continue
            }
            let seekEnd = seek.localDataOffset + seekSize
            var seekID: UInt32?
            var position: Int?
            reader.seek(toLocal: seek.localDataOffset)
            while reader.cursor < seekEnd {
                guard let field = reader.readElement(), let fieldSize = field.size else { break }
                switch field.id {
                case MatroskaID.seekID:
                    if let raw = reader.bytes(atLocal: field.localDataOffset, size: fieldSize) {
                        seekID = decodeElementID(raw)
                    }
                case MatroskaID.seekPosition:
                    position = reader.uint(atLocal: field.localDataOffset, size: fieldSize).map(Int.init)
                default:
                    break
                }
                reader.seek(toLocal: field.localDataOffset + fieldSize)
            }
            if let seekID, let position {
                summary.seekEntries[seekID] = position
                if seekID == MatroskaID.cues, summary.cuesSegmentRelativePosition == nil {
                    summary.cuesSegmentRelativePosition = position
                }
            }
            reader.seek(toLocal: seekEnd)
        }
    }

    private static func parseInfo(
        _ reader: inout EBMLReader,
        child: EBMLReader.Element,
        into summary: inout MatroskaSummary
    ) {
        guard let size = child.size else { return }
        let end = child.localDataOffset + size
        reader.seek(toLocal: child.localDataOffset)
        while reader.cursor < end {
            guard let field = reader.readElement(), let fieldSize = field.size else { break }
            switch field.id {
            case MatroskaID.timestampScale:
                if let scale = reader.uint(atLocal: field.localDataOffset, size: fieldSize), scale > 0 {
                    summary.timestampScaleNs = scale
                }
            case MatroskaID.duration:
                summary.durationTicks = reader.double(atLocal: field.localDataOffset, size: fieldSize)
            default:
                break
            }
            reader.seek(toLocal: field.localDataOffset + fieldSize)
        }
    }

    private static func parseTracks(
        _ reader: inout EBMLReader,
        child: EBMLReader.Element,
        into summary: inout MatroskaSummary
    ) {
        guard let size = child.size else { return }
        let end = child.localDataOffset + size
        reader.seek(toLocal: child.localDataOffset)
        while reader.cursor < end {
            guard let entry = reader.readElement(), let entrySize = entry.size else { break }
            if entry.id == MatroskaID.trackEntry {
                if let track = parseTrackEntry(&reader, entry: entry) {
                    summary.tracks.append(track)
                }
            }
            reader.seek(toLocal: entry.localDataOffset + entrySize)
        }
    }

    private static func parseTrackEntry(
        _ reader: inout EBMLReader,
        entry: EBMLReader.Element
    ) -> MatroskaTrack? {
        guard let size = entry.size else { return nil }
        let end = entry.localDataOffset + size
        var number: UInt64?
        var type: UInt64?
        var codecID = ""
        var codecPrivate: [UInt8]?
        var pixelWidth: Int?
        var pixelHeight: Int?
        var channels: Int?
        var samplingFrequency: Double?

        reader.seek(toLocal: entry.localDataOffset)
        while reader.cursor < end {
            guard let field = reader.readElement(), let fieldSize = field.size else { break }
            switch field.id {
            case MatroskaID.trackNumber:
                number = reader.uint(atLocal: field.localDataOffset, size: fieldSize)
            case MatroskaID.trackType:
                type = reader.uint(atLocal: field.localDataOffset, size: fieldSize)
            case MatroskaID.codecID:
                codecID = reader.string(atLocal: field.localDataOffset, size: fieldSize) ?? ""
            case MatroskaID.codecPrivate:
                codecPrivate = reader.bytes(atLocal: field.localDataOffset, size: fieldSize)
            case MatroskaID.video:
                (pixelWidth, pixelHeight) = parseVideoBlock(&reader, field: field)
                reader.seek(toLocal: field.localDataOffset)
            case MatroskaID.audio:
                (channels, samplingFrequency) = parseAudioBlock(&reader, field: field)
                reader.seek(toLocal: field.localDataOffset)
            default:
                break
            }
            reader.seek(toLocal: field.localDataOffset + fieldSize)
        }

        guard let number, let type else { return nil }
        return MatroskaTrack(
            number: number,
            type: type,
            codecID: codecID,
            codecPrivate: codecPrivate,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            channels: channels,
            samplingFrequency: samplingFrequency
        )
    }

    private static func parseVideoBlock(
        _ reader: inout EBMLReader,
        field: EBMLReader.Element
    ) -> (Int?, Int?) {
        guard let size = field.size else { return (nil, nil) }
        let end = field.localDataOffset + size
        var width: Int?
        var height: Int?
        reader.seek(toLocal: field.localDataOffset)
        while reader.cursor < end {
            guard let sub = reader.readElement(), let subSize = sub.size else { break }
            switch sub.id {
            case MatroskaID.pixelWidth:
                width = reader.uint(atLocal: sub.localDataOffset, size: subSize).map(Int.init)
            case MatroskaID.pixelHeight:
                height = reader.uint(atLocal: sub.localDataOffset, size: subSize).map(Int.init)
            default:
                break
            }
            reader.seek(toLocal: sub.localDataOffset + subSize)
        }
        return (width, height)
    }

    private static func parseAudioBlock(
        _ reader: inout EBMLReader,
        field: EBMLReader.Element
    ) -> (Int?, Double?) {
        guard let size = field.size else { return (nil, nil) }
        let end = field.localDataOffset + size
        var channels: Int?
        var frequency: Double?
        reader.seek(toLocal: field.localDataOffset)
        while reader.cursor < end {
            guard let sub = reader.readElement(), let subSize = sub.size else { break }
            switch sub.id {
            case MatroskaID.channels:
                channels = reader.uint(atLocal: sub.localDataOffset, size: subSize).map(Int.init)
            case MatroskaID.samplingFrequency:
                frequency = reader.double(atLocal: sub.localDataOffset, size: subSize)
            default:
                break
            }
            reader.seek(toLocal: sub.localDataOffset + subSize)
        }
        return (channels, frequency)
    }

    private static func parseCuesElement(
        _ reader: inout EBMLReader,
        child: EBMLReader.Element,
        into summary: inout MatroskaSummary
    ) {
        guard let size = child.size else { return }
        let end = child.localDataOffset + size
        reader.seek(toLocal: child.localDataOffset)
        while reader.cursor < end {
            guard let point = reader.readElement(), let pointSize = point.size else { break }
            if point.id == MatroskaID.cuePoint {
                if let cue = parseCuePoint(&reader, point: point) {
                    summary.cues.append(cue)
                }
            }
            reader.seek(toLocal: point.localDataOffset + pointSize)
        }
    }

    private static func parseCuePoint(
        _ reader: inout EBMLReader,
        point: EBMLReader.Element
    ) -> MatroskaCuePoint? {
        guard let size = point.size else { return nil }
        let end = point.localDataOffset + size
        var time: UInt64?
        var clusterPosition: Int?
        reader.seek(toLocal: point.localDataOffset)
        while reader.cursor < end {
            guard let field = reader.readElement(), let fieldSize = field.size else { break }
            switch field.id {
            case MatroskaID.cueTime:
                time = reader.uint(atLocal: field.localDataOffset, size: fieldSize)
            case MatroskaID.cueTrackPositions:
                if clusterPosition == nil {
                    clusterPosition = parseClusterPosition(&reader, field: field)
                    reader.seek(toLocal: field.localDataOffset)
                }
            default:
                break
            }
            reader.seek(toLocal: field.localDataOffset + fieldSize)
        }
        guard let time, let clusterPosition else { return nil }
        return MatroskaCuePoint(timeTicks: time, clusterPosition: clusterPosition)
    }

    private static func parseClusterPosition(
        _ reader: inout EBMLReader,
        field: EBMLReader.Element
    ) -> Int? {
        guard let size = field.size else { return nil }
        let end = field.localDataOffset + size
        var position: Int?
        reader.seek(toLocal: field.localDataOffset)
        while reader.cursor < end {
            guard let sub = reader.readElement(), let subSize = sub.size else { break }
            if sub.id == MatroskaID.cueClusterPosition {
                position = reader.uint(atLocal: sub.localDataOffset, size: subSize).map(Int.init)
            }
            reader.seek(toLocal: sub.localDataOffset + subSize)
        }
        return position
    }

    /// Decodes a stored element-ID payload (the marker-bearing bytes) into a
    /// 32-bit ID for SeekHead `SeekID` matching.
    private static func decodeElementID(_ bytes: [UInt8]) -> UInt32? {
        guard !bytes.isEmpty, bytes.count <= 4 else { return nil }
        var value: UInt32 = 0
        for byte in bytes {
            value = (value << 8) | UInt32(byte)
        }
        return value
    }
}

private extension EBMLReader {
    /// Best-effort recovery helper: returns the local offset just past the next
    /// element header at `index`, used to resync a malformed SeekHead walk.
    func readElementSkip(at index: Int) -> Int? {
        var probe = self
        probe.seek(toLocal: index)
        guard let element = probe.readElement() else { return nil }
        if let size = element.size {
            return element.localDataOffset + size
        }
        return nil
    }
}
