#if canImport(AVFoundation)
import Foundation
import CoreModels

/// The off-main worker that owns the live remux pipeline for one title: the range
/// reader, the FFmpeg `-c copy` remuxer, the loopback HTTP server, and the pre-computed
/// VOD timeline. Built once on a background task; all members are thread-safe so the
/// session can read metrics from the main actor while the server serves segments.
final class CueDrivenRemuxBackend: @unchecked Sendable {
    /// Sendable metrics snapshot for the diagnostics overlay.
    struct Metrics: Sendable {
        var segmentsServed: Int
        var bytesPulled: Int64
        var memoryBytes: Int64
    }

    enum BuildError: Error, CustomStringConvertible {
        case parseFailed
        case noCues
        case emptyTimeline

        var description: String {
            switch self {
            case .parseFailed: return "could not parse Matroska header"
            case .noCues: return "MKV has no Cues/SeekHead index"
            case .emptyTimeline: return "segment planner produced no segments"
            }
        }
    }

    /// Max bytes pulled for the header probe before consulting the SeekHead for Cues.
    private static let headProbeBytes: Int64 = 8 * 1024 * 1024

    let playbackURL: URL

    private let reader: MKVRangeReader
    private let remuxer: FFmpegSegmentRemuxer
    private let server: LocalRemuxHTTPServer
    private let byteCounter: RemuxByteCounter
    private let segmentsServed = RemuxByteCounter()
    private let memoryFootprint: Int64

    private init(
        playbackURL: URL,
        reader: MKVRangeReader,
        remuxer: FFmpegSegmentRemuxer,
        server: LocalRemuxHTTPServer,
        byteCounter: RemuxByteCounter,
        memoryFootprint: Int64
    ) {
        self.playbackURL = playbackURL
        self.reader = reader
        self.remuxer = remuxer
        self.server = server
        self.byteCounter = byteCounter
        self.memoryFootprint = memoryFootprint
    }

    // MARK: Build

    static func build(source: LocalRemuxSourceDescriptor) throws -> CueDrivenRemuxBackend {
        let byteCounter = RemuxByteCounter()
        let reader = MKVRangeReader(url: source.originalURL, byteCounter: byteCounter)

        let totalSize = try reader.totalSize()

        // 1. Parse the header (Info/Tracks/SeekHead) from a bounded head window.
        let headLength = Int(min(headProbeBytes, totalSize))
        let headData = try reader.fetchRange(offset: 0, length: headLength)
        guard var summary = MatroskaCueParser.parseHeader(headData, baseOffset: 0) else {
            throw BuildError.parseFailed
        }

        // 2. If Cues weren't inside the head window, follow the SeekHead to the
        //    (usually trailing) Cues element and parse them with one more read.
        if !summary.hasCues,
           let cuesOffset = summary.cuesAbsoluteOffset,
           Int64(cuesOffset) >= 0, Int64(cuesOffset) < totalSize {
            let cuesData = try reader.fetchToEnd(offset: Int64(cuesOffset))
            summary = MatroskaCueParser.parseCues(cuesData, baseOffset: cuesOffset, summary: summary)
        }
        guard summary.hasCues else { throw BuildError.noCues }

        // 3. Convert the parsed Cues into the shared KeyframeTable currency, then
        //    compute the full keyframe-aligned VOD timeline up front (pure math).
        //    Feeding the planner via KeyframeTable keeps the Cues fast-path on the
        //    same planner seam as the cache/scan/server providers (no divergence).
        let duration = source.durationSeconds ?? summary.durationSeconds
        let keyframeTable = CuesKeyframeProvider(summary: summary, durationHint: duration).keyframeTable()
        let timeline = HLSSegmentPlanner.plan(
            keyframeTable: keyframeTable,
            targetDuration: 6.0
        )
        guard !timeline.isEmpty else { throw BuildError.emptyTimeline }

        // 4. Open the FFmpeg `-c copy` remuxer and capture the CMAF init segment.
        let remuxer = FFmpegSegmentRemuxer(reader: reader)
        try remuxer.open()
        let initData = try remuxer.initSegment()

        // 5. Build the complete VOD playlist and the loopback server.
        let sessionID = Self.makeSessionID()
        let playlistText = LocalRemuxPlaylistBuilder.makeMediaPlaylist(timeline: timeline)
        let playlistData = Data(playlistText.utf8)
        let segmentsCounter = RemuxByteCounter()

        let handler = Self.makeHandler(
            sessionID: sessionID,
            playlistData: playlistData,
            initData: initData,
            timeline: timeline,
            remuxer: remuxer,
            segmentsServed: segmentsCounter
        )

        let server = LocalRemuxHTTPServer(handler: handler)
        let port = try server.start()

        guard let playbackURL = URL(string: "http://127.0.0.1:\(port)\(LocalRemuxRoutes.playlistPath(session: sessionID))") else {
            server.stop()
            remuxer.close()
            throw BuildError.parseFailed
        }

        let backend = CueDrivenRemuxBackend(
            playbackURL: playbackURL,
            reader: reader,
            remuxer: remuxer,
            server: server,
            byteCounter: byteCounter,
            memoryFootprint: Int64(playlistData.count + initData.count)
        )
        // Adopt the handler's segment counter so metrics reflect served segments.
        backend.adoptSegmentCounter(segmentsCounter)
        return backend
    }

    /// The `@Sendable` request router handed to the HTTP server. It captures only
    /// Sendable values (data buffers, the timeline, the thread-safe remuxer and
    /// counters), never main-actor state.
    private static func makeHandler(
        sessionID: String,
        playlistData: Data,
        initData: Data,
        timeline: RemuxSegmentTimeline,
        remuxer: FFmpegSegmentRemuxer,
        segmentsServed: RemuxByteCounter
    ) -> LocalRemuxHTTPServer.Handler {
        return { path in
            guard let route = LocalRemuxRoutes.parse(path: path),
                  routeSession(route) == sessionID else {
                return .notFound()
            }
            switch route {
            case .playlist:
                return .ok(playlistData, contentType: "application/vnd.apple.mpegurl")
            case .initSegment:
                return .ok(initData, contentType: "video/mp4")
            case .mediaSegment(_, let index):
                guard index >= 0, index < timeline.segments.count else { return .notFound() }
                let plan = timeline.segments[index]
                do {
                    let data = try remuxer.makeSegment(index: index, start: plan.startTime, end: plan.endTime)
                    segmentsServed.add(1)
                    return .ok(data, contentType: "video/mp4")
                } catch {
                    return .serverError("segment \(index): \(error)")
                }
            }
        }
    }

    private static func routeSession(_ route: LocalRemuxRoutes.Route) -> String {
        switch route {
        case .playlist(let session): return session
        case .initSegment(let session): return session
        case .mediaSegment(let session, _): return session
        }
    }

    private static func makeSessionID() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
    }

    // MARK: Lifecycle / metrics

    private var liveSegmentsCounter: RemuxByteCounter?

    private func adoptSegmentCounter(_ counter: RemuxByteCounter) {
        liveSegmentsCounter = counter
    }

    func metricsSnapshot() -> Metrics {
        Metrics(
            segmentsServed: Int(liveSegmentsCounter?.value ?? segmentsServed.value),
            bytesPulled: byteCounter.value,
            memoryBytes: memoryFootprint
        )
    }

    func shutdown() {
        server.stop()
        remuxer.close()
    }
}
#endif
