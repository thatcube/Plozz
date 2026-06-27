import Foundation
import CoreModels
import CFFmpegRemux

/// `@convention(c)` trampoline for libavformat reads. `opaque` is an unretained
/// pointer to the `MKVRangeReader`; returns bytes read (0 = EOF, -1 = error).
private func remuxReadThunk(
    _ opaque: UnsafeMutableRawPointer?,
    _ buffer: UnsafeMutablePointer<UInt8>?,
    _ size: Int32
) -> Int32 {
    guard let opaque, let buffer, size > 0 else { return 0 }
    let reader = Unmanaged<MKVRangeReader>.fromOpaque(opaque).takeUnretainedValue()
    return Int32(reader.avioRead(buffer: buffer, count: Int(size)))
}

/// `@convention(c)` trampoline for libavformat seeks (POSIX whence + AVSEEK_SIZE).
private func remuxSeekThunk(
    _ opaque: UnsafeMutableRawPointer?,
    _ offset: Int64,
    _ whence: Int32
) -> Int64 {
    guard let opaque else { return -1 }
    let reader = Unmanaged<MKVRangeReader>.fromOpaque(opaque).takeUnretainedValue()
    return reader.avioSeek(offset: offset, whence: whence)
}

/// Swift face of the `CFFmpegRemux` shim: turns "give me the init segment" and
/// "give me bytes for [start,end)" into valid fMP4/CMAF using `-c copy` only.
///
/// The underlying C handle is single-threaded, so every call is serialised on a
/// dedicated queue. The reader is retained for the handle's lifetime because the
/// C side holds an unretained pointer to it for its AVIO callbacks.
final class FFmpegSegmentRemuxer: @unchecked Sendable {
    enum RemuxError: Error, CustomStringConvertible {
        case open(String)
        case segment(String)

        var description: String {
            switch self {
            case .open(let m): return "remux open failed: \(m)"
            case .segment(let m): return "remux segment failed: \(m)"
            }
        }
    }

    private let reader: MKVRangeReader
    private let queue = DispatchQueue(label: "com.plozz.remux.ffmpeg")
    private var handle: OpaquePointer?

    init(reader: MKVRangeReader) {
        self.reader = reader
    }

    /// Opens the input and probes streams. Must be called once before segmenting.
    func open() throws {
        try queue.sync {
            guard handle == nil else { return }
            guard let created = plozz_remuxer_create() else {
                throw RemuxError.open("allocation failed")
            }
            let opaque = Unmanaged.passUnretained(reader).toOpaque()
            let size = (try? reader.totalSize()) ?? 0
            let rc = plozz_remuxer_open(created, remuxReadThunk, remuxSeekThunk, opaque, size)
            guard rc == PLOZZ_REMUX_OK else {
                let message = String(cString: plozz_remuxer_last_error(created))
                plozz_remuxer_destroy(created)
                throw RemuxError.open(message)
            }
            handle = created
        }
    }

    /// Container duration in seconds, as seen by FFmpeg (0 if unknown).
    var durationSeconds: Double {
        queue.sync {
            guard let handle else { return 0 }
            return plozz_remuxer_duration_seconds(handle)
        }
    }

    /// The deterministic CMAF init segment (ftyp + empty moov) for EXT-X-MAP.
    func initSegment() throws -> Data {
        try queue.sync {
            guard let handle else { throw RemuxError.segment("not opened") }
            var buffer: UnsafeMutablePointer<UInt8>?
            var length: Int32 = 0
            let rc = plozz_remuxer_init_segment(handle, &buffer, &length)
            guard rc == PLOZZ_REMUX_OK, let buffer, length > 0 else {
                throw RemuxError.segment(String(cString: plozz_remuxer_last_error(handle)))
            }
            defer { plozz_free(buffer) }
            return Data(bytes: buffer, count: Int(length))
        }
    }

    /// One CMAF media segment covering the keyframe range `[start, end)`.
    func makeSegment(index: Int, start: Double, end: Double) throws -> Data {
        try queue.sync {
            guard let handle else { throw RemuxError.segment("not opened") }
            var buffer: UnsafeMutablePointer<UInt8>?
            var length: Int32 = 0
            let rc = plozz_remuxer_make_segment(handle, Int32(index), start, end, &buffer, &length)
            guard rc == PLOZZ_REMUX_OK, let buffer, length > 0 else {
                throw RemuxError.segment(String(cString: plozz_remuxer_last_error(handle)))
            }
            defer { plozz_free(buffer) }
            return Data(bytes: buffer, count: Int(length))
        }
    }

    func close() {
        queue.sync {
            if let handle {
                plozz_remuxer_destroy(handle)
                self.handle = nil
            }
        }
    }

    deinit {
        if let handle {
            plozz_remuxer_destroy(handle)
        }
    }
}
