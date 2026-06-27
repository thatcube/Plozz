import Foundation

/// Generates the **complete VOD HLS media playlist** for a cue-driven local
/// remux. Declaring the entire timeline up front (EXT-X-MAP init segment + every
/// EXTINF + EXT-X-ENDLIST) is the whole point: AVPlayer's seekable range becomes
/// the full movie immediately, so a seek-ahead resolves to an already-declared
/// segment and can never 404 against an on-demand server.
///
/// fMP4/CMAF segments are required for HEVC + Dolby Vision + E-AC-3, so the
/// playlist is version 7 with an `EXT-X-MAP` initialization segment.
public enum LocalRemuxPlaylistBuilder {
    /// Builds the media playlist text for `timeline`.
    ///
    /// - Parameters:
    ///   - initURI: relative URI of the initialization segment.
    ///   - segmentURI: maps a segment index to its relative URI.
    public static func makeMediaPlaylist(
        timeline: RemuxSegmentTimeline,
        initURI: String = LocalRemuxRoutes.initSegmentURI,
        segmentURI: (Int) -> String = LocalRemuxRoutes.segmentURI(index:)
    ) -> String {
        var lines: [String] = []
        lines.append("#EXTM3U")
        lines.append("#EXT-X-VERSION:7")
        lines.append("#EXT-X-PLAYLIST-TYPE:VOD")
        lines.append("#EXT-X-INDEPENDENT-SEGMENTS")
        lines.append("#EXT-X-TARGETDURATION:\(timeline.targetDuration)")
        lines.append("#EXT-X-MEDIA-SEQUENCE:0")
        lines.append("#EXT-X-MAP:URI=\"\(initURI)\"")

        for segment in timeline.segments {
            lines.append("#EXTINF:\(formatDuration(segment.duration)),")
            lines.append(segmentURI(segment.index))
        }

        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Formats an EXTINF duration with the 6 decimal places AVPlayer expects.
    static func formatDuration(_ seconds: Double) -> String {
        String(format: "%.6f", max(0, seconds))
    }
}
